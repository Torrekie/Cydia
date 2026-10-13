/* Pure parent projections; no execution or privileged evidence production.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderConditionalDeconfiguration.hpp"
#include <algorithm>

namespace CydiaAPT { namespace Provider {
namespace {
bool Fail(std::string *error, const char *code) {
    if (error) *error = code;
    return false;
}
bool Digest(const std::string &s) { return s.size() == 64 && s.find_first_not_of("0123456789abcdef") == std::string::npos; }
std::string Slot(const ExecutionPackage &p) { return p.package + ':' + p.architecture; }
std::string Generation(const ExecutionPackage &p) { return Slot(p) + '@' + p.version; }
bool Same(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.version == b.version && a.architecture == b.architecture;
}
bool SameCause(const DeconfigurationCause &a, const DeconfigurationCause &b) {
    return a.kind == b.kind && a.unpackAction == b.unpackAction && a.archive == b.archive &&
        a.canonicalRelation == b.canonicalRelation && a.comparedVersion == b.comparedVersion &&
        a.group == b.group && a.alternative == b.alternative && a.provide == b.provide;
}
bool SameReview(const ReviewedTransaction &a, const ReviewedTransaction &b) {
    std::string x, y; return Encode(a, &x) && Encode(b, &y) && x == y;
}
bool Option(const std::vector<std::string> &arguments, const std::string &value) {
    return std::find(arguments.begin(), arguments.end(), value) != arguments.end();
}
bool Scope(const DeconfigurationAllowanceSet &approval, const AuthorizedExecution &batch,
    const DpkgState &state, const std::string &checkpoint, const ConditionalDeconfigurationAdmission &admission,
    std::string *error) {
    std::string encoded;
    if (!EncodeDeconfigurationApproval(approval, &encoded, error) || !batch.batch || batch.actions.empty() ||
        batch.actions.size() > MaximumDeconfigurationActions || batch.archives.size() > MaximumDeconfigurationActions ||
        batch.conditionalDeconfigurationIdentity != approval.identity || admission.approvalIdentity != approval.identity ||
        !Digest(checkpoint) || state.packageStateIdentity.empty() ||
        state.registeredArchitectures != approval.primaryReview.transaction.registeredArchitectures ||
        admission.checkpointIdentity != checkpoint ||
        admission.stateIdentity != state.packageStateIdentity ||
        admission.batch != batch.batch || admission.actions != batch.actions ||
        admission.causes.size() > MaximumDeconfigurationCauses || !Option(batch.arguments, "--no-triggers"))
        return Fail(error, "provider_conditional_scope_changed");
    std::set<std::uint64_t> ids; std::set<std::string> neededArchives;
    for (const auto id : batch.actions) {
        const auto action = std::find_if(approval.primaryReview.execution.actions.begin(), approval.primaryReview.execution.actions.end(),
            [&](const ReviewedAction &a) { return a.identifier == id; });
        if (!ids.insert(id).second || action == approval.primaryReview.execution.actions.end() || action->action != batch.action)
            return Fail(error, "provider_conditional_primary_changed");
        if (batch.action == ExecutionAction::Unpack) neededArchives.insert(action->archive);
    }
    if (batch.archives.size() != neededArchives.size()) return Fail(error, "provider_conditional_primary_changed");
    for (const auto &archive : batch.archives) {
        const auto expected = std::find_if(approval.primaryReview.execution.archives.begin(), approval.primaryReview.execution.archives.end(),
            [&](const ArchiveManifest &a) { return a.identifier == archive.archive.identifier; });
        std::string first, second;
        if (!neededArchives.erase(archive.archive.identifier) || expected == approval.primaryReview.execution.archives.end() ||
            !ValidIdentityToken(archive.fileIdentity) || !Encode(*expected, &first) || !Encode(archive.archive, &second) || first != second)
            return Fail(error, "provider_conditional_primary_changed");
    }
    if (batch.action == ExecutionAction::Deconfigure || batch.action == ExecutionAction::Triggers ||
        (batch.action != ExecutionAction::Unpack && (!admission.causes.empty() || Option(batch.arguments, "--auto-deconfigure"))))
        return Fail(error, "provider_conditional_primary_changed");
    return true;
}
bool Projection(const DpkgState &state, const RestorationCheckpoint &point, const DeconfigurationAllowanceSet &approval,
    std::set<std::string> *slots, std::string *error) {
    if (!Digest(point.identity) || point.packages.size() != approval.allowances.size())
        return Fail(error, "provider_conditional_projection_changed");
    for (const auto &entry : approval.allowances) {
        const auto slot = Slot(entry.second.installed); const auto observation = point.packages.find(slot);
        if (!slots->insert(slot).second || observation == point.packages.end())
            return Fail(error, "provider_conditional_projection_changed");
        const auto row = state.packages.find(slot); const auto &o = observation->second;
        // A forgotten wanted-selection has no architecture/version generation.
        // Its exact remaining row is still checked by the full ordinary state
        // verifier; this projection must never invent an installed generation.
        if (!o.present) {
            if (row != state.packages.end()) return Fail(error, "provider_conditional_projection_changed");
            continue;
        }
        if (row == state.packages.end() || !Same(row->second.package, o.package) || row->second.selection != o.selection ||
            row->second.status != o.status || row->second.reinstallRequired != o.reinstallRequired ||
            row->second.triggersPending != o.triggersPending || row->second.triggersAwaited != o.triggersAwaited)
            return Fail(error, "provider_conditional_projection_changed");
    }
    return true;
}
}
bool ValidateConditionalDeconfigurationAdmission(const DeconfigurationAllowanceSet &approval,
    const AuthorizedExecution &batch, const DpkgState &state, const std::string &expectedCheckpoint,
    const ConditionalDeconfigurationAdmission &admission, std::string *error) {
    if (error) error->clear();
    if (!Scope(approval, batch, state, expectedCheckpoint, admission, error)) return false;
    std::set<std::string> generations; std::size_t causeBytes = 0;
    for (const auto &observation : admission.causes) {
        for (const auto *value : {&observation.installed.package, &observation.installed.version, &observation.installed.architecture,
            &observation.cause.archive, &observation.cause.canonicalRelation, &observation.cause.comparedVersion}) {
            if (value->size() > MaximumDeconfigurationApprovalBytes - causeBytes)
                return Fail(error, "provider_conditional_cause_limit");
            causeBytes += value->size();
        }
        const auto generation = Generation(observation.installed); const auto allowance = approval.allowances.find(generation);
        const auto row = state.packages.find(Slot(observation.installed)); const auto &cause = observation.cause;
        if (!generations.insert(generation).second || allowance == approval.allowances.end() || row == state.packages.end() ||
            !Same(allowance->second.installed, observation.installed) || !Same(row->second.package, observation.installed) ||
            row->second.reinstallRequired || row->second.status <= DpkgPackageStatus::HalfConfigured ||
            row->second.selection != allowance->second.selection ||
            std::find(batch.actions.begin(), batch.actions.end(), cause.unpackAction) == batch.actions.end() ||
            std::none_of(allowance->second.causes.begin(), allowance->second.causes.end(),
                [&](const DeconfigurationCause &approved) { return SameCause(approved, cause); }))
            return Fail(error, "provider_conditional_cause_unapproved");
        // Creation and successor Unpack need an observed old HalfConfigured
        // boundary, never two inferred stages hidden inside one native child.
        if (allowance->second.endpoint.precedingUnpack && std::find(batch.actions.begin(), batch.actions.end(),
            allowance->second.endpoint.precedingUnpack) != batch.actions.end())
            return Fail(error, "provider_conditional_fresh_boundary_required");
    }
    return true;
}
bool ValidateConditionalDeconfigurationTransition(const DpkgState &before, const DpkgState &after,
    const ReviewedTransaction &review, const AuthorizedExecution &batch, const DeconfigurationAllowanceSet &approval,
    const RestorationDebtLedger &prepared, const ConditionalDeconfigurationTransition &transition,
    std::set<std::string> *restorationSlots, std::string *error) {
    if (error) error->clear();
    if (!restorationSlots) return Fail(error, "provider_conditional_projection_changed");
    restorationSlots->clear(); std::set<std::string> beforeSlots, afterSlots;
    if (!SameReview(review, approval.primaryReview) || !prepared.active() || prepared.stateIdentity() != transition.before.identity ||
        !prepared.AuthorizeCheckpoint(approval, transition.before, error) ||
        !ValidateConditionalDeconfigurationAdmission(approval, batch, before, transition.before.identity, transition.admission, error) ||
        !Projection(before, transition.before, approval, &beforeSlots, error) ||
        !Projection(after, transition.after, approval, &afterSlots, error) || beforeSlots != afterSlots) {
        if (!error || error->empty()) return Fail(error, "provider_conditional_scope_changed");
        return false;
    }
    std::set<std::string> observed;
    for (const auto &cause : transition.admission.causes) {
        const auto slot = Slot(cause.installed); const auto &now = transition.after.packages.at(slot);
        if (!now.present || !Same(now.package, cause.installed) || now.status != DpkgPackageStatus::HalfConfigured ||
            now.diskStatus != DpkgPackageStatus::HalfConfigured)
            return Fail(error, "provider_conditional_effect_unobserved");
        observed.insert(Generation(cause.installed));
    }
    for (const auto &entry : approval.allowances) {
        const auto slot = Slot(entry.second.installed); const auto &old = transition.before.packages.at(slot), &now = transition.after.packages.at(slot);
        if (old.present && now.present && Same(old.package, entry.second.installed) && Same(now.package, entry.second.installed) &&
            old.status > DpkgPackageStatus::HalfConfigured && now.status == DpkgPackageStatus::HalfConfigured &&
            !observed.count(entry.first)) return Fail(error, "provider_conditional_effect_unapproved");
    }
    for (const auto &entry : approval.allowances) {
        const auto slot = Slot(entry.second.installed); const auto old = before.packages.find(slot), now = after.packages.find(slot);
        const auto target = std::find_if(review.execution.actions.begin(), review.execution.actions.end(), [&](const ReviewedAction &a) {
            return a.action == ExecutionAction::Unpack && Slot(a.package) == slot &&
                std::find(batch.actions.begin(), batch.actions.end(), a.identifier) != batch.actions.end();
        });
        if (target != review.execution.actions.end()) {
            const auto proof = std::find_if(transition.successors.begin(), transition.successors.end(), [&](const RestorationSuccessorProof &p) {
                return p.oldGeneration == entry.first && p.unpackAction == target->identifier;
            });
            if (proof == transition.successors.end() || now == after.packages.end() ||
                (proof->installedMultiArch != "no" && proof->installedMultiArch != "same" &&
                 proof->installedMultiArch != "foreign" && proof->installedMultiArch != "allowed") ||
                proof->installedMultiArch != (now->second.multiArch.empty() ? "no" : now->second.multiArch))
                return Fail(error, "provider_conditional_multiarch_unverified");
        } else if (old != before.packages.end() && now != after.packages.end() && old->second.multiArch != now->second.multiArch)
            return Fail(error, "provider_conditional_multiarch_changed");
    }
    auto trial = prepared;
    if (!trial.SettlePrimary(batch.batch, transition.child, transition.after, transition.successors, error)) return false;
    *restorationSlots = std::move(beforeSlots); return true;
}
}}
