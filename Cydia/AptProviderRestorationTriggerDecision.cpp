/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderRestorationTriggerDecision.hpp"
namespace CydiaAPT { namespace Provider {
namespace {
bool Same(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.architecture == b.architecture && a.version == b.version;
}
}
bool SameRestorationCheckpoint(const RestorationCheckpoint &a, const RestorationCheckpoint &b) {
    if (a.identity != b.identity || a.deferredQueueEmpty != b.deferredQueueEmpty || a.packages.size() != b.packages.size()) return false;
    for (const auto &entry : a.packages) {
        const auto found = b.packages.find(entry.first);
        if (found == b.packages.end()) return false;
        const auto &x = entry.second, &y = found->second;
        if (x.present != y.present || x.reinstallRequired != y.reinstallRequired || !Same(x.package, y.package) ||
            x.selection != y.selection || x.status != y.status || x.diskStatus != y.diskStatus ||
            x.configVersion != y.configVersion || x.controlIdentity != y.controlIdentity || x.scriptsIdentity != y.scriptsIdentity ||
            x.contentIdentity != y.contentIdentity || x.scriptContentIdentity != y.scriptContentIdentity ||
            x.triggersPending != y.triggersPending || x.triggersAwaited != y.triggersAwaited) return false;
    }
    return true;
}
RestorationTriggerDecision DecideRestorationTriggerWork(const DeconfigurationAllowanceSet &approval,
    const RestorationDebtLedger &ledger, const TriggerEffectCheckpoint &checkpoint) {
    RestorationTriggerDecision result;
    result.reason = "provider_restoration_trigger_state_changed";
    if (!ledger.active() || ledger.stateIdentity() != checkpoint.identity || checkpoint.identity.empty() ||
        checkpoint.identity != TriggerEffectCheckpointIdentity(checkpoint) ||
        ledger.completedActions() > approval.primaryReview.execution.actions.size()) return result;
    bool unconfigured = false, pending = !checkpoint.registry.state.deferred.empty();
    for (const auto &item : checkpoint.packages.packages)
        pending = pending || !item.second.triggersPending.empty() || !item.second.triggersAwaited.empty();
    for (const auto &item : ledger.debts()) {
        const auto &debt = item.second;
        const auto found = checkpoint.packages.packages.find(debt.current.package + ':' + debt.current.architecture);
        if (found == checkpoint.packages.packages.end() || !Same(found->second.package, debt.current) ||
            found->second.reinstallRequired) return result;
        const auto phase = found->second.status;
        const auto metadata = checkpoint.metadata.packages.find(found->first);
        if (metadata == checkpoint.metadata.packages.end()) return result;
        const auto disk = metadata->second.diskStatus;
        if (debt.phase == RestorationDebtPhase::HalfConfigured) {
            if (phase != DpkgPackageStatus::HalfConfigured || disk != DpkgPackageStatus::HalfConfigured) return result;
            unconfigured = true;
        } else if (debt.phase == RestorationDebtPhase::SuccessorUnpacked) {
            if (phase != DpkgPackageStatus::Unpacked || disk != DpkgPackageStatus::Unpacked) return result;
            unconfigured = true;
        } else if (phase < DpkgPackageStatus::TriggersAwaited || disk < DpkgPackageStatus::TriggersAwaited ||
            !debt.configureAction) return result;
    }
    if (unconfigured && ledger.completedActions() == approval.primaryReview.execution.actions.size()) {
        result.reason = "provider_restoration_endpoint_missing"; return result;
    }
    // Processing healthy recipients can still depend on an unrestored debtor.
    // Preserve that genuine phase and use the next reviewed primary boundary;
    // never publish an Installed projection merely to make a drain pass.
    result.work = unconfigured ? RestorationTriggerWork::Defer :
        pending ? RestorationTriggerWork::Drain : RestorationTriggerWork::Quiescent;
    result.reason.clear(); return result;
}
}}
