/* Pure bookkeeping only; every observation/proof must come from the parent.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderRestorationDebt.hpp"
#include <algorithm>
#include <set>

namespace CydiaAPT { namespace Provider {
namespace {
using Phase = DpkgPackageStatus;
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Digest(const std::string &s) { return s.size() == 64 && s.find_first_not_of("0123456789abcdef") == std::string::npos; }
std::string Slot(const ExecutionPackage &p) { return p.package + ':' + p.architecture; }
bool Same(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.version == b.version && a.architecture == b.architecture;
}
bool Package(const ExecutionPackage &p) {
    std::shared_ptr<const BinaryRelationships::Package> value; BinaryRelationships::Error error;
    return BinaryRelationships::ParsePackage(p.package, p.version, p.architecture, "no", "", &value, &error);
}
bool TriggerPhase(Phase p) { return p >= Phase::TriggersAwaited && p <= Phase::Installed; }
bool UnpackedPhase(Phase p) { return p == Phase::Unpacked || p == Phase::TriggersAwaited || p == Phase::TriggersPending; }
bool Successful(const RestorationChildResult &r) {
    return r.child.started && r.child.exitCode == 0 && r.child.signal == 0 && r.child.launchError == 0 && !r.cancelled && !r.uncertain;
}
bool EmptyTriggers(const RestorationObservation &o) { return o.triggersPending.empty() && o.triggersAwaited.empty(); }
bool SameContent(const RestorationObservation &a, const RestorationObservation &b) {
    return a.present && b.present && Same(a.package, b.package) && a.contentIdentity == b.contentIdentity &&
        a.scriptContentIdentity == b.scriptContentIdentity && a.selection == b.selection && a.reinstallRequired == b.reinstallRequired;
}
bool SameHistory(const RestorationObservation &a, const RestorationObservation &b) {
    return a.configVersion == b.configVersion && a.diskStatus == b.diskStatus &&
        a.controlIdentity == b.controlIdentity && a.scriptsIdentity == b.scriptsIdentity;
}
bool SameObservation(const RestorationObservation &a, const RestorationObservation &b) {
    if (!a.present || !b.present) return a.present == b.present;
    return SameContent(a, b) && SameHistory(a, b) && a.status == b.status &&
        a.triggersPending == b.triggersPending && a.triggersAwaited == b.triggersAwaited;
}
bool HistoryAfterConfigure(const RestorationObservation &old, const RestorationObservation &now) {
    // Native post_postinst_tasks can leave the old Config-Version while
    // awaited; installed/pending parsing synthesizes the current Version.
    return now.configVersion == ((now.diskStatus == Phase::Installed || now.diskStatus == Phase::TriggersPending) ?
        now.package.version : old.configVersion);
}
bool Settled(const RestorationObservation &o, const RestorationCheckpoint &point) {
    return o.present && o.status == Phase::Installed && o.diskStatus == Phase::Installed &&
        o.configVersion == o.package.version && !o.reinstallRequired && EmptyTriggers(o) && point.deferredQueueEmpty;
}
bool ObservationShape(const RestorationObservation &o, std::size_t *bytes) {
    const auto add = [&](const std::string &s) {
        if (s.size() > 65536 || s.find('\0') != std::string::npos || s.size() + 32 > MaximumRestorationObservationBytes - *bytes) return false;
        *bytes += s.size() + 32; return true;
    };
    if (!o.present) return !o.reinstallRequired && o.package.package.empty() && o.package.version.empty() && o.package.architecture.empty() &&
        o.selection == DpkgSelection::Unknown && o.status == Phase::NotInstalled && o.diskStatus == Phase::NotInstalled &&
        o.configVersion.empty() && o.controlIdentity.empty() && o.scriptsIdentity.empty() && o.contentIdentity.empty() &&
        o.scriptContentIdentity.empty() && EmptyTriggers(o);
    if (!Package(o.package) || static_cast<unsigned>(o.selection) > static_cast<unsigned>(DpkgSelection::Purge) ||
        static_cast<unsigned>(o.status) > static_cast<unsigned>(Phase::Installed) || static_cast<unsigned>(o.diskStatus) > static_cast<unsigned>(Phase::Installed) ||
        o.reinstallRequired || !Digest(o.controlIdentity) || !Digest(o.scriptsIdentity) || !Digest(o.contentIdentity) || !Digest(o.scriptContentIdentity) ||
        (!o.configVersion.empty() && !BinaryRelationships::ValidVersion(o.configVersion))) return false;
    if ((o.diskStatus == Phase::Installed || o.diskStatus == Phase::TriggersPending) && o.configVersion != o.package.version) return false;
    if (o.diskStatus == Phase::NotInstalled && !o.configVersion.empty()) return false;
    for (const auto *s : {&o.package.package, &o.package.version, &o.package.architecture, &o.configVersion,
        &o.controlIdentity, &o.scriptsIdentity, &o.contentIdentity, &o.scriptContentIdentity}) if (!add(*s)) return false;
    for (const auto *list : {&o.triggersPending, &o.triggersAwaited}) {
        if (list->size() > MaximumDeconfigurationCauses) return false;
        for (const auto &s : *list) if (s.empty() || !add(s)) return false;
    }
    return true;
}
bool CheckpointShape(const RestorationCheckpoint &point, const DeconfigurationAllowanceSet &approval) {
    if (!Digest(point.identity) || point.packages.size() != approval.allowances.size()) return false;
    std::size_t bytes = 0;
    for (const auto &a : approval.allowances) {
        const auto found = point.packages.find(Slot(a.second.installed));
        if (found == point.packages.end() || !ObservationShape(found->second, &bytes) ||
            (found->second.present && Slot(found->second.package) != found->first)) return false;
    }
    return true;
}
bool Stable(const RestorationObservation &a, const RestorationObservation &b) {
    return SameContent(a, b) && a.configVersion == b.configVersion &&
        (a.diskStatus != b.diskStatus || (a.controlIdentity == b.controlIdentity && a.scriptsIdentity == b.scriptsIdentity));
}
bool NativeTriggerTransition(const RestorationObservation &a, const RestorationObservation &b) {
    return SameContent(a, b) && TriggerPhase(a.status) && TriggerPhase(b.status) && TriggerPhase(a.diskStatus) && TriggerPhase(b.diskStatus) &&
        (SameHistory(a, b) || ((a.diskStatus != b.diskStatus || a.configVersion != b.configVersion) &&
         (a.configVersion == b.configVersion || (a.diskStatus == Phase::TriggersAwaited && HistoryAfterConfigure(a, b)))));
}
bool Removed(const RestorationObservation &o, const ExecutionPackage &target, ExecutionAction kind) {
    if (!o.present) return true;
    return Same(o.package, target) && !o.reinstallRequired && EmptyTriggers(o) &&
        (o.selection == DpkgSelection::Unknown || o.selection == DpkgSelection::Deinstall || o.selection == DpkgSelection::Purge) &&
        ((o.status == Phase::NotInstalled && o.diskStatus == Phase::NotInstalled && o.configVersion.empty()) ||
         (kind == ExecutionAction::Remove && o.status == Phase::ConfigFiles && o.diskStatus == Phase::ConfigFiles && o.selection != DpkgSelection::Unknown));
}
}
bool RestorationDebtLedger::Reject(std::string *error, const char *code, bool uncertain) {
    active_ = false; uncertain_ = uncertain_ || uncertain; pending_.clear(); pendingArchives_.clear(); pendingBatch_ = 0;
    return Fail(error, code);
}
void RestorationDebtLedger::Invalidate(bool uncertain) { Reject(nullptr, "provider_restoration_invalidated", uncertain); }
bool RestorationDebtLedger::Begin(const DeconfigurationAllowanceSet &approval, const RestorationCheckpoint &point, std::string *error) {
    if (initialized_) return Reject(error, "provider_restoration_replayed");
    initialized_ = true;
    std::string encoded;
    if (!EncodeDeconfigurationApproval(approval, &encoded, error) || point.identity != approval.initialCheckpoint ||
        !CheckpointShape(point, approval)) return Reject(error, "provider_restoration_initial_invalid");
    std::set<std::string> slots;
    for (const auto &entry : approval.allowances) {
        const auto &a = entry.second; const auto &o = point.packages.at(Slot(a.installed));
        if (!slots.insert(Slot(a.installed)).second || !o.present || !Same(o.package, a.installed) || o.selection != a.selection ||
            o.status != a.initialStatus || o.diskStatus != a.diskStatus || o.configVersion != a.configVersion ||
            o.controlIdentity != a.installedControlIdentity || o.scriptsIdentity != a.installedScriptsIdentity)
            return Reject(error, "provider_restoration_initial_changed");
    }
    approval_ = approval; current_ = point; active_ = true;
    if (error) error->clear();
    return true;
}
bool RestorationDebtLedger::PreparePrimary(const std::string &expected, const AuthorizedExecution &batch, std::string *error) {
    const auto &actions = approval_.primaryReview.execution.actions;
    if (!active_ || pendingBatch_ || expected != current_.identity || batch.batch != nextBatch_ || batch.actions.empty() ||
        batch.actions.size() > actions.size() - completed_ || batch.action == ExecutionAction::Deconfigure || batch.action == ExecutionAction::Triggers)
        return Reject(error, "provider_restoration_primary_invalid");
    std::set<std::uint64_t> requested(batch.actions.begin(), batch.actions.end());
    if (requested.size() != batch.actions.size()) return Reject(error, "provider_restoration_primary_replayed");
    std::vector<std::uint64_t> ordered; std::map<std::string, std::string> retained;
    std::map<std::string, const ArchiveManifest *> archives;
    for (const auto &archive : approval_.primaryReview.execution.archives) archives.emplace(archive.identifier, &archive);
    for (std::size_t i = 0; i < batch.actions.size(); ++i) {
        const auto &action = actions[completed_ + i];
        if (action.action != batch.action || !requested.count(action.identifier)) return Reject(error, "provider_restoration_primary_order");
        ordered.push_back(action.identifier);
        if (action.action == ExecutionAction::Unpack) {
            if (batch.archives.size() != batch.actions.size()) return Reject(error, "provider_restoration_archive_order");
            std::string a, b;
            const auto found = archives.find(action.archive);
            if (found == archives.end() || !ValidIdentityToken(batch.archives[i].fileIdentity) || !Encode(*found->second, &a) ||
                !Encode(batch.archives[i].archive, &b) || a != b) return Reject(error, "provider_restoration_archive_order");
            retained.emplace(action.archive, batch.archives[i].fileIdentity);
        }
    }
    // Require a real boundary between a possible old-generation deconfigure
    // and its own successor unpack. End-of-child state cannot prove both.
    for (const auto &entry : approval_.allowances) if (requested.count(entry.second.endpoint.precedingUnpack))
        for (const auto &cause : entry.second.causes) if (requested.count(cause.unpackAction))
            return Reject(error, "provider_restoration_boundary_required");
    pending_ = std::move(ordered); pendingArchives_ = std::move(retained); pendingBatch_ = batch.batch;
    if (error) error->clear();
    return true;
}
bool RestorationDebtLedger::SettlePrimary(std::uint64_t batch, const RestorationChildResult &reply,
    const RestorationCheckpoint &next, const std::vector<RestorationSuccessorProof> &proofs, std::string *error) {
    const bool ran = reply.child.started || reply.uncertain;
    if (!active_ || !pendingBatch_ || batch != pendingBatch_ || !Successful(reply) || next.identity == current_.identity ||
        !CheckpointShape(next, approval_) || proofs.size() > approval_.allowances.size())
        return Reject(error, "provider_restoration_primary_unsettled", ran);
    std::map<std::string, const RestorationSuccessorProof *> successors;
    for (const auto &proof : proofs) {
        if (proof.oldGeneration.size() > 4096 || !approval_.allowances.count(proof.oldGeneration) ||
            !ValidIdentityToken(proof.archive) || !ValidIdentityToken(proof.retainedArchiveIdentity) ||
            !pendingArchives_.count(proof.archive) || pendingArchives_.at(proof.archive) != proof.retainedArchiveIdentity ||
            proof.beforeCheckpoint != current_.identity || proof.afterCheckpoint != next.identity ||
            !Digest(proof.installedControlIdentity) || !Digest(proof.installedScriptsIdentity) ||
            !Digest(proof.installedContentIdentity) || !Digest(proof.installedScriptContentIdentity) ||
            !successors.emplace(proof.oldGeneration, &proof).second)
            return Reject(error, "provider_restoration_successor_unverified", true);
    }
    const std::set<std::uint64_t> ids(pending_.begin(), pending_.end());
    auto result = debts_; std::set<std::string> usedProofs;
    std::map<std::string, const ReviewedAction *> targets;
    for (std::size_t i = 0; i < pending_.size(); ++i) {
        const auto &action = approval_.primaryReview.execution.actions[completed_ + i];
        if (!targets.emplace(Slot(action.package), &action).second) return Reject(error, "provider_restoration_target_ambiguous", true);
    }
    for (const auto &entry : approval_.allowances) {
        const auto &key = entry.first; const auto &a = entry.second; const auto &old = current_.packages.at(Slot(a.installed));
        const auto &now = next.packages.at(Slot(a.installed)); auto debt = result.find(key);
        const auto foundTarget = targets.find(Slot(a.installed));
        const ReviewedAction *target = foundTarget == targets.end() ? nullptr : foundTarget->second; std::uint64_t cause = 0;
        for (const auto &c : a.causes) if (ids.count(c.unpackAction)) { cause = c.unpackAction; break; }
        if (target && target->action == ExecutionAction::Unpack) {
            const auto proof = successors.find(key);
            if (target->identifier != a.endpoint.precedingUnpack || !old.present || !now.present ||
                !Same(target->package, a.endpoint.package) || !Same(now.package, target->package) ||
                !UnpackedPhase(now.status) || !UnpackedPhase(now.diskStatus) || !HistoryAfterConfigure(old, now) ||
                (now.selection != DpkgSelection::Install && !(old.selection == DpkgSelection::Hold && now.selection == DpkgSelection::Hold)) ||
                proof == successors.end() || proof->second->unpackAction != target->identifier || proof->second->archive != target->archive ||
                proof->second->installedControlIdentity != now.controlIdentity || proof->second->installedScriptsIdentity != now.scriptsIdentity ||
                proof->second->installedContentIdentity != now.contentIdentity || proof->second->installedScriptContentIdentity != now.scriptContentIdentity)
                return Reject(error, "provider_restoration_successor_unverified", true);
            usedProofs.insert(key);
            if (debt != result.end()) {
                if (debt->second.phase != RestorationDebtPhase::HalfConfigured || !Same(debt->second.current, a.installed) ||
                    old.status != Phase::HalfConfigured || old.diskStatus != Phase::HalfConfigured)
                    return Reject(error, "provider_restoration_successor_phase", true);
                debt->second.current = now.package; debt->second.successorAction = target->identifier;
                debt->second.phase = RestorationDebtPhase::SuccessorUnpacked;
            }
        } else if (target && (target->action == ExecutionAction::Configure || target->action == ExecutionAction::Remove || target->action == ExecutionAction::Purge)) {
            if (target->identifier != a.endpoint.action) {
                // The independent later Purge remains a primary obligation
                // after a Remove endpoint has already discharged the debt.
                if (debt != result.end() || a.endpoint.kind != ExecutionAction::Remove || target->action != ExecutionAction::Purge ||
                    !Same(target->package, a.endpoint.package) || !Removed(now, target->package, target->action))
                    return Reject(error, "provider_restoration_endpoint_changed", true);
                continue;
            }
            if (!old.present || !Same(old.package, target->package)) return Reject(error, "provider_restoration_endpoint_generation", true);
            if (target->action == ExecutionAction::Configure) {
                // An unused allowance is not a restoration requirement. The
                // ordinary parent verifier may prove a no-op or trigger-only
                // Configure; completing that reviewed action creates no debt
                // and supplies no evidence that postinst configure ran.
                if (debt == result.end() && TriggerPhase(old.status) && TriggerPhase(old.diskStatus) &&
                    (SameObservation(old, now) || NativeTriggerTransition(old, now))) continue;
                if ((old.status != Phase::HalfConfigured && old.status != Phase::Unpacked) ||
                    (old.diskStatus != Phase::HalfConfigured && old.diskStatus != Phase::Unpacked) || !SameContent(old, now) ||
                    !TriggerPhase(now.status) || !TriggerPhase(now.diskStatus) || !HistoryAfterConfigure(old, now))
                    return Reject(error, "provider_restoration_configure_incomplete", true);
                if (debt != result.end()) {
                    debt->second.configureAction = target->identifier; debt->second.phase = RestorationDebtPhase::ConfiguredAwaitingEffects;
                    if (Settled(now, next)) result.erase(debt);
                }
            } else {
                if (!Removed(now, target->package, target->action) ||
                    (now.present && now.status == Phase::ConfigFiles && now.configVersion != old.configVersion))
                    return Reject(error, "provider_restoration_remove_incomplete", true);
                if (debt != result.end()) result.erase(debt);
            }
        } else if (SameObservation(old, now)) {
            // An allowed cause need not actually deconfigure its recipient.
        } else if (debt == result.end() && cause && old.present && Same(old.package, a.installed) &&
            old.status > Phase::HalfConfigured && old.diskStatus > Phase::HalfConfigured && Stable(old, now) &&
            now.status == Phase::HalfConfigured && now.diskStatus == Phase::HalfConfigured) {
            RestorationDebt value; value.original = a.installed; value.current = a.installed; value.endpoint = a.endpoint; value.causeAction = cause;
            result.emplace(key, std::move(value));
        } else if (debt != result.end() && debt->second.phase == RestorationDebtPhase::ConfiguredAwaitingEffects &&
            debt->second.configureAction && NativeTriggerTransition(old, now)) {
            if (Settled(now, next)) result.erase(debt);
        } else if (debt != result.end() && Stable(old, now) && now.status == old.status && now.diskStatus == old.diskStatus) {
            // Trigger graph changes are independently verified by the owner;
            // they never repair HalfConfigured/Unpacked debt by themselves.
        } else if (debt == result.end() && NativeTriggerTransition(old, now)) {
        } else return Reject(error, "provider_restoration_unpredicted_transition", true);
    }
    if (usedProofs.size() != proofs.size()) return Reject(error, "provider_restoration_successor_unused", true);
    // An unrelated verified primary can incorporate the deferred queue while
    // an already configured debtor's package fields stay exactly unchanged.
    // Only a previously observed Configure and actual Installed state qualify.
    for (auto debt = result.begin(); debt != result.end();) {
        if (debt->second.phase == RestorationDebtPhase::ConfiguredAwaitingEffects && debt->second.configureAction &&
            Settled(next.packages.at(Slot(debt->second.current)), next)) debt = result.erase(debt);
        else ++debt;
    }
    debts_.swap(result); current_ = next; completed_ += pending_.size(); ++nextBatch_; pending_.clear(); pendingArchives_.clear(); pendingBatch_ = 0;
    if (error) error->clear();
    return true;
}
bool RestorationDebtLedger::ObserveEffects(const std::string &expected, const RestorationChildResult &reply,
    const RestorationCheckpoint &next, std::string *error) {
    if (!active_ || pendingBatch_ || effectObservations_ >= MaximumTriggerPassesPerTransaction ||
        expected != current_.identity || !Successful(reply) || next.identity == current_.identity ||
        !CheckpointShape(next, approval_)) return Reject(error, "provider_restoration_effect_unsettled", reply.child.started || reply.uncertain);
    auto result = debts_;
    for (const auto &entry : approval_.allowances) {
        const auto &old = current_.packages.at(Slot(entry.second.installed)); const auto &now = next.packages.at(Slot(entry.second.installed));
        auto debt = result.find(entry.first);
        if (SameObservation(old, now)) continue;
        if (debt == result.end()) {
            if (!NativeTriggerTransition(old, now)) return Reject(error, "provider_restoration_effect_changed", true);
        } else if (debt->second.phase == RestorationDebtPhase::ConfiguredAwaitingEffects) {
            if (!debt->second.configureAction || !NativeTriggerTransition(old, now)) return Reject(error, "provider_restoration_effect_changed", true);
            if (Settled(now, next)) result.erase(debt);
        } else if (!Stable(old, now) || old.status != now.status || old.diskStatus != now.diskStatus)
            return Reject(error, "provider_restoration_effect_cannot_restore", true);
    }
    // An empty deferred queue can settle an already Installed debtor even
    // when its package fields did not change during queue incorporation.
    for (auto debt = result.begin(); debt != result.end();) {
        if (debt->second.phase == RestorationDebtPhase::ConfiguredAwaitingEffects && debt->second.configureAction &&
            Settled(next.packages.at(Slot(debt->second.current)), next)) debt = result.erase(debt);
        else ++debt;
    }
    debts_.swap(result); current_ = next; ++effectObservations_;
    if (error) error->clear();
    return true;
}
bool RestorationDebtLedger::complete() const {
    return active_ && !pendingBatch_ && debts_.empty() && completed_ == approval_.primaryReview.execution.actions.size();
}
}}
