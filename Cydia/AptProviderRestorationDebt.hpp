/* Parent-owned restoration bookkeeping; no capture, execution or permission.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderRestorationDebt_HPP
#define Cydia_AptProviderRestorationDebt_HPP
#include "Cydia/AptProviderDeconfigurationApproval.hpp"

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumRestorationObservationBytes = 8 * 1024 * 1024;
// Exactly the approved allowance slots, including an explicit absent value
// after removal. This is a parent projection of a complete protected checkpoint,
// not a provider DTO. Ordinary/unrelated state must still pass the owner's full
// transition verifier. Present NotInstalled rows retain an exact generation;
// forgotten versionless rows must be projected as absence by that verifier.
struct RestorationObservation {
    bool present = false, reinstallRequired = false;
    ExecutionPackage package;
    DpkgSelection selection = DpkgSelection::Unknown;
    DpkgPackageStatus status = DpkgPackageStatus::NotInstalled;
    DpkgPackageStatus diskStatus = DpkgPackageStatus::NotInstalled;
    std::string configVersion, controlIdentity, scriptsIdentity;
    // Parent hashes of exact canonical controls/declarations and selected
    // prerm/postinst evidence, respectively, excluding ONLY disk phase and
    // Config-Version. These permit legitimate status/history transitions;
    // phase-bound existing metadata/script identities above remain required.
    // Generation, native filenames/format, absence, bytes and protected file
    // metadata must remain bound. No hash or native capture is done here.
    std::string contentIdentity, scriptContentIdentity;
    std::vector<std::string> triggersPending, triggersAwaited;
};
struct RestorationCheckpoint {
    std::string identity;
    bool deferredQueueEmpty = false;
    std::map<std::string, RestorationObservation> packages; // name:actual arch
};
struct RestorationSuccessorProof {
    std::uint64_t unpackAction = 0;
    std::string oldGeneration, archive, retainedArchiveIdentity;
    std::string beforeCheckpoint, afterCheckpoint;
    // Produced only after independently comparing the retained archive's
    // canonical controls and prerm/postinst bytes/metadata to fresh installed
    // evidence. Archive hashes/layout/provenance and script generation rules
    // are separate mandatory parent proofs. Public values are not authority.
    std::string installedControlIdentity, installedScriptsIdentity;
    std::string installedContentIdentity, installedScriptContentIdentity;
    // Actual canonical installed control value, matched to the retained archive
    // by the producer. Required by conditional full-state successor verification;
    // empty is unknown, and grants no assumption of native Multi-Arch:no.
    std::string installedMultiArch;
};
struct RestorationChildResult {
    ParentExecutionReply child;
    bool cancelled = false, uncertain = false;
};
enum class RestorationDebtPhase { HalfConfigured, SuccessorUnpacked, ConfiguredAwaitingEffects };
struct RestorationDebt {
    ExecutionPackage original, current;
    DeconfigurationEndpoint endpoint;
    RestorationDebtPhase phase = RestorationDebtPhase::HalfConfigured;
    std::uint64_t causeAction = 0, successorAction = 0, configureAction = 0;
};
// Single-use, bounded pure ledger (at most 256 effect observations). Begin
// requires the independently rebuilt native-approved allowance set, never
// merely a decoded approval. Prepare runs
// after full batch authorization/effect/ownership/Pre-Depends/native-policy
// proof and before the actual child. Settle runs only after full post-child
// capture/transition verification. No booleans or digest shapes here prove it.
//
// Batches are contiguous homogeneous slices of the exact review. Synthetic
// Deconfigure IDs are refused. Creation plus successor Unpack in one child is
// unsupported: the old HalfConfigured state needs a real observed boundary.
// Failed/cancelled/uncertain settlement retires this ledger without completing
// IDs or publishing a partial debt update; no retry of a started child. An
// unused allowance permits independently verified unchanged/trigger-only
// Configure transitions without recording any restoration or creating debt.
class RestorationDebtLedger {
    DeconfigurationAllowanceSet approval_;
    RestorationCheckpoint current_;
    std::map<std::string, RestorationDebt> debts_;
    std::vector<std::uint64_t> pending_;
    std::map<std::string, std::string> pendingArchives_;
    std::uint64_t pendingBatch_ = 0, nextBatch_ = 1;
    std::size_t completed_ = 0;
    unsigned effectObservations_ = 0;
    bool initialized_ = false, active_ = false, uncertain_ = false;
    bool Reject(std::string *, const char *, bool uncertain = false);
public:
    bool Begin(const DeconfigurationAllowanceSet &, const RestorationCheckpoint &, std::string *error);
    // Read-only equality against this ledger's PRIVATE canonical approval and
    // exact current complete observation. Caller supplies observation() from
    // an actual opaque protected checkpoint; digest/shape equality alone is
    // insufficient. This performs no capture or mutation and grants no native
    // effect permission. Prepared-but-unstarted primary retains this point.
    bool AuthorizeCheckpoint(const DeconfigurationAllowanceSet &,
        const RestorationCheckpoint &actualProtectedObservation, std::string *error) const;
    bool PreparePrimary(const std::string &expectedCheckpoint, const AuthorizedExecution &, std::string *error);
    bool SettlePrimary(std::uint64_t batch, const RestorationChildResult &, const RestorationCheckpoint &,
        const std::vector<RestorationSuccessorProof> &, std::string *error);
    // Called after a successful, independently verified trigger-only child.
    // Debtors stay HalfConfigured/Unpacked until their reviewed Configure;
    // no fictitious Installed normalization is permitted. A previously proven
    // Configure may finish once its actual trigger obligations settle. A
    // Configure starting from TriggersPending/Awaited cannot prove that
    // postinst configure ran and is conservatively refused at settlement.
    bool ObserveEffects(const std::string &expectedCheckpoint, const RestorationChildResult &,
        const RestorationCheckpoint &, std::string *error);
    void Invalidate(bool executionUncertain = false);
    bool active() const { return active_; }
    bool indeterminate() const { return uncertain_; }
    std::size_t completedActions() const { return completed_; }
    const std::map<std::string, RestorationDebt> &debts() const { return debts_; }
    const std::string &stateIdentity() const { return current_.identity; }
    // Debt/primary bookkeeping only: owner must additionally require trigger
    // quiescence, complete review/lease settlement and final state CAS.
    bool complete() const;
};
}}
#endif
