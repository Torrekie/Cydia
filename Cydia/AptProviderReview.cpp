/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderReview.hpp"
#include <algorithm>
#include <limits>

namespace CydiaAPT { namespace Provider {
namespace {
bool Fail(std::string *error, const char *code) {
    if (error) *error = code;
    return false;
}
template<class T> bool Equal(const T &a, const T &b) {
    std::string left, right;
    return Encode(a, &left) && Encode(b, &right) && left == right;
}
std::string Key(const ExecutionPackage &package) {
    std::string key; Encode(package, &key); return key;
}
bool Text(const std::string &value, std::size_t maximum = 4096) {
    if (value.empty() || value.size() > maximum) return false;
    for (const unsigned char c : value) if (c < 32 || c == 127) return false;
    return true;
}
bool Path(const std::string &value) {
    if (!Text(value) || value.front() != '/' || value.find("//") != std::string::npos) return false;
    std::size_t start = 1;
    while (start < value.size()) {
        const auto end = value.find('/', start);
        const auto part = value.substr(start, end == std::string::npos ? end : end - start);
        if (part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return value == "/" || value.back() != '/';
}
bool Package(const ExecutionPackage &package) {
    const auto selector = ParsePackageSelector(package.package);
    const auto qualified = ParsePackageSelector(package.package + ':' + package.architecture);
    return selector.valid() && selector.kind == PackageSelectorKind::Default &&
        qualified.valid() && qualified.kind == PackageSelectorKind::ExactArchitecture &&
        Text(package.version, 1024) && package.version.find_first_not_of(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+:~-") == std::string::npos;
}
bool SameInstance(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && (a.architecture == b.architecture ||
        a.architecture == "all" || b.architecture == "all");
}
bool Layout(const CydiaPackages::ArchiveLayout &layout) {
    if (!Path(layout.prefix)) return false;
    std::set<std::string> paths;
    for (const auto &path : layout.foreignPrefixes)
        if (!Path(path) || path == "/" || !paths.insert(path).second) return false;
    return true;
}
bool Hashes(const std::map<std::string, std::string> &hashes) {
    bool strong = false;
    for (const auto &hash : hashes) {
        const std::size_t length = hash.first == "SHA512" ? 128 : hash.first == "SHA256" ? 64 :
            hash.first == "SHA1" ? 40 : hash.first == "MD5Sum" ? 32 : 0;
        if (!length || hash.second.size() != length ||
            hash.second.find_first_not_of("0123456789abcdef") != std::string::npos) return false;
        strong = strong || hash.first == "SHA512" || hash.first == "SHA256";
    }
    return strong;
}
bool URI(const std::string &value) {
    const auto colon = value.find(':');
    return Text(value) && value.find_first_of(" \t") == std::string::npos && colon != std::string::npos && colon != 0 &&
        value.substr(0, colon).find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789+.-") == std::string::npos;
}
bool Archive(const ArchiveManifest &archive, const ReviewPolicy &policy) {
    return ValidIdentityToken(archive.identifier) && Package(archive.package) &&
        URI(archive.sourceURI) && URI(archive.sourceIndexURI) &&
        archive.sourceIndexIdentity.size() == 71 && archive.sourceIndexIdentity.compare(0, 7, "SHA256:") == 0 &&
        archive.sourceIndexIdentity.find_first_not_of("0123456789abcdef", 7) == std::string::npos &&
        Path(archive.sourceDefinitionPath) && archive.sourceDefinitionPath != "/" &&
        Path(archive.sourceIndexPath) && archive.sourceIndexPath != "/" &&
        archive.sourceDefinitionOrdinal < MaximumCollectionItems &&
        archive.recordSize != 0 && archive.recordSize <= MaximumStringBytes &&
        archive.recordOffset <= std::numeric_limits<std::uint64_t>::max() - archive.recordSize &&
        Text(archive.filename) && archive.filename.find_first_of(" \t") == std::string::npos &&
        Path(archive.path) && archive.path != "/" &&
        archive.size != 0 && Hashes(archive.hashes) && Equal(archive.layout, policy.layout);
}

bool Decimal(const std::string &value) {
    return !value.empty() && value.size() <= 10 && value.find_first_not_of("0123456789") == std::string::npos;
}
// Protected options remain exact parent authority, but cannot smuggle another
// action, global selection or a second worker-controlled descriptor into argv.
bool ProtectedOptions(const std::vector<std::string> &options) {
    if (options.size() > 256) return false;
    for (std::size_t i = 0; i < options.size(); ++i) {
        const auto &option = options[i];
        if (!Text(option)) return false;
        const auto equal = option.find('=');
        const auto name = option.substr(0, equal);
        if (name == "--root" || name == "--instdir" || name == "--admindir" ||
            name == "--pre-invoke" || name == "--post-invoke") {
            const auto value = equal == std::string::npos ?
                (++i < options.size() ? options[i] : std::string()) : option.substr(equal + 1);
            if (!Text(value)) return false;
            if (name != "--pre-invoke" && name != "--post-invoke" && !Path(value)) return false;
        } else if (option != "--force-confnew" && option != "--force-confold" &&
                   option != "--force-confdef" && option != "--force-confmiss" && option != "--force-confask") return false;
    }
    return true;
}
struct ParsedBatch {
    ExecutionAction action = ExecutionAction::Unpack;
    bool pending = false, noTriggers = false, autoDeconfigure = false;
    std::vector<std::string> operands, arguments;
    std::size_t optionPrefixSize = 0, statusOptionIndex = 0;
};
bool ParseBatch(const ParentExecutionRequest &request, const ReviewPolicy &policy,
                int descriptor, ParsedBatch *parsed) {
    if (descriptor < 3 || request.arguments.size() > 100000 ||
        request.arguments.size() < policy.protectedDpkgOptions.size() ||
        !std::equal(policy.protectedDpkgOptions.begin(), policy.protectedDpkgOptions.end(), request.arguments.begin())) return false;
    ParsedBatch value; value.arguments = request.arguments; value.optionPrefixSize = request.arguments.size();
    bool action = false, status = false, operands = false, forceDepends = false, abortOne = false;
    std::size_t bytes = 0;
    for (const auto &argument : request.arguments) {
        if (!Text(argument) || bytes > 1024 * 1024 - argument.size()) return false;
        bytes += argument.size();
    }
    for (std::size_t i = policy.protectedDpkgOptions.size(); i < request.arguments.size(); ++i) {
        const auto &argument = request.arguments[i];
        if (argument == "--" && !operands) { value.optionPrefixSize = i + 1; operands = true; continue; }
        if (!operands && argument.compare(0, 2, "--") == 0) {
            ExecutionAction kind;
            bool isAction = true;
            if (argument == "--unpack") kind = ExecutionAction::Unpack;
            else if (argument == "--configure") kind = ExecutionAction::Configure;
            else if (argument == "--remove") kind = ExecutionAction::Remove;
            else if (argument == "--purge") kind = ExecutionAction::Purge;
            else if (argument == "--triggers-only") kind = ExecutionAction::Triggers;
            else isAction = false;
            if (isAction) { if (action) return false; action = true; value.action = kind; continue; }
            if (argument == "--status-fd" || argument.compare(0, 12, "--status-fd=") == 0) {
                if (status) return false;
                status = true; value.statusOptionIndex = i;
                if (argument == "--status-fd") {
                    if (++i == request.arguments.size() || !Decimal(request.arguments[i])) return false;
                    value.arguments[i] = std::to_string(descriptor);
                } else {
                    if (!Decimal(argument.substr(12))) return false;
                    value.arguments[i] = "--status-fd=" + std::to_string(descriptor);
                }
            } else if (argument == "--no-triggers" && !value.noTriggers) value.noTriggers = true;
            else if (argument == "--auto-deconfigure" && !value.autoDeconfigure) value.autoDeconfigure = true;
            else if (argument == "--pending" && !value.pending) value.pending = true;
            else if (argument == "--force-depends" && !forceDepends) forceDepends = true;
            else if (argument == "--abort-after=1" && !abortOne) abortOne = true;
            else return false;
        } else {
            if (!operands) value.optionPrefixSize = i;
            operands = true;
            if (argument.front() == '-') return false;
            value.operands.push_back(argument);
        }
    }
    if (!action || !status || value.action != request.action ||
        (value.pending && (!value.operands.empty() || value.action == ExecutionAction::Unpack)) ||
        (!value.pending && value.operands.empty()) ||
        (value.autoDeconfigure && value.action != ExecutionAction::Unpack) ||
        ((forceDepends || abortOne) && value.action != ExecutionAction::Remove && value.action != ExecutionAction::Purge)) return false;
    *parsed = std::move(value); return true;
}
bool PackageSet(const std::vector<ExecutionPackage> &packages, std::set<std::string> *keys) {
    keys->clear();
    for (const auto &package : packages)
        if (!Package(package) || !keys->insert(Key(package)).second) return false;
    return true;
}
}

void ReviewAuthorization::Invalidate() {
    active_ = false; actions_.clear(); archives_.clear(); completed_.clear();
    pending_ = AuthorizedExecution(); stateIdentity_.clear(); nextBatch_ = 1;
}

bool ReviewAuthorization::Accept(const ReviewedTransaction &review, const ReviewPolicy &policy, std::string *error) {
    Invalidate();
    Message bound; bound.sequence = 1; bound.kind = MessageKind::ParentRequest;
    bound.operation = Operation::ExecuteDpkg; bound.binding = review.binding;
    if (!ValidRequestBinding(bound) || !ValidEnvironment(policy.environment) || !Layout(policy.layout) ||
        review.binding.configurationIdentity != policy.environment.configurationIdentity ||
        review.binding.policyIdentity != policy.environment.policyIdentity ||
        review.binding.packageStateIdentity != policy.environment.packageStateIdentity ||
        review.transaction.registeredArchitectures != policy.environment.registeredArchitectures ||
        !review.transaction.issues.empty() || review.transaction.removesEssential ||
        !ProtectedOptions(policy.protectedDpkgOptions) || review.execution.actions.empty() ||
        review.execution.actions.size() > MaximumCollectionItems ||
        review.execution.archives.size() > MaximumCollectionItems) return Fail(error, "provider_invalid_execution_review");
    std::map<std::string, ExecutionAction> plan;
    std::set<std::string> routes;
    const auto add = [&](const std::vector<std::string> &names, ExecutionAction action) {
        for (const auto &name : names) {
            const auto entry = review.transaction.packages.find(name);
            if (entry == review.transaction.packages.end() || !routes.insert(name).second) return false;
            const auto &identity = entry->second.identity;
            ExecutionPackage package{identity.baseName, entry->second.version, identity.versionArchitecture};
            const auto canonical = BuildPackageIdentity(identity.baseName, identity.packageArchitecture,
                identity.versionArchitecture, policy.environment.nativeArchitecture, identity.multiArch);
            if (!Package(package) || !Equal(identity, canonical) || identity.routingName != name ||
                !plan.emplace(Key(package), action).second) return false;
        }
        return true;
    };
    if (!add(review.transaction.installs, ExecutionAction::Unpack) ||
        !add(review.transaction.reinstalls, ExecutionAction::Unpack) ||
        !add(review.transaction.upgrades, ExecutionAction::Unpack) ||
        !add(review.transaction.downgrades, ExecutionAction::Unpack) ||
        !add(review.transaction.removes, ExecutionAction::Remove) ||
        !add(review.transaction.purges, ExecutionAction::Purge) ||
        routes.size() != review.transaction.packages.size()) return Fail(error, "provider_inconsistent_review_packages");
    std::map<std::string, ArchiveManifest> archives;
    std::set<std::string> paths;
    for (const auto &archive : review.execution.archives)
        if (!Archive(archive, policy) || !archives.emplace(archive.identifier, archive).second ||
            !paths.insert(archive.path).second) return Fail(error, "provider_invalid_archive_manifest");
    std::map<std::uint64_t, ReviewedAction> actions;
    std::set<std::string> usedArchives, covered, configured, uniqueActions;
    std::map<std::string, std::size_t> unpackOrder, configureOrder, removeOrder, purgeOrder;
    std::size_t position = 0;
    for (const auto &action : review.execution.actions) {
        if (!action.identifier || !Package(action.package) ||
            static_cast<unsigned>(action.action) > static_cast<unsigned>(ExecutionAction::Deconfigure) ||
            !actions.emplace(action.identifier, action).second) return Fail(error, "provider_invalid_action_manifest");
        if (action.action != ExecutionAction::Triggers &&
            !uniqueActions.insert(std::to_string(static_cast<unsigned>(action.action)) + Key(action.package)).second)
            return Fail(error, "provider_duplicate_review_action");
        const auto planned = plan.find(Key(action.package));
        const bool primary = planned != plan.end() &&
            (action.action == planned->second || (planned->second == ExecutionAction::Unpack &&
                action.action == ExecutionAction::Configure) || (planned->second == ExecutionAction::Purge &&
                action.action == ExecutionAction::Remove));
        if (!primary && !policy.additionalActionsReviewed.count(action.identifier))
            return Fail(error, "provider_action_not_reviewed");
        if (primary && action.action == planned->second)
            covered.insert(planned->first);
        if (primary && action.action == ExecutionAction::Configure) configured.insert(planned->first);
        switch (action.action) {
            case ExecutionAction::Unpack: unpackOrder[Key(action.package)] = position; break;
            case ExecutionAction::Configure: configureOrder[Key(action.package)] = position; break;
            case ExecutionAction::Remove: removeOrder[Key(action.package)] = position; break;
            case ExecutionAction::Purge: purgeOrder[Key(action.package)] = position; break;
            default: break;
        }
        ++position;
        if (action.action == ExecutionAction::Unpack) {
            const auto archive = archives.find(action.archive);
            if (!primary || archive == archives.end() || !Equal(archive->second.package, action.package) ||
                (action.package.architecture != "all" && std::find(policy.environment.registeredArchitectures.begin(),
                    policy.environment.registeredArchitectures.end(), action.package.architecture) == policy.environment.registeredArchitectures.end()))
                return Fail(error, "provider_unreviewed_unpack");
            usedArchives.insert(action.archive);
        } else if (!action.archive.empty()) return Fail(error, "provider_unexpected_archive_reference");
    }
    for (const auto id : policy.additionalActionsReviewed)
        if (!actions.count(id)) return Fail(error, "provider_unknown_additional_action");
    for (const auto &id : policy.unverifiedArchiveWarningsAccepted)
        if (!archives.count(id)) return Fail(error, "provider_unknown_archive_warning");
    if (covered.size() != plan.size() || usedArchives.size() != archives.size())
        return Fail(error, "provider_incomplete_execution_manifest");
    for (const auto &package : plan)
        if (package.second == ExecutionAction::Unpack && !configured.count(package.first))
            return Fail(error, "provider_missing_configure_action");
    for (const auto &unpack : unpackOrder) {
        const auto configure = configureOrder.find(unpack.first);
        if (configure == configureOrder.end() || configure->second <= unpack.second)
            return Fail(error, "provider_invalid_install_order");
    }
    for (const auto &purge : purgeOrder) {
        const auto remove = removeOrder.find(purge.first);
        if (remove != removeOrder.end() && remove->second >= purge.second)
            return Fail(error, "provider_invalid_purge_order");
    }
    review_ = review; policy_ = policy; actions_ = std::move(actions); archives_ = std::move(archives);
    stateIdentity_ = review.binding.packageStateIdentity; active_ = true;
    if (error) error->clear();
    return true;
}

bool ReviewAuthorization::Authorize(const ParentExecutionRequest &request, const ParentExecutionEvidence &evidence,
                                    AuthorizedExecution *authorized, std::string *error) {
    if (!authorized || !active_ || pending_.batch || request.batch != nextBatch_ || request.actions.size() > MaximumCollectionItems ||
        nextBatch_ == std::numeric_limits<std::uint64_t>::max() ||
        !SameBinding(request.binding, review_.binding) || !SameBinding(evidence.binding, review_.binding) ||
        !evidence.frontendLockHeld || !evidence.stateVerified || evidence.stateIdentity != stateIdentity_)
        return Fail(error, "provider_execution_state_changed");
    ParsedBatch parsed;
    if (!ParseBatch(request, policy_, evidence.statusDescriptor, &parsed))
        return Fail(error, "provider_unsupported_dpkg_batch");
    AuthorizedExecution result; result.batch = request.batch; result.action = request.action;
    result.arguments = parsed.arguments;
    result.optionPrefixSize = parsed.optionPrefixSize; result.statusOptionIndex = parsed.statusOptionIndex;
    std::set<std::uint64_t> selected;
    std::set<std::string> packages;
    std::vector<const ReviewedAction *> ordered;
    for (const auto id : request.actions) {
        const auto found = actions_.find(id);
        if (found == actions_.end() || found->second.action != request.action || completed_.count(id) ||
            !selected.insert(id).second || !packages.insert(Key(found->second.package)).second)
            return Fail(error, "provider_unreviewed_batch_target");
        ordered.push_back(&found->second);
    }
    if (parsed.pending) {
        std::set<std::string> pending;
        if (!evidence.pendingTargetsKnown || !PackageSet(evidence.pendingTargets, &pending) || pending != packages)
            return Fail(error, "provider_pending_targets_changed");
    } else {
        if (parsed.operands.size() != ordered.size()) return Fail(error, "provider_batch_operands_changed");
        for (std::size_t i = 0; i < ordered.size(); ++i) {
            const auto &action = *ordered[i];
            const auto &operand = parsed.operands[i];
            if (action.action == ExecutionAction::Unpack) {
                if (operand != archives_.at(action.archive).path) return Fail(error, "provider_archive_path_changed");
            } else if (operand != action.package.package + ':' + action.package.architecture) {
                if (operand != action.package.package) return Fail(error, "provider_batch_package_changed");
                const auto resolved = evidence.barePackageTargets.find(operand);
                if (resolved == evidence.barePackageTargets.end() || !Equal(resolved->second, action.package))
                    return Fail(error, "provider_ambiguous_dpkg_name");
            }
        }
    }
    const auto remaining = [&](ExecutionAction kind, const ExecutionPackage &package) -> std::uint64_t {
        for (const auto &action : review_.execution.actions)
            if (action.action == kind && Equal(action.package, package) && !completed_.count(action.identifier))
                return action.identifier;
        return 0;
    };
    std::set<std::string> effects;
    if (parsed.autoDeconfigure) {
        if (!evidence.deconfigurationTargetsKnown || !PackageSet(evidence.deconfigurationTargets, &effects))
            return Fail(error, "provider_deconfiguration_unknown");
        for (const auto &package : evidence.deconfigurationTargets)
        {
            const auto id = remaining(ExecutionAction::Deconfigure, package);
            // The deconfigured installed version may be replaced before its
            // eventual configure. Review that old exact identity separately,
            // and require a remaining configure of the same package instance.
            bool restored = false;
            for (const auto &action : review_.execution.actions)
                if (action.action == ExecutionAction::Configure && SameInstance(action.package, package) &&
                    !completed_.count(action.identifier)) restored = true;
            if (!id || !restored) return Fail(error, "provider_deconfiguration_not_reviewed");
            selected.insert(id);
        }
    } else if (!evidence.deconfigurationTargets.empty()) return Fail(error, "provider_unexpected_deconfiguration");
    if (!parsed.noTriggers) {
        if (!evidence.triggerTargetsKnown || !PackageSet(evidence.triggerTargets, &effects))
            return Fail(error, "provider_trigger_targets_unknown");
        for (const auto &package : evidence.triggerTargets) {
            const auto id = remaining(ExecutionAction::Triggers, package);
            if (!id) return Fail(error, "provider_trigger_not_reviewed");
            selected.insert(id);
        }
    } else if (!evidence.triggerTargets.empty()) return Fail(error, "provider_unexpected_trigger");
    for (const auto id : selected) {
        const auto &action = actions_.at(id);
        for (const auto &prior : review_.execution.actions) {
            if (prior.identifier == id) break;
            if (SameInstance(prior.package, action.package) && !completed_.count(prior.identifier) &&
                !selected.count(prior.identifier)) return Fail(error, "provider_batch_out_of_order");
        }
    }
    std::vector<ArchiveManifest> neededArchives;
    for (const auto action : ordered) if (action->action == ExecutionAction::Unpack) {
        neededArchives.push_back(archives_.at(action->archive));
    }
    if (!VerifyReviewedArchiveEvidence(neededArchives, evidence.archives,
        policy_.unverifiedArchiveWarningsAccepted, error)) return false;
    for (const auto &archive : neededArchives)
        for (const auto &checked : evidence.archives)
            if (checked.archive.identifier == archive.identifier) result.archives.push_back(checked);
    result.actions.assign(selected.begin(), selected.end());
    pending_ = result; ++nextBatch_; *authorized = std::move(result);
    if (error) error->clear();
    return true;
}

bool VerifyReviewedArchiveEvidence(const std::vector<ArchiveManifest> &expected,
    const std::vector<VerifiedArchiveEvidence> &observed,
    const std::set<std::string> &approvedWarnings, std::string *error) {
    if (expected.size() > MaximumCollectionItems || observed.size() > MaximumCollectionItems)
        return Fail(error, "provider_invalid_archive_manifest");
    std::map<std::string, const VerifiedArchiveEvidence *> evidence;
    for (const auto &archive : observed)
        if (!evidence.emplace(archive.archive.identifier, &archive).second)
            return Fail(error, "provider_duplicate_archive_evidence");
    std::set<std::string> requested;
    for (const auto &archive : expected) {
        if (!requested.insert(archive.identifier).second)
            return Fail(error, "provider_invalid_archive_manifest");
        const auto found = evidence.find(archive.identifier);
        if (found == evidence.end()) return Fail(error, "provider_archive_evidence_missing");
        const auto &checked = *found->second;
        const auto &inspection = checked.inspection;
        const bool allowed = inspection.status == CydiaPackages::ArchivePolicyStatus::Accepted ||
            (inspection.status == CydiaPackages::ArchivePolicyStatus::Unverified && approvedWarnings.count(archive.identifier));
        if (!Equal(archive, checked.archive) || !ValidIdentityToken(checked.fileIdentity) ||
            !inspection.identityVerified || !inspection.complete || !allowed)
            return Fail(error, "provider_archive_evidence_changed");
    }
    if (requested.size() != evidence.size()) return Fail(error, "provider_unexpected_archive_evidence");
    if (error) error->clear();
    return true;
}

bool ReviewAuthorization::Settle(std::uint64_t batch, const ParentExecutionReply &result,
                                 const std::string &nextStateIdentity, bool stateTransitionVerified, std::string *error) {
    if (!active_ || !pending_.batch || batch != pending_.batch)
        return Fail(error, "provider_unknown_execution_batch");
    if (!result.started || result.exitCode != 0 || result.signal != 0 || result.launchError != 0 ||
        !stateTransitionVerified || !ValidIdentityToken(nextStateIdentity)) {
        Invalidate(); return Fail(error, "provider_execution_requires_new_review");
    }
    completed_.insert(pending_.actions.begin(), pending_.actions.end());
    stateIdentity_ = nextStateIdentity; pending_ = AuthorizedExecution();
    if (error) error->clear();
    return true;
}
bool ReviewAuthorization::AdvanceEffects(const std::string &expected, const std::string &next,
    bool verified, std::string *error) {
    if (!active_ || pending_.batch || expected != stateIdentity_ || !verified || !ValidIdentityToken(next)) {
        Invalidate(); return Fail(error, "provider_execution_requires_new_review");
    }
    stateIdentity_ = next; if (error) error->clear(); return true;
}

}} // namespace CydiaAPT::Provider
