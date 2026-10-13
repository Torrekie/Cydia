/* Pure allowance construction; no filesystem access, subprocess or mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderDeconfigurationEffects.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <limits>

namespace CydiaAPT { namespace Provider {
namespace {
namespace B = BinaryRelationships;
namespace P = CydiaRuntime::Privileged;
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
std::string Key(const ExecutionPackage &p) { return p.package + ':' + p.architecture; }
std::string Generation(const ExecutionPackage &p) { return Key(p) + '@' + p.version; }
bool Same(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.architecture == b.architecture && a.version == b.version;
}
bool Digest(const std::string &s) { return s.size() == 64 && s.find_first_not_of("0123456789abcdef") == std::string::npos; }
void Field(std::string *out, const std::string &s) { *out += std::to_string(s.size()) + ':' + s + ','; }
void PackageBytes(std::string *out, const ExecutionPackage &p) { Field(out, p.package); Field(out, p.version); Field(out, p.architecture); }
std::string Hash(const std::string &bytes) {
    Hashes h(Hashes::SHA256SUM);
    return h.Add(bytes.data(), bytes.size()) ? h.GetHashString(Hashes::SHA256SUM).HashValue() : "";
}
struct Budget {
    std::size_t bytes = 0, steps = 0, causes = 0;
    bool Bytes(std::size_t n) {
        if (n > MaximumDeconfigurationInputBytes - bytes) return false;
        bytes += n; return true;
    }
    bool Steps(std::size_t n) {
        if (n > MaximumDeconfigurationSteps - steps) return false;
        steps += n; return true;
    }
};
struct Incoming {
    const DeconfigurationIndexControl *record = nullptr;
    std::shared_ptr<const B::Package> package;
    std::shared_ptr<const B::Field> breaks;
};
struct Derived {
    std::map<std::string, DeconfigurationAllowance> allowances;
    std::map<std::string, Incoming> incoming;
    std::string reviewBytes;
    std::map<std::string, std::size_t> installedInstances;
    Budget budget;
};
bool Controls(const std::map<std::string, std::string> &input,
    const ExecutionPackage &package, std::shared_ptr<const B::Package> *parsed,
    std::shared_ptr<const B::Field> *breaks, Budget *budget, std::string *error) {
    for (const auto &item : input)
        if (!budget->Bytes(item.first.size()) || !budget->Bytes(item.second.size()))
            return Fail(error, "provider_deconfiguration_limit");
    std::map<std::string, std::string> canonical;
    if (!CydiaPackages::CanonicalPackageEffectControlFields(input, &canonical, error) || canonical != input)
        return Fail(error, "provider_deconfiguration_controls_invalid");
    B::Error reason;
    if (!B::ParsePackage(package.package, package.version, package.architecture,
            canonical.at("multi-arch"), canonical.at("provides"), parsed, &reason))
        return Fail(error, "provider_deconfiguration_relationship_unsupported");
    const std::pair<const char *, B::Kind> kinds[] = {{"depends", B::Kind::Depends},
        {"pre-depends", B::Kind::PreDepends}, {"breaks", B::Kind::Breaks},
        {"conflicts", B::Kind::Conflicts}, {"replaces", B::Kind::Replaces}};
    for (const auto &kind : kinds) {
        std::shared_ptr<const B::Field> field;
        if (!B::ParseField(kind.second, canonical.at(kind.first), &field, &reason))
            return Fail(error, "provider_deconfiguration_relationship_unsupported");
        for (const auto &group : field->groups) for (const auto &atom : group.alternatives)
            if (atom.qualifier == B::Qualifier::Native)
                return Fail(error, "provider_deconfiguration_relationship_unsupported");
        if (kind.second == B::Kind::Breaks) *breaks = std::move(field);
    }
    return true;
}
bool Evaluate(const Incoming &incoming, const std::vector<std::shared_ptr<const B::Package>> &candidates,
    const std::string &native, const B::VersionComparator &compare, Budget *budget,
    B::Evaluation *result, std::string *error) {
    std::size_t width = 0;
    for (const auto &candidate : candidates) {
        if (candidate->provides->atomCount >= MaximumDeconfigurationSteps - width)
            return Fail(error, "provider_deconfiguration_limit");
        width += 1 + candidate->provides->atomCount;
    }
    if (incoming.breaks->atomCount && width > (MaximumDeconfigurationSteps - budget->steps) / incoming.breaks->atomCount)
        return Fail(error, "provider_deconfiguration_limit");
    if (!budget->Steps(width * incoming.breaks->atomCount)) return Fail(error, "provider_deconfiguration_limit");
    B::Error reason;
    if (!B::Evaluate(*incoming.breaks, *incoming.package, candidates, native, B::Use::UnpackChecks, compare, result, &reason))
        return Fail(error, reason.code == B::ErrorCode::LimitExceeded ? "provider_deconfiguration_limit" :
            "provider_deconfiguration_relationship_unsupported");
    return true;
}
bool Endpoint(const ReviewedTransaction &review, std::size_t causePosition,
    DeconfigurationAllowance *allowance, Budget *budget, std::string *error) {
    bool found = false, pairedPurge = false;
    for (std::size_t p = causePosition + 1; p < review.execution.actions.size(); ++p) {
        if (!budget->Steps(1)) return Fail(error, "provider_deconfiguration_limit");
        const auto &action = review.execution.actions[p];
        if (Key(action.package) != Key(allowance->installed) || (action.action != ExecutionAction::Configure &&
            action.action != ExecutionAction::Remove && action.action != ExecutionAction::Purge)) continue;
        const ReviewedAction *lastUnpack = nullptr;
        for (std::size_t u = 0; u < p; ++u) {
            if (!budget->Steps(1)) return Fail(error, "provider_deconfiguration_limit");
            if (review.execution.actions[u].action == ExecutionAction::Unpack &&
                Key(review.execution.actions[u].package) == Key(allowance->installed)) lastUnpack = &review.execution.actions[u];
        }
        const auto &expected = lastUnpack ? lastUnpack->package : allowance->installed;
        if (!Same(action.package, expected)) return Fail(error, "provider_deconfiguration_endpoint_generation_invalid");
        if (found) {
            // ReviewAuthorization permits explicit Remove followed by Purge.
            // Removal is the first terminating endpoint; purge remains an
            // independent required primary action, never an allowance action.
            if (!pairedPurge && allowance->endpoint.kind == ExecutionAction::Remove && action.action == ExecutionAction::Purge &&
                Same(action.package, allowance->endpoint.package) &&
                allowance->endpoint.precedingUnpack == (lastUnpack ? lastUnpack->identifier : 0)) {
                pairedPurge = true; continue;
            }
            return Fail(error, "provider_deconfiguration_endpoint_ambiguous");
        }
        allowance->endpoint.action = action.identifier; allowance->endpoint.kind = action.action;
        allowance->endpoint.package = action.package; allowance->endpoint.precedingUnpack = lastUnpack ? lastUnpack->identifier : 0;
        found = true;
    }
    return found || Fail(error, "provider_deconfiguration_endpoint_missing");
}
bool SingleAllNativeReplacement(const TriggerEffectCheckpoint &checkpoint, const std::map<std::string, std::size_t> &counts,
    const B::Package &incoming, const B::Package &old) {
    const auto &native = checkpoint.packages.nativeArchitecture;
    if (!((incoming.architecture == "all" && old.architecture == native) ||
        (old.architecture == "all" && incoming.architecture == native))) return false;
    const auto found = counts.find(incoming.name); const auto instances = found == counts.end() ? 0 : found->second;
    // Native parse_find_pkg_slot reuses the single installed slot unless both
    // old/new are Multi-Arch:same; all cannot be Multi-Arch:same. Other foreign
    // crossgrades remain outside this builder's bounded admission.
    return instances <= 1 && (incoming.multiArch != B::MultiArch::Same || old.multiArch != B::MultiArch::Same);
}
bool CheckpointBounded(const TriggerEffectCheckpoint &point) {
    Budget budget;
    if (point.metadata.packages.size() > MaximumTriggerEffectPackages || point.packages.packages.size() > MaximumTriggerEffectPackages ||
        point.registry.state.interests.size() > MaximumDeconfigurationSteps || point.registry.state.deferred.size() > MaximumDeconfigurationSteps) return false;
    for (const auto &entry : point.metadata.packages) {
        const auto &package = entry.second;
        if (package.controls.size() > 9 || package.declarations.size() > MaximumDeconfigurationSteps || !budget.Steps(1) ||
            !budget.Bytes(entry.first.size()) || !budget.Bytes(package.package.package.size()) || !budget.Bytes(package.package.version.size()) ||
            !budget.Bytes(package.package.architecture.size()) || !budget.Bytes(package.configVersion.size())) return false;
        for (const auto &control : package.controls)
            if (!budget.Steps(1) || !budget.Bytes(control.first.size()) || !budget.Bytes(control.second.size())) return false;
        for (const auto &declaration : package.declarations)
            if (!budget.Steps(1) || !budget.Bytes(declaration.trigger.size())) return false;
    }
    for (const auto &entry : point.packages.packages) {
        const auto &package = entry.second;
        if (!budget.Steps(1) || !budget.Bytes(entry.first.size()) || !budget.Bytes(package.package.package.size()) ||
            !budget.Bytes(package.package.version.size()) || !budget.Bytes(package.package.architecture.size()) || !budget.Bytes(package.multiArch.size())) return false;
        for (const auto *list : {&package.triggersPending, &package.triggersAwaited})
            for (const auto &trigger : *list) if (!budget.Steps(1) || !budget.Bytes(trigger.size())) return false;
    }
    for (const auto &interest : point.registry.state.interests)
        if (!budget.Steps(1) || !budget.Bytes(interest.package.size()) || !budget.Bytes(interest.trigger.size())) return false;
    for (const auto &activation : point.registry.state.deferred) {
        if (!budget.Steps(1) || !budget.Bytes(activation.trigger.size())) return false;
        for (const auto &awaiter : activation.awaiters) if (!budget.Steps(1) || !budget.Bytes(awaiter.size())) return false;
    }
    return true;
}
bool Derive(const ReviewedTransaction &review, const TriggerEffectCheckpoint &checkpoint,
    const std::vector<DeconfigurationIndexControl> &records, const B::VersionComparator &compare,
    Derived *out, std::string *error) {
    Derived result;
    if (review.execution.actions.empty() || review.execution.actions.size() > MaximumDeconfigurationActions ||
        review.execution.archives.size() > MaximumDeconfigurationActions || records.size() != review.execution.archives.size() ||
        checkpoint.packages.packages.size() > MaximumTriggerEffectPackages ||
        !Digest(checkpoint.identity) || !CheckpointBounded(checkpoint) || checkpoint.identity != TriggerEffectCheckpointIdentity(checkpoint) ||
        review.binding.packageStateIdentity != checkpoint.packages.packageStateIdentity || !Encode(review, &result.reviewBytes) ||
        !result.budget.Bytes(result.reviewBytes.size())) return Fail(error, "provider_deconfiguration_input_invalid");
    Message bound; bound.sequence = 1; bound.operation = Operation::RunPackageManager; bound.binding = review.binding;
    if (!ValidRequestBinding(bound)) return Fail(error, "provider_deconfiguration_review_invalid");
    std::map<std::uint64_t, std::size_t> positions;
    std::map<std::string, const ArchiveManifest *> archives;
    for (const auto &archive : review.execution.archives)
        if (!ValidIdentityToken(archive.identifier) || !archives.emplace(archive.identifier, &archive).second)
            return Fail(error, "provider_deconfiguration_archive_invalid");
    for (std::size_t p = 0; p < review.execution.actions.size(); ++p) {
        const auto &action = review.execution.actions[p];
        std::shared_ptr<const B::Package> parsed; B::Error reason;
        if (!action.identifier || !positions.emplace(action.identifier, p).second ||
            action.action == ExecutionAction::Deconfigure || action.action == ExecutionAction::Triggers ||
            static_cast<unsigned>(action.action) > static_cast<unsigned>(ExecutionAction::Deconfigure) ||
            !B::ParsePackage(action.package.package, action.package.version, action.package.architecture, "no", "", &parsed, &reason))
            return Fail(error, "provider_deconfiguration_review_invalid");
        if (action.action == ExecutionAction::Unpack) {
            const auto archive = archives.find(action.archive);
            if (archive == archives.end() || !Same(action.package, archive->second->package))
                return Fail(error, "provider_deconfiguration_archive_invalid");
        } else if (!action.archive.empty()) return Fail(error, "provider_deconfiguration_archive_invalid");
    }
    for (const auto &record : records) {
        const auto expected = archives.find(record.archive.identifier); std::string a, b;
        Incoming incoming; incoming.record = &record;
        if (expected == archives.end() || !Digest(record.evidenceIdentity) ||
            !Encode(*expected->second, &a) || !Encode(record.archive, &b) || a != b ||
            !Controls(record.controls, record.archive.package, &incoming.package, &incoming.breaks, &result.budget, error) ||
            !result.incoming.emplace(record.archive.identifier, std::move(incoming)).second)
            return Fail(error, "provider_deconfiguration_index_invalid");
    }
    std::vector<std::shared_ptr<const B::Package>> candidates;
    std::map<std::string, std::shared_ptr<const B::Package>> installedPackages;
    std::map<std::string, std::size_t> lastCause;
    for (const auto &record : checkpoint.packages.packages) {
        if (record.second.status != DpkgPackageStatus::NotInstalled) ++result.installedInstances[record.second.package.package];
        if (record.second.package.version.empty()) continue;
        const auto metadata = checkpoint.metadata.packages.find(record.first);
        std::shared_ptr<const B::Package> parsed; std::shared_ptr<const B::Field> ignored;
        if (metadata == checkpoint.metadata.packages.end() || !Same(metadata->second.package, record.second.package) ||
            !Digest(metadata->second.evidenceIdentity) || !Controls(metadata->second.controls, record.second.package,
                &parsed, &ignored, &result.budget, error)) return Fail(error, "provider_deconfiguration_installed_invalid");
        installedPackages.emplace(record.first, parsed);
        if (record.second.status > DpkgPackageStatus::HalfConfigured) candidates.push_back(std::move(parsed));
    }
    const auto add = [&](const ExecutionPackage &target, const DeconfigurationCause &cause, std::size_t position) {
        if (!result.budget.Steps(1) || ++result.budget.causes > MaximumDeconfigurationCauses)
            return Fail(error, "provider_deconfiguration_limit");
        const auto current = checkpoint.packages.packages.find(Key(target));
        const auto metadata = checkpoint.metadata.packages.find(Key(target));
        if (current == checkpoint.packages.packages.end() || metadata == checkpoint.metadata.packages.end() ||
            !Same(current->second.package, target) || current->second.reinstallRequired ||
            current->second.status <= DpkgPackageStatus::HalfConfigured || metadata->second.diskStatus <= DpkgPackageStatus::HalfConfigured)
            return Fail(error, "provider_deconfiguration_initial_generation_unavailable");
        for (std::size_t p = 0; p < position; ++p) {
            if (!result.budget.Steps(1)) return Fail(error, "provider_deconfiguration_limit");
            if (review.execution.actions[p].action == ExecutionAction::Unpack && Key(review.execution.actions[p].package) == Key(target))
                return Fail(error, "provider_deconfiguration_initial_generation_unavailable");
        }
        auto &allowance = result.allowances[Generation(target)];
        allowance.installed = target; allowance.selection = current->second.selection;
        allowance.initialStatus = current->second.status; allowance.diskStatus = metadata->second.diskStatus;
        allowance.configVersion = metadata->second.configVersion; allowance.installedControlIdentity = metadata->second.evidenceIdentity;
        allowance.causes.push_back(cause); lastCause[Generation(target)] = position; return true;
    };
    std::set<std::string> usedArchives;
    for (std::size_t p = 0; p < review.execution.actions.size(); ++p) {
        const auto &action = review.execution.actions[p];
        if (action.action != ExecutionAction::Unpack) continue;
        usedArchives.insert(action.archive); const auto &incoming = result.incoming.at(action.archive);
        std::vector<std::shared_ptr<const B::Package>> live;
        for (const auto &candidate : candidates) {
            bool initial = true;
            for (std::size_t before = 0; before < p; ++before) {
                if (!result.budget.Steps(1)) return Fail(error, "provider_deconfiguration_limit");
                const auto &prior = review.execution.actions[before];
                const bool exact = prior.package.package == candidate->name && prior.package.architecture == candidate->architecture;
                const bool cross = prior.action == ExecutionAction::Unpack && prior.package.package == candidate->name &&
                    SingleAllNativeReplacement(checkpoint, result.installedInstances, *result.incoming.at(prior.archive).package, *candidate);
                if ((exact && (prior.action == ExecutionAction::Unpack || prior.action == ExecutionAction::Remove || prior.action == ExecutionAction::Purge)) || cross)
                    initial = false;
            }
            if (initial) live.push_back(candidate);
        }
        B::Evaluation matches;
        if (!Evaluate(incoming, live, checkpoint.packages.nativeArchitecture, compare, &result.budget, &matches, error)) return false;
        for (const auto &group : matches.groups) {
            const bool provider = std::any_of(group.witnesses.begin(), group.witnesses.end(),
                [](const B::Witness &w) { return w.provide != B::DirectPackage; });
            if (provider && group.witnesses.size() != 1) return Fail(error, "provider_deconfiguration_provider_ambiguous");
            for (const auto &witness : group.witnesses) {
                DeconfigurationCause cause; cause.unpackAction = action.identifier; cause.archive = action.archive;
                cause.canonicalRelation = incoming.breaks->canonical; cause.comparedVersion = witness.comparedVersion;
                cause.group = witness.group; cause.alternative = witness.alternative; cause.provide = witness.provide;
                if (!add({witness.package, witness.version, witness.architecture}, cause, p)) return false;
            }
        }
        for (const auto &candidate : live) {
            if (!result.budget.Steps(1)) return Fail(error, "provider_deconfiguration_limit");
            if (candidate->name != incoming.package->name || candidate->architecture == incoming.package->architecture) continue;
            if (SingleAllNativeReplacement(checkpoint, result.installedInstances, *incoming.package, *candidate)) continue;
            if (candidate->multiArch != B::MultiArch::Same || incoming.package->multiArch != B::MultiArch::Same)
                return Fail(error, "provider_deconfiguration_sibling_unsupported");
            B::VersionComparison compared;
            try { if (compare) compared = compare(candidate->version, incoming.package->version); }
            catch (...) { compared.status = B::ComparisonStatus::Failed; }
            if (compared.status != B::ComparisonStatus::Compared) return Fail(error, "provider_deconfiguration_comparison_unavailable");
            if (!compared.ordering) continue;
            DeconfigurationCause cause; cause.kind = DeconfigurationCauseKind::SiblingVersionMismatch;
            cause.unpackAction = action.identifier; cause.archive = action.archive; cause.comparedVersion = candidate->version;
            if (!add({candidate->name, candidate->version, candidate->architecture}, cause, p)) return false;
        }
    }
    if (usedArchives.size() != archives.size()) return Fail(error, "provider_deconfiguration_archive_invalid");
    // An already replaced/configured generation is outside initial capture.
    // Evaluate those exact reviewed generations too, so absence of an old-version
    // Breaks match never silently grants permission for a future victim.
    for (std::size_t p = 0; p < review.execution.actions.size(); ++p) {
        const auto &action = review.execution.actions[p]; if (action.action != ExecutionAction::Unpack) continue;
        std::map<std::string, std::shared_ptr<const B::Package>> future;
        for (std::size_t q = 0; q < p; ++q) {
            if (!result.budget.Steps(1)) return Fail(error, "provider_deconfiguration_limit");
            const auto &prior = review.execution.actions[q];
            if (prior.action == ExecutionAction::Unpack || prior.action == ExecutionAction::Remove || prior.action == ExecutionAction::Purge)
                future.erase(Key(prior.package));
            if (prior.action != ExecutionAction::Configure) continue;
            bool unpacked = false;
            for (std::size_t u = q; u > 0; --u) {
                if (!result.budget.Steps(1)) return Fail(error, "provider_deconfiguration_limit");
                const auto &unpack = review.execution.actions[u - 1];
                if (unpack.action == ExecutionAction::Unpack && Key(unpack.package) == Key(prior.package)) {
                    unpacked = true;
                    if (Same(unpack.package, prior.package)) future[Key(prior.package)] = result.incoming.at(unpack.archive).package;
                    break;
                }
            }
            if (!unpacked) {
                const auto installed = installedPackages.find(Key(prior.package));
                if (installed != installedPackages.end() && installed->second->version == prior.package.version)
                    future[Key(prior.package)] = installed->second;
            }
        }
        std::vector<std::shared_ptr<const B::Package>> values; for (const auto &value : future) values.push_back(value.second);
        B::Evaluation matches;
        if (!Evaluate(result.incoming.at(action.archive), values, checkpoint.packages.nativeArchitecture, compare,
            &result.budget, &matches, error)) return false;
        if (matches.anyGroupMatched) return Fail(error, "provider_deconfiguration_future_generation_unavailable");
        const auto &source = *result.incoming.at(action.archive).package;
        for (const auto &candidate : values) {
            if (!result.budget.Steps(1)) return Fail(error, "provider_deconfiguration_limit");
            if (source.name != candidate->name || source.architecture == candidate->architecture ||
                SingleAllNativeReplacement(checkpoint, result.installedInstances, source, *candidate)) continue;
            if (source.multiArch != B::MultiArch::Same || candidate->multiArch != B::MultiArch::Same)
                return Fail(error, "provider_deconfiguration_sibling_unsupported");
            B::VersionComparison compared;
            try { if (compare) compared = compare(candidate->version, source.version); }
            catch (...) { compared.status = B::ComparisonStatus::Failed; }
            if (compared.status != B::ComparisonStatus::Compared) return Fail(error, "provider_deconfiguration_comparison_unavailable");
            if (compared.ordering) return Fail(error, "provider_deconfiguration_future_generation_unavailable");
        }
    }
    for (auto &allowance : result.allowances)
        if (!Endpoint(review, lastCause.at(allowance.first), &allowance.second, &result.budget, error)) return false;
    *out = std::move(result); return true;
}
bool Script(const P::Evidence &file, Budget *budget, std::string *encoded) {
    if (file.path.empty() || file.path.front() != '/' || file.path.size() > 4096 || file.directory || file.identityOnly ||
        file.bytes.size() > MaximumInstalledScriptBytes || !file.entries.empty()) return false;
    if (file.absent) { if (!file.bytes.empty()) return false; }
    else if (!S_ISREG(file.identity.st_mode) || file.identity.st_uid || file.identity.st_nlink != 1 ||
        (file.identity.st_mode & 0022) || file.identity.st_size < 0 ||
        static_cast<std::uint64_t>(file.identity.st_size) != file.bytes.size()) return false;
    if (!budget->Bytes(file.path.size()) || !budget->Bytes(file.bytes.size())) return false;
    *encoded = P::SerializeSnapshotEvidence(file); return !encoded->empty();
}
bool EvidenceShape(const P::Evidence &file) {
    if (file.path.empty() || file.path.front() != '/' || file.path.size() > 4096 ||
        !file.sourceDelegation.empty() || !file.entries.empty() || !file.sourceReaderGroups.values.empty() ||
        file.sourceInput || file.sharedState || file.sourceReaderUID || file.sourceReaderGID) return false;
    for (unsigned char byte : file.path) if (byte < 32 || byte == 127) return false;
    if (file.absent) return !file.directory && !file.identityOnly && file.bytes.empty();
    if (file.directory) return file.identityOnly && file.bytes.empty() && S_ISDIR(file.identity.st_mode);
    return !file.identityOnly && S_ISREG(file.identity.st_mode) && file.identity.st_nlink == 1 &&
        file.identity.st_size >= 0 && static_cast<std::uint64_t>(file.identity.st_size) == file.bytes.size();
}
bool ScriptNames(const InstalledPackageScripts &package, const std::map<std::string, const P::Evidence *> &files,
    std::set<std::string> *selected) {
    std::string directory, qualification;
    for (const auto &item : {std::make_pair("prerm", &package.prerm), std::make_pair("postinst", &package.postinst)}) {
        const auto slash = item.second->path.rfind('/');
        if (slash == std::string::npos) return false;
        const auto parent = item.second->path.substr(0, slash), name = item.second->path.substr(slash + 1);
        const auto plain = package.package.package + '.' + item.first, qualified = Key(package.package) + '.' + item.first;
        const auto form = name == plain ? "plain" : name == qualified ? "qualified" : "";
        if (!*form || (!directory.empty() && directory != parent) || (!qualification.empty() && qualification != form) ||
            !selected->insert(item.second->path).second) return false;
        directory = parent; qualification = form;
        const auto other = files.find(parent + '/' + (name == plain ? qualified : plain));
        if (other == files.end() || !other->second->absent || other->second->directory || !other->second->bytes.empty()) return false;
    }
    return true;
}
}
bool SelectDeconfigurationTargets(const ReviewedTransaction &review, const TriggerEffectCheckpoint &checkpoint,
    const std::vector<DeconfigurationIndexControl> &incoming, const B::VersionComparator &compare,
    std::vector<ExecutionPackage> *targets, std::string *error) {
    if (!targets) return Fail(error, "provider_deconfiguration_output_invalid");
    targets->clear(); Derived derived;
    if (!Derive(review, checkpoint, incoming, compare, &derived, error)) return false;
    for (const auto &allowance : derived.allowances) targets->push_back(allowance.second.installed);
    if (error) error->clear(); return true;
}
bool BuildDeconfigurationAllowances(const ReviewedTransaction &review, const TriggerEffectCheckpoint &checkpoint,
    const std::string &nativeAuthority, const std::vector<DeconfigurationIndexControl> &incoming,
    const InstalledScriptMetadata &scripts, const B::VersionComparator &compare,
    DeconfigurationAllowanceSet *output, std::string *error) {
    if (!output) return Fail(error, "provider_deconfiguration_output_invalid");
    *output = DeconfigurationAllowanceSet(); Derived derived;
    if (!Digest(nativeAuthority)) return Fail(error, "provider_deconfiguration_input_invalid");
    if (!Derive(review, checkpoint, incoming, compare, &derived, error)) return false;
    std::string bytes("CYDIA-DECONFIGURATION-ALLOWANCES-1");
    Field(&bytes, derived.reviewBytes); Field(&bytes, checkpoint.identity); Field(&bytes, nativeAuthority);
    for (const auto &record : derived.incoming) {
        Field(&bytes, record.first); Field(&bytes, record.second.record->evidenceIdentity);
        for (const auto &control : record.second.record->controls) { Field(&bytes, control.first); Field(&bytes, control.second); }
        Field(&bytes, "");
    }
    if (!derived.allowances.empty()) {
        if (!Digest(scripts.evidenceIdentity) || scripts.packageStateIdentity != checkpoint.packages.packageStateIdentity ||
            scripts.packages.size() != derived.allowances.size() || scripts.files.empty() ||
            scripts.files.size() > 4 + 4 * MaximumTriggerEffectPackages)
            return Fail(error, "provider_deconfiguration_scripts_invalid");
        std::map<std::string, std::string> files; std::map<std::string, const P::Evidence *> rawFiles;
        for (const auto &file : scripts.files) {
            if (!EvidenceShape(file) || !derived.budget.Bytes(file.path.size()) || !derived.budget.Bytes(file.bytes.size()))
                return Fail(error, "provider_deconfiguration_scripts_invalid");
            const auto encoded = P::SerializeSnapshotEvidence(file);
            const auto inserted = files.emplace(file.path, encoded);
            if (!inserted.second && inserted.first->second != encoded) return Fail(error, "provider_deconfiguration_scripts_invalid");
            rawFiles.emplace(file.path, &file);
        }
        Field(&bytes, scripts.evidenceIdentity);
        for (const auto &file : files) { Field(&bytes, file.first); Field(&bytes, file.second); }
        std::set<std::string> selected;
        for (auto &entry : derived.allowances) {
            auto &allowance = entry.second; const auto found = scripts.packages.find(Key(allowance.installed));
            if (found == scripts.packages.end() || !Same(found->second.package, allowance.installed) ||
                found->second.configVersion != allowance.configVersion || found->second.diskStatus != allowance.diskStatus ||
                !Digest(found->second.evidenceIdentity) || !ScriptNames(found->second, rawFiles, &selected))
                return Fail(error, "provider_deconfiguration_scripts_invalid");
            std::string prerm, postinst;
            if (!Script(found->second.prerm, &derived.budget, &prerm) || !Script(found->second.postinst, &derived.budget, &postinst) ||
                !files.count(found->second.prerm.path) || files.at(found->second.prerm.path) != prerm ||
                !files.count(found->second.postinst.path) || files.at(found->second.postinst.path) != postinst)
                return Fail(error, "provider_deconfiguration_scripts_invalid");
            std::string scriptBytes; Field(&scriptBytes, found->second.evidenceIdentity); Field(&scriptBytes, prerm); Field(&scriptBytes, postinst);
            allowance.installedScriptsIdentity = Hash(scriptBytes);
            Field(&bytes, entry.first); PackageBytes(&bytes, allowance.installed);
            for (const auto &value : {std::to_string(static_cast<unsigned>(allowance.selection)),
                std::to_string(static_cast<unsigned>(allowance.initialStatus)), std::to_string(static_cast<unsigned>(allowance.diskStatus)),
                allowance.configVersion, allowance.installedControlIdentity, allowance.installedScriptsIdentity}) Field(&bytes, value);
            const auto &controls = checkpoint.metadata.packages.at(Key(allowance.installed)).controls;
            for (const auto &control : controls) { Field(&bytes, control.first); Field(&bytes, control.second); }
            Field(&bytes, "");
            for (const auto &cause : allowance.causes) {
                for (const auto &value : {std::to_string(static_cast<unsigned>(cause.kind)), std::to_string(cause.unpackAction),
                    cause.archive, cause.canonicalRelation, cause.comparedVersion, std::to_string(cause.group),
                    std::to_string(cause.alternative), std::to_string(cause.provide)}) Field(&bytes, value);
            }
            Field(&bytes, ""); Field(&bytes, std::to_string(allowance.endpoint.action));
            Field(&bytes, std::to_string(allowance.endpoint.precedingUnpack));
            Field(&bytes, std::to_string(static_cast<unsigned>(allowance.endpoint.kind))); PackageBytes(&bytes, allowance.endpoint.package);
        }
    } else if (!scripts.packages.empty() || !scripts.files.empty() || !scripts.packageStateIdentity.empty() || !scripts.evidenceIdentity.empty())
        return Fail(error, "provider_deconfiguration_scripts_invalid");
    DeconfigurationAllowanceSet result; result.identity = Hash(bytes);
    if (!Digest(result.identity)) return Fail(error, "provider_deconfiguration_hash_failed");
    result.initialCheckpoint = checkpoint.identity; result.nativeAuthorityIdentity = nativeAuthority;
    result.primaryReview = review; result.allowances = std::move(derived.allowances);
    *output = std::move(result); if (error) error->clear(); return true;
}
}}
