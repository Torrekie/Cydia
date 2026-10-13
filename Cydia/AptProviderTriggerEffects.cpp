/* Finite, parent-selected effects. No dpkg execution or provider authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEffects.hpp"
#include "Cydia/ExtendedState.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>

namespace CydiaAPT { namespace Provider {
namespace {
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
void Frame(std::string *bytes, const std::string &value) { *bytes += std::to_string(value.size()) + ':' + value + ','; }
std::string Hash(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM);
    return hash.Add(bytes.data(), bytes.size()) ? hash.GetHashString(Hashes::SHA256SUM).HashValue() : "";
}
bool Digest(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
std::string Key(const ExecutionPackage &package) { return package.package + ':' + package.architecture; }
std::string Generation(const ExecutionPackage &package) { return Key(package) + '@' + package.version; }
bool SamePackage(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.version == b.version && a.architecture == b.architecture;
}
bool Package(const ExecutionPackage &package) {
    return CydiaRuntime::ValidPackageName(package.package) && CydiaRuntime::ValidArchitectureName(package.architecture) &&
        package.architecture != "any" && package.architecture != "native" && !package.version.empty() &&
        package.version.size() <= 1024 && package.version.find_first_not_of(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+:~-") == std::string::npos;
}
bool Installed(const DpkgPackageState &package) {
    return package.status >= DpkgPackageStatus::Unpacked && !package.reinstallRequired;
}
bool SameDeclarations(const std::vector<TriggerDeclaration> &a, const std::vector<TriggerDeclaration> &b) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i)
        if (a[i].kind != b[i].kind || a[i].trigger != b[i].trigger || a[i].await != b[i].await) return false;
    return true;
}
bool SamePackageContent(const TriggerPackageMetadata &a, const TriggerPackageMetadata &b) {
    return SamePackage(a.package, b.package) && a.controls == b.controls &&
        SameDeclarations(a.declarations, b.declarations);
}
bool SameMetadata(const TriggerPackageMetadata &a, const TriggerPackageMetadata &b) {
    return SamePackageContent(a, b) && a.configVersion == b.configVersion &&
        a.diskStatus == b.diskStatus && a.declarationIdentity == b.declarationIdentity && a.evidenceIdentity == b.evidenceIdentity;
}
void MetadataBytes(std::string *bytes, const TriggerPackageMetadata &value) {
    Frame(bytes, Generation(value.package)); Frame(bytes, value.evidenceIdentity);
    Frame(bytes, value.configVersion); Frame(bytes, value.declarationIdentity);
    Frame(bytes, std::to_string(static_cast<unsigned>(value.diskStatus)));
    for (const auto &control : value.controls) { Frame(bytes, control.first); Frame(bytes, control.second); }
    Frame(bytes, "");
    for (const auto &declaration : value.declarations) {
        Frame(bytes, declaration.kind == TriggerDeclarationKind::Interest ? "interest" : "activate");
        Frame(bytes, declaration.trigger); Frame(bytes, declaration.await ? "1" : "0");
    }
    Frame(bytes, "");
}
// Round-trip through the existing structured parser, keeping its full native
// architecture/status/list validation instead of a weaker parallel validator.
bool StateBytes(const DpkgState &state, std::string *bytes) {
    if (state.packages.size() > MaximumTriggerEffectPackages || state.registeredArchitectures.empty()) return false;
    const char *selections[] = {"unknown", "install", "hold", "deinstall", "purge"};
    const char *states[] = {"not-installed", "config-files", "half-installed", "unpacked", "half-configured",
                          "triggers-awaited", "triggers-pending", "installed"};
    bytes->clear();
    for (const auto &item : state.packages) {
        const auto &record = item.second;
        if (item.first != Key(record.package) || static_cast<unsigned>(record.selection) >= 5 ||
            static_cast<unsigned>(record.status) >= 8 || record.triggersPending.size() > 4096 ||
            record.triggersAwaited.size() > 4096) return false;
        for (const auto *field : {&record.package.package, &record.package.version, &record.package.architecture, &record.multiArch})
            if (field->size() > 4096 || field->find_first_of(" \t\r\n\v\f") != std::string::npos) return false;
        std::string row = record.package.package + '\t' + record.package.version + '\t' + record.package.architecture + '\t' +
            selections[static_cast<unsigned>(record.selection)] + ' ' + (record.reinstallRequired ? "reinstreq " : "ok ") +
            states[static_cast<unsigned>(record.status)] + '\t' + record.multiArch;
        for (const auto *list : {&record.triggersPending, &record.triggersAwaited}) {
            if (!std::is_sorted(list->begin(), list->end())) return false;
            row += '\t'; bool first = true;
            for (const auto &entry : *list) {
                if (entry.empty() || entry.size() > 4096 || entry.find_first_of(" \t\r\n\v\f") != std::string::npos) return false;
                if (!first) row += ' '; row += entry; first = false;
            }
        }
        row += '\n';
        if (row.size() > MaximumTriggerEvidenceBytes - bytes->size()) return false;
        *bytes += row;
    }
    std::string foreign;
    for (std::size_t i = 1; i < state.registeredArchitectures.size(); ++i) foreign += state.registeredArchitectures[i] + '\n';
    DpkgState parsed; std::string error;
    return state.registeredArchitectures.front() == state.nativeArchitecture &&
        ParseDpkgState(*bytes, state.nativeArchitecture + '\n', foreign, state.packageStateIdentity, &parsed, &error) &&
        parsed.packages.size() == state.packages.size();
}
const DpkgPackageState *Resolve(const DpkgState &state, const std::string &selector) {
    const auto colon = selector.find(':');
    if (colon != std::string::npos) {
        const auto architecture = selector.substr(colon + 1);
        if (architecture == "any" || architecture == "native") return NULL;
        const auto found = state.packages.find(selector);
        return found == state.packages.end() ? NULL : &found->second;
    }
    const DpkgPackageState *result = NULL;
    for (const auto &record : state.packages) if (record.second.package.package == selector &&
        record.second.status != DpkgPackageStatus::NotInstalled) {
        if (result) return NULL;
        result = &record.second;
    }
    return result;
}
bool MatchesActivation(const std::string &interest, const std::string &activation) {
    return interest == activation || (!interest.empty() && interest[0] == '/' && activation.size() > interest.size() &&
        activation.compare(0, interest.size(), interest) == 0 && activation[interest.size()] == '/');
}
using Interests = std::map<std::pair<std::string, std::string>, bool>; // generation, trigger -> await
bool Checkpoint(const TriggerEffectCheckpoint &checkpoint, Interests *interests, std::string *error) {
    interests->clear(); std::string state;
    if (!checkpoint.registry.synchronized || !checkpoint.registry.state.directoryPresent || !checkpoint.registry.state.lockPresent ||
        !Digest(checkpoint.registry.evidenceIdentity) || !Digest(checkpoint.registry.state.canonicalIdentity) ||
        !Digest(checkpoint.metadata.evidenceIdentity) || checkpoint.metadata.packageStateIdentity != checkpoint.packages.packageStateIdentity ||
        !StateBytes(checkpoint.packages, &state) || checkpoint.metadata.packages.size() > MaximumTriggerEffectPackages ||
        checkpoint.registry.state.interests.size() > MaximumTriggerRelations || checkpoint.registry.state.deferred.size() > MaximumTriggerRelations)
        return Fail(error, "provider_trigger_checkpoint_invalid");
    for (const auto &record : checkpoint.packages.packages) {
        if (record.second.package.version.empty()) continue;
        const auto metadata = checkpoint.metadata.packages.find(record.first);
        if (metadata == checkpoint.metadata.packages.end() || !SamePackage(metadata->second.package, record.second.package) ||
            !Digest(metadata->second.evidenceIdentity) || !Digest(metadata->second.declarationIdentity) ||
            static_cast<unsigned>(metadata->second.diskStatus) > static_cast<unsigned>(DpkgPackageStatus::Installed) ||
            metadata->second.configVersion.size() > 1024 || metadata->second.configVersion.find_first_not_of(
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+:~-") != std::string::npos)
            return Fail(error, "provider_trigger_control_changed");
        if (((metadata->second.diskStatus == DpkgPackageStatus::Installed || metadata->second.diskStatus == DpkgPackageStatus::TriggersPending) &&
            metadata->second.configVersion != metadata->second.package.version) ||
            (metadata->second.diskStatus == DpkgPackageStatus::NotInstalled && !metadata->second.configVersion.empty()))
            return Fail(error, "provider_trigger_control_changed");
        std::map<std::string, std::string> controls;
        if (!CydiaPackages::CanonicalPackageEffectControlFields(metadata->second.controls, &controls, error) ||
            controls != metadata->second.controls || controls["multi-arch"] != (record.second.multiArch.empty() ? "no" : record.second.multiArch))
            return Fail(error, "provider_trigger_control_changed");
        if (metadata->second.declarations.size() > MaximumTriggerRelations) return Fail(error, "provider_trigger_evidence_limit");
        std::string raw;
        for (const auto &declaration : metadata->second.declarations) {
            if (static_cast<unsigned>(declaration.kind) > static_cast<unsigned>(TriggerDeclarationKind::Activate))
                return Fail(error, "provider_trigger_declarations_invalid");
            raw += declaration.kind == TriggerDeclarationKind::Interest ? "interest" : "activate";
            raw += declaration.await ? "-await " : "-noawait "; raw += declaration.trigger + '\n';
            if (raw.size() > 1024 * 1024) return Fail(error, "provider_trigger_evidence_limit");
        }
        std::vector<TriggerDeclaration> parsed;
        if (!ParseTriggerDeclarations(raw, &parsed, error) || !SameDeclarations(parsed, metadata->second.declarations)) return false;
    }
    for (const auto &metadata : checkpoint.metadata.packages)
        if (!checkpoint.packages.packages.count(metadata.first)) return Fail(error, "provider_trigger_control_changed");
    for (const auto &interest : checkpoint.registry.state.interests) {
        const auto package = Resolve(checkpoint.packages, interest.package);
        if (!package || !Installed(*package)) return Fail(error, "provider_trigger_selector_unresolved");
        const auto &metadata = checkpoint.metadata.packages.at(Key(package->package));
        bool declared = false;
        for (const auto &declaration : metadata.declarations)
            if (declaration.kind == TriggerDeclarationKind::Interest && declaration.trigger == interest.trigger &&
                declaration.await == interest.await) declared = true;
        if (!declared || !interests->emplace(std::make_pair(Generation(package->package), interest.trigger), interest.await).second)
            return Fail(error, "provider_trigger_registry_changed");
    }
    for (const auto &metadata : checkpoint.metadata.packages) {
        if (!Installed(checkpoint.packages.packages.at(metadata.first))) continue;
        for (const auto &declaration : metadata.second.declarations)
            if (declaration.kind == TriggerDeclarationKind::Interest &&
                !interests->count(std::make_pair(Generation(metadata.second.package), declaration.trigger)))
                return Fail(error, "provider_trigger_registry_changed");
    }
    return true;
}
bool Graph(const TriggerEffectCheckpoint &checkpoint, const TriggerEffectEnvelope &envelope, std::string *error) {
    Interests interests;
    if (!Checkpoint(checkpoint, &interests, error)) return false;
    for (const auto &interest : interests)
        if (!envelope.recipients.count(interest.first.first)) return Fail(error, "provider_trigger_recipient_unreviewed");
    for (const auto &item : checkpoint.packages.packages) {
        const auto &record = item.second; const auto generation = Generation(record.package);
        for (const auto &trigger : record.triggersPending)
            if (!envelope.recipients.count(generation) || !interests.count(std::make_pair(generation, trigger)))
                return Fail(error, "provider_trigger_recipient_unreviewed");
        if (!record.triggersAwaited.empty() && !envelope.awaiters.count(generation))
            return Fail(error, "provider_trigger_awaiter_unreviewed");
        for (const auto &selector : record.triggersAwaited) {
            const auto target = Resolve(checkpoint.packages, selector);
            if (!target || !envelope.recipients.count(Generation(target->package)) || target->triggersPending.empty())
                return Fail(error, "provider_trigger_waiter_unresolved");
            bool canAwait = false;
            for (const auto &trigger : target->triggersPending) {
                const auto interest = interests.find(std::make_pair(Generation(target->package), trigger));
                if (interest != interests.end() && interest->second) canAwait = true;
            }
            if (!canAwait) return Fail(error, "provider_trigger_waiter_unresolved");
        }
    }
    for (const auto &activation : checkpoint.registry.state.deferred) {
        for (const auto &selector : activation.awaiters) {
            const auto waiter = Resolve(checkpoint.packages, selector);
            if (!waiter || !envelope.awaiters.count(Generation(waiter->package)))
                return Fail(error, "provider_trigger_awaiter_unreviewed");
        }
        for (const auto &interest : interests) if (MatchesActivation(interest.first.second, activation.trigger) &&
            !envelope.recipients.count(interest.first.first)) return Fail(error, "provider_trigger_recipient_unreviewed");
    }
    return true;
}
std::string EnvelopeIdentity(const TriggerEffectEnvelope &envelope) {
    std::string bytes("CYDIA-TRIGGER-EFFECT-ENVELOPE-2"), review;
    if (!Encode(envelope.primaryReview, &review)) return "";
    Frame(&bytes, envelope.initialCheckpoint); Frame(&bytes, envelope.nativeAuthorityIdentity); Frame(&bytes, review);
    for (const auto *pool : {&envelope.recipients, &envelope.awaiters}) {
        for (const auto &package : *pool) { Frame(&bytes, package.first); Frame(&bytes, Generation(package.second)); }
        Frame(&bytes, "");
    }
    for (const auto &incoming : envelope.incoming) Frame(&bytes, incoming);
    return Hash(bytes);
}
std::string GraphIdentity(const TriggerEffectCheckpoint &checkpoint) {
    std::string bytes("CYDIA-TRIGGER-EFFECT-GRAPH-1");
    for (const auto &record : checkpoint.packages.packages) {
        Frame(&bytes, Generation(record.second.package)); Frame(&bytes, std::to_string(static_cast<unsigned>(record.second.status)));
        for (const auto *list : {&record.second.triggersPending, &record.second.triggersAwaited}) {
            for (const auto &value : *list) Frame(&bytes, value);
            Frame(&bytes, "");
        }
    }
    for (const auto &activation : checkpoint.registry.state.deferred) {
        Frame(&bytes, activation.trigger); Frame(&bytes, activation.noAwait ? "1" : "0");
        for (const auto &waiter : activation.awaiters) Frame(&bytes, waiter);
        Frame(&bytes, "");
    }
    return Hash(bytes);
}
DpkgState WithoutTriggers(const DpkgState &state) {
    DpkgState result(state);
    for (auto &record : result.packages) {
        record.second.triggersPending.clear(); record.second.triggersAwaited.clear();
        if (record.second.status == DpkgPackageStatus::TriggersPending || record.second.status == DpkgPackageStatus::TriggersAwaited)
            record.second.status = DpkgPackageStatus::Installed;
    }
    return result;
}
bool SameBase(const DpkgState &a, const DpkgState &b) {
    std::string left, right;
    return a.nativeArchitecture == b.nativeArchitecture && a.registeredArchitectures == b.registeredArchitectures &&
        StateBytes(WithoutTriggers(a), &left) && StateBytes(WithoutTriggers(b), &right) && left == right;
}
bool Successful(const ParentExecutionReply &reply) {
    return reply.started && reply.exitCode == 0 && reply.signal == 0 && reply.launchError == 0;
}
bool SameBatch(const AuthorizedExecution &a, const AuthorizedExecution &b) {
    if (a.batch != b.batch || a.action != b.action || a.actions != b.actions || a.arguments != b.arguments ||
        a.archives.size() != b.archives.size()) return false;
    for (std::size_t i = 0; i < a.archives.size(); ++i) {
        std::string left, right;
        if (a.archives[i].fileIdentity != b.archives[i].fileIdentity || !Encode(a.archives[i].archive, &left) ||
            !Encode(b.archives[i].archive, &right) || left != right) return false;
    }
    return true;
}
bool UnchangedMetadata(const TriggerEffectCheckpoint &before, const TriggerEffectCheckpoint &after,
    const std::set<std::string> &changed, const std::map<std::string, TriggerPackageMetadata> &incoming,
    const std::set<std::string> &configured, std::string *error) {
    for (const auto &metadata : after.metadata.packages) {
        const auto previous = before.metadata.packages.find(metadata.first);
        const auto generation = Generation(metadata.second.package);
        if (changed.count(generation)) {
            const auto refined = incoming.find(generation);
            if (refined != incoming.end()) {
                // Config-Version belongs to native installed state, not the
                // incoming control archive or source index.
                if (!SamePackageContent(refined->second, metadata.second)) return Fail(error, "provider_trigger_incoming_changed");
            } else if (previous == before.metadata.packages.end() || previous->second.controls != metadata.second.controls ||
                (!metadata.second.declarations.empty() && !SameDeclarations(previous->second.declarations, metadata.second.declarations)))
                return Fail(error, "provider_trigger_control_changed");
        } else if (previous == before.metadata.packages.end() || !SameMetadata(previous->second, metadata.second)) {
            // Native dump omits Config-Version once installed/pending. A
            // successful explicit configure, or a waiter becoming installed,
            // then reads back Version as the last configured version. Permit
            // only that transition, retaining exact declaration-file evidence.
            // Query may already have normalized a disk waiter to pending or
            // installed without rewriting its historical Config-Version.
            if (previous == before.metadata.packages.end()) return Fail(error, "provider_trigger_control_changed");
            const auto &old = previous->second, &now = metadata.second;
            const bool phaseAllowed = now.diskStatus >= DpkgPackageStatus::TriggersAwaited &&
                (configured.count(generation) || old.diskStatus >= DpkgPackageStatus::TriggersAwaited);
            const bool versionAllowed = old.configVersion == now.configVersion ||
                ((configured.count(generation) || old.diskStatus == DpkgPackageStatus::TriggersAwaited) &&
                 (now.diskStatus == DpkgPackageStatus::Installed || now.diskStatus == DpkgPackageStatus::TriggersPending) &&
                 now.configVersion == now.package.version);
            const bool nativeTransition = phaseAllowed && versionAllowed &&
                (old.diskStatus != now.diskStatus || old.configVersion != now.configVersion) &&
                SamePackageContent(old, now) && old.declarationIdentity == now.declarationIdentity;
            if (!nativeTransition) return Fail(error, "provider_trigger_control_changed");
        }
    }
    for (const auto &metadata : before.metadata.packages) if (!after.metadata.packages.count(metadata.first) &&
        !changed.count(Generation(metadata.second.package))) {
        // An exact all/native replacement is independently checked by the
        // primary dpkg verifier; allow only its same-name refined generation.
        bool replaced = false;
        for (const auto &candidate : incoming) if (changed.count(candidate.first) &&
            candidate.second.package.package == metadata.second.package.package &&
            (candidate.second.package.architecture == "all" || metadata.second.package.architecture == "all")) replaced = true;
        if (!replaced) return Fail(error, "provider_trigger_control_changed");
    }
    return true;
}
}
std::string TriggerEffectCheckpointIdentity(const TriggerEffectCheckpoint &checkpoint) {
    Interests interests; std::string ignored, state;
    if (!Checkpoint(checkpoint, &interests, &ignored) || !StateBytes(checkpoint.packages, &state)) return "";
    std::string bytes("CYDIA-TRIGGER-EFFECT-CHECKPOINT-2");
    Frame(&bytes, checkpoint.packages.packageStateIdentity); Frame(&bytes, checkpoint.packages.nativeArchitecture);
    for (const auto &arch : checkpoint.packages.registeredArchitectures) Frame(&bytes, arch);
    Frame(&bytes, ""); Frame(&bytes, state); Frame(&bytes, checkpoint.registry.evidenceIdentity);
    Frame(&bytes, checkpoint.registry.state.canonicalIdentity); Frame(&bytes, checkpoint.metadata.evidenceIdentity);
    for (const auto &interest : checkpoint.registry.state.interests) {
        Frame(&bytes, interest.trigger); Frame(&bytes, interest.package); Frame(&bytes, interest.await ? "1" : "0");
    }
    Frame(&bytes, "");
    for (const auto &activation : checkpoint.registry.state.deferred) {
        Frame(&bytes, activation.trigger); Frame(&bytes, activation.noAwait ? "1" : "0");
        for (const auto &waiter : activation.awaiters) Frame(&bytes, waiter);
        Frame(&bytes, "");
    }
    Frame(&bytes, "");
    for (const auto &metadata : checkpoint.metadata.packages) { Frame(&bytes, metadata.first); MetadataBytes(&bytes, metadata.second); }
    return Hash(bytes);
}
bool BuildTriggerEffectEnvelope(const ReviewedTransaction &review, const TriggerEffectCheckpoint &checkpoint,
    TriggerEffectEnvelope *envelope, std::string *error, const std::string &nativeAuthorityIdentity) {
    if (!envelope) return Fail(error, "provider_trigger_envelope_invalid");
    *envelope = TriggerEffectEnvelope(); Interests interests;
    if (!Checkpoint(checkpoint, &interests, error) || checkpoint.identity != TriggerEffectCheckpointIdentity(checkpoint) ||
        checkpoint.identity.empty() || review.binding.packageStateIdentity != checkpoint.packages.packageStateIdentity ||
        review.execution.actions.size() > MaximumTriggerEffectPackages || review.execution.archives.size() > MaximumTriggerEffectPackages)
        return Fail(error, "provider_trigger_envelope_invalid");
    TriggerEffectEnvelope result; result.initialCheckpoint = checkpoint.identity; result.primaryReview = review;
    if (!nativeAuthorityIdentity.empty() && !Digest(nativeAuthorityIdentity)) return Fail(error, "provider_trigger_envelope_invalid");
    result.nativeAuthorityIdentity = nativeAuthorityIdentity;
    for (const auto &interest : checkpoint.registry.state.interests) {
        const auto &package = Resolve(checkpoint.packages, interest.package)->package;
        result.recipients.emplace(Generation(package), package);
    }
    std::set<std::uint64_t> actions; std::set<std::string> archives;
    for (const auto &archive : review.execution.archives) {
        if (!Package(archive.package) || !ValidIdentityToken(archive.identifier) || !archives.insert(archive.identifier).second ||
            !result.incoming.insert(Generation(archive.package)).second) return Fail(error, "provider_trigger_envelope_invalid");
        result.recipients.emplace(Generation(archive.package), archive.package);
    }
    result.awaiters = result.recipients;
    for (const auto &action : review.execution.actions) {
        if (!action.identifier || !actions.insert(action.identifier).second || !Package(action.package) ||
            action.action == ExecutionAction::Deconfigure || static_cast<unsigned>(action.action) > static_cast<unsigned>(ExecutionAction::Deconfigure))
            return Fail(error, "provider_trigger_envelope_invalid");
        if (action.action == ExecutionAction::Unpack) {
            bool found = false;
            for (const auto &archive : review.execution.archives)
                if (archive.identifier == action.archive && SamePackage(archive.package, action.package)) found = true;
            if (!found) return Fail(error, "provider_trigger_incoming_unverified");
        }
        result.awaiters.emplace(Generation(action.package), action.package);
        // The old exact generation can await a recipient during replacement.
        const auto previous = checkpoint.packages.packages.find(Key(action.package));
        if (previous != checkpoint.packages.packages.end() && Package(previous->second.package))
            result.awaiters.emplace(Generation(previous->second.package), previous->second.package);
    }
    for (const auto &record : checkpoint.packages.packages) if (!record.second.triggersAwaited.empty())
        result.awaiters.emplace(Generation(record.second.package), record.second.package);
    for (const auto &activation : checkpoint.registry.state.deferred) for (const auto &selector : activation.awaiters) {
        const auto waiter = Resolve(checkpoint.packages, selector);
        if (!waiter || !Package(waiter->package)) return Fail(error, "provider_trigger_awaiter_unresolved");
        result.awaiters.emplace(Generation(waiter->package), waiter->package);
    }
    if (result.recipients.size() > MaximumTriggerEffectPackages || result.awaiters.size() > MaximumTriggerEffectPackages ||
        !Graph(checkpoint, result, error)) return Fail(error, "provider_trigger_envelope_invalid");
    result.identity = EnvelopeIdentity(result);
    if (!Digest(result.identity)) return Fail(error, "provider_trigger_hash_failed");
    *envelope = std::move(result); if (error) error->clear(); return true;
}
bool TriggerEffectLedger::Reject(std::string *error, const char *code) {
    Invalidate(primary_.batch != 0 || pending_.pass != 0); return Fail(error, code);
}
void TriggerEffectLedger::Invalidate(bool uncertain) {
    active_ = false; uncertain_ = uncertain_ || uncertain; // Keep pending ownership until the caller settles/reaps its child.
}
bool TriggerEffectLedger::Begin(const TriggerEffectEnvelope &envelope, const TriggerEffectCheckpoint &checkpoint, std::string *error) {
    if (initialized_) return Reject(error, "provider_trigger_ledger_reused");
    initialized_ = true;
    TriggerEffectEnvelope actual;
    if (!BuildTriggerEffectEnvelope(envelope.primaryReview, checkpoint, &actual, error, envelope.nativeAuthorityIdentity) || actual.identity != envelope.identity ||
        EnvelopeIdentity(envelope) != envelope.identity) return Reject(error, "provider_trigger_envelope_changed");
    envelope_ = envelope; current_ = checkpoint; active_ = true;
    seenGraphs_.insert(GraphIdentity(current_)); if (error) error->clear(); return true;
}
bool TriggerEffectLedger::RefineIncoming(const std::vector<VerifiedArchiveControlEvidence> &observed, std::string *error) {
    if (!active_ || primary_.batch || pending_.pass || !primaryActions_.empty() || !incomingMetadata_.empty() ||
        observed.size() != envelope_.primaryReview.execution.archives.size()) return Reject(error, "provider_trigger_refinement_invalid");
    std::map<std::string, TriggerPackageMetadata> metadata; std::map<std::string, std::string> identities;
    for (const auto &item : observed) {
        const auto &archive = item.archive; const auto &control = item.control;
        const ArchiveManifest *expected = NULL;
        for (const auto &candidate : envelope_.primaryReview.execution.archives)
            if (candidate.identifier == archive.archive.identifier) expected = &candidate;
        std::string a, b;
        if (!expected || !Encode(*expected, &a) || !Encode(archive.archive, &b) || a != b ||
            archive.fileIdentity.empty() || !archive.inspection.complete || !archive.inspection.identityVerified ||
            (archive.inspection.status != CydiaPackages::ArchivePolicyStatus::Accepted &&
                archive.inspection.status != CydiaPackages::ArchivePolicyStatus::Unverified) ||
            !control.complete || !control.reason.empty() || control.identity.package != expected->package.package ||
            control.identity.version != expected->package.version || control.identity.architecture != expected->package.architecture ||
            (!control.triggersPresent && !control.triggers.empty())) return Reject(error, "provider_trigger_incoming_unverified");
        TriggerPackageMetadata value; value.package = expected->package;
        if (!CydiaPackages::CanonicalPackageEffectControlFields(control.controls, &value.controls, error) || value.controls != control.controls ||
            !ParseTriggerDeclarations(control.triggers, &value.declarations, error)) return Reject(error, "provider_trigger_incoming_unverified");
        value.evidenceIdentity = Hash(archive.fileIdentity + a);
        if (!metadata.emplace(Generation(value.package), value).second ||
            !identities.emplace(expected->identifier, archive.fileIdentity).second) return Reject(error, "provider_trigger_incoming_unverified");
    }
    incomingMetadata_ = std::move(metadata); incomingArchiveIdentities_ = std::move(identities);
    if (error) error->clear(); return true;
}
bool TriggerEffectLedger::PreparePrimary(const std::string &expected, const AuthorizedExecution &batch, std::string *error) {
    if (!active_ || primary_.batch || pending_.pass || expected != current_.identity || !batch.batch || batch.actions.empty() ||
        batch.action == ExecutionAction::Deconfigure || !Graph(current_, envelope_, error)) return Reject(error, "provider_trigger_primary_invalid");
    if (std::find(batch.arguments.begin(), batch.arguments.end(), "--no-triggers") == batch.arguments.end() ||
        std::find(batch.arguments.begin(), batch.arguments.end(), "--auto-deconfigure") != batch.arguments.end())
        return Reject(error, "provider_dpkg_effects_unknown");
    std::set<std::uint64_t> ids; std::set<std::string> targets;
    for (const auto id : batch.actions) {
        const ReviewedAction *action = NULL;
        for (const auto &candidate : envelope_.primaryReview.execution.actions) if (candidate.identifier == id) action = &candidate;
        if (!action || action->action != batch.action || primaryActions_.count(id) || !ids.insert(id).second)
            return Reject(error, "provider_trigger_primary_replayed");
        targets.insert(Generation(action->package));
        if (batch.action == ExecutionAction::Unpack) {
            const auto refined = incomingMetadata_.find(Generation(action->package)); bool proof = false;
            for (const auto &archive : batch.archives) if (archive.archive.identifier == action->archive &&
                incomingArchiveIdentities_.count(action->archive) && archive.fileIdentity == incomingArchiveIdentities_.at(action->archive) &&
                SamePackage(archive.archive.package, action->package)) proof = true;
            if (refined == incomingMetadata_.end() || !proof) return Reject(error, "provider_trigger_incoming_unverified");
        }
    }
    if (batch.action == ExecutionAction::Triggers) {
        std::vector<ExecutionPackage> pending;
        if (!DpkgPendingTargets(current_.packages, ExecutionAction::Triggers, &pending, error) || pending.empty() || pending.size() != targets.size())
            return Reject(error, "provider_trigger_targets_incomplete");
        for (const auto &package : pending) if (!targets.count(Generation(package))) return Reject(error, "provider_trigger_targets_incomplete");
    }
    primary_ = batch; if (error) error->clear(); return true;
}
bool TriggerEffectLedger::Reconcile(const AuthorizedExecution &batch, const ParentExecutionReply &reply,
    const TriggerEffectCheckpoint &next, std::string *error) {
    if (!active_ || !primary_.batch || !SameBatch(primary_, batch) || !Successful(reply) ||
        next.identity.empty() || next.identity != TriggerEffectCheckpointIdentity(next) || !Graph(next, envelope_, error))
        return Reject(error, "provider_trigger_primary_unsettled");
    std::set<std::string> changed, configured;
    for (const auto id : batch.actions) for (const auto &action : envelope_.primaryReview.execution.actions)
        if (action.identifier == id) {
            if (action.action == ExecutionAction::Unpack || action.action == ExecutionAction::Remove ||
                action.action == ExecutionAction::Purge) changed.insert(Generation(action.package));
            if (action.action == ExecutionAction::Configure) configured.insert(Generation(action.package));
        }
    const std::map<std::string, TriggerPackageMetadata> noIncoming;
    if (!UnchangedMetadata(current_, next, changed,
        batch.action == ExecutionAction::Unpack ? incomingMetadata_ : noIncoming, configured, error)) return Reject(error, "provider_trigger_control_changed");
    if (batch.action == ExecutionAction::Triggers) {
        if (!SameBase(current_.packages, next.packages) || seenGraphs_.count(GraphIdentity(next)))
            return Reject(error, "provider_trigger_drain_no_progress");
    } else if (!VerifyDpkgStateTransition(WithoutTriggers(current_.packages), WithoutTriggers(next.packages),
        envelope_.primaryReview, batch, error)) return Reject(error, "provider_trigger_primary_transition_invalid");
    primaryActions_.insert(batch.actions.begin(), batch.actions.end()); primary_ = AuthorizedExecution(); current_ = next;
    ++primaryCheckpoint_; checkpointPasses_ = 0; seenGraphs_.clear(); seenGraphs_.insert(GraphIdentity(current_));
    if (error) error->clear(); return true;
}
bool TriggerEffectLedger::NextDrain(const std::string &expected, TriggerDrainPlan *plan, std::string *error) {
    if (plan) *plan = TriggerDrainPlan();
    if (!plan || !active_ || primary_.batch || pending_.pass || expected != current_.identity ||
        checkpointPasses_ >= MaximumTriggerPassesPerCheckpoint || totalPasses_ >= MaximumTriggerPassesPerTransaction ||
        !Graph(current_, envelope_, error)) return Reject(error, "provider_trigger_drain_invalid");
    TriggerDrainPlan result; result.envelopeIdentity = envelope_.identity; result.checkpointIdentity = current_.identity;
    if (!DpkgPendingTargets(current_.packages, ExecutionAction::Triggers, &result.targets, error)) return Reject(error, "provider_trigger_state_unsettled");
    result.incorporateDeferred = !current_.registry.state.deferred.empty();
    if (result.targets.empty() && !result.incorporateDeferred) return Fail(error, "provider_trigger_no_pending_effects");
    result.pass = nextPass_++; result.primaryCheckpoint = primaryCheckpoint_; pending_ = result;
    ++checkpointPasses_; ++totalPasses_; *plan = result; if (error) error->clear(); return true;
}
bool TriggerEffectLedger::SettleDrain(std::uint64_t pass, const ParentExecutionReply &reply,
    const TriggerEffectCheckpoint &next, std::string *error) {
    if (!active_ || !pending_.pass || pass != pending_.pass || !Successful(reply) || next.identity.empty() ||
        next.identity != TriggerEffectCheckpointIdentity(next) || !Graph(next, envelope_, error) ||
        !SameBase(current_.packages, next.packages) || !UnchangedMetadata(current_, next, {}, {}, {}, error))
        return Reject(error, "provider_trigger_drain_unsettled");
    const auto graph = GraphIdentity(next);
    if (seenGraphs_.count(graph)) return Reject(error, "provider_trigger_drain_no_progress");
    seenGraphs_.insert(graph); current_ = next; pending_ = TriggerDrainPlan(); if (error) error->clear(); return true;
}
bool TriggerEffectLedger::quiescent() const {
    if (!active_ || primary_.batch || pending_.pass || !current_.registry.state.deferred.empty()) return false;
    for (const auto &record : current_.packages.packages)
        if (!record.second.triggersPending.empty() || !record.second.triggersAwaited.empty()) return false;
    return true;
}
}} // namespace CydiaAPT::Provider
