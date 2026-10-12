/* Pure state machine for a retained transaction in authenticated cydo.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderTransactionLease_HPP
#define Cydia_AptProviderTransactionLease_HPP
#include "Cydia/AptProviderComponentSuccession.hpp"
#include "Cydia/ApplicationSession.hpp"

namespace CydiaAPT { namespace Provider {
struct TransactionLockIdentity {
    std::uint64_t device = 0, inode = 0;
};
struct TransactionLeaseIdentity {
    CydiaRuntime::Privileged::ApplicationProcessIdentity application;
    TransactionLockIdentity lock;
    std::string nonce, reviewDigest, originIdentity, operatingIdentity;
    // Native dpkg's complete declared config graph is distinct from APT
    // options. An unverified/missing graph cannot be filled with a placeholder.
    std::string nativeConfigurationIdentity, platformIdentity, extendedStateIdentity;
    std::string stagingDirectory;
    // Empty preserves the legacy primary-only route. Otherwise fixed at Begin
    // to the digest independently recomputed from native-approved recipients.
    std::string effectIdentity;
};
struct StagedArchiveEvidence {
    InstalledComponentEvidence identity;
    // Recomputed from this retained copy, never copied from the source record:
    // every manifest hash plus SHA256 used by identity.file.sha256. The helper
    // hashes one stable descriptor for both values before publishing evidence.
    std::map<std::string, std::string> hashes;
};
struct TransactionLeaseContext {
    CydiaRuntime::Privileged::ApplicationProcessIdentity application;
    TransactionLockIdentity lock;
    std::uint64_t lockOwner = 0;
    std::string operatingIdentity, nativeConfigurationIdentity, stateIdentity;
    std::vector<InstalledComponentEvidence> components;
    // Rehashed retained copies, including after each child; a root maintainer
    // script must not silently replace a later archive in the private stage.
    std::vector<StagedArchiveEvidence> stagedArchives;
};
struct TransactionLeaseEnvelope {
    std::string nonce, reviewDigest;
    std::uint64_t sequence = 0;
};
struct RetainedTransactionArchive {
    // Source records, all requested hashes and archive inspection are verified
    // on the retained copy before mutation. source keeps the approved original
    // manifest path; its fileIdentity identifies this copy's retained fd and
    // protected path chain. copy independently records its actual private path.
    VerifiedArchiveEvidence source;
    StagedArchiveEvidence copy;
};
enum class TransactionLeasePhase { Empty, Ready, Executing, Committing, Committed, Failed, Closed, ExecutingEffects };

/* Inputs are helper-owned capture results, never provider request authority.
 * The production owner authenticates the app, computes all identities (the
 * review digest includes this exact review and UI approval), holds/stages
 * files, captures state and verifies loader/config graphs. This pure class
 * does not claim those producers or persistent cydo transport are installed.
 * Every failure terminates admission; active children still require Settle.
 * One instance is single-use, even following a pre-mutation failure. */
class TransactionLease {
    TransactionLeaseIdentity identity_;
    ReviewedTransaction review_;
    ReviewAuthorization authorization_;
    ComponentSuccession components_;
    std::map<std::string, RetainedTransactionArchive> archives_;
    std::map<std::string, bool> deltas_;
    std::string executor_;
    std::set<std::uint64_t> completedUnpacks_;
    AuthorizedExecution pending_;
    TransactionLeasePhase phase_ = TransactionLeasePhase::Empty;
    std::uint64_t nextSequence_ = 1;
    std::uint64_t nextEffectPass_ = 1, pendingEffectPass_ = 0;
    bool initialized_ = false, cancelled_ = false, uncertain_ = false;
    bool childStarted_ = false, everStarted_ = false, committed_ = false;
    bool Fail(std::string *, const char *);
    bool Context(const TransactionLeaseContext &, std::string *) const;
    bool Copies(const TransactionLeaseContext &, std::string *) const;
    bool Request(const TransactionLeaseEnvelope &, const TransactionLeaseContext &, std::string *);
public:
    bool Begin(const TransactionLeaseIdentity &, const ReviewedTransaction &, const ReviewPolicy &,
        const TransactionLeaseContext &, const std::vector<RetainedTransactionArchive> &,
        const std::vector<RetainedComponentArchive> &, const std::vector<AutoInstalledDelta> &,
        std::string *error);
    bool Capture(const TransactionLeaseEnvelope &, const TransactionLeaseContext &, std::string *error);
    bool Authorize(const TransactionLeaseEnvelope &, const TransactionLeaseContext &,
        const ParentExecutionRequest &, const ParentExecutionEvidence &, const ComponentClosureEvidence &,
        AuthorizedExecution *, std::string *error);
    // Notification after the actual child starts, not permission to spawn it.
    bool Started(std::uint64_t batch, std::string *error);
    bool Settle(std::uint64_t batch, const ParentExecutionReply &, const TransactionLeaseContext &,
        bool transitionVerified, std::string *error);
    // Internal owner-selected passes: no worker request sequence, argv or
    // primary action ID is consumed. Target authorization is supplied only by
    // the owner's retained TriggerEffectLedger, not a worker boolean.
    bool AuthorizeEffects(const TransactionLeaseContext &, const std::string &effectIdentity,
        std::uint64_t pass, const ComponentClosureEvidence &, std::string *error);
    bool StartedEffects(std::uint64_t pass, std::string *error);
    bool SettleEffects(std::uint64_t pass, const ParentExecutionReply &, const TransactionLeaseContext &,
        bool transitionVerified, std::string *error);
    bool BeginCommit(const TransactionLeaseEnvelope &, const TransactionLeaseContext &,
        const std::vector<AutoInstalledDelta> &, const std::string &extendedStateIdentity, std::string *error);
    bool SettleCommit(bool committed, std::string *error);
    void Cancel();
    void TransportLost();
    bool Close(std::string *error);
    TransactionLeasePhase phase() const { return phase_; }
    bool mutationStarted() const { return everStarted_; }
    bool complete() const { return committed_; }
    bool indeterminate() const { return uncertain_; }
    const std::string &stateIdentity() const { return authorization_.stateIdentity(); }
    bool Expects(const TransactionLeaseEnvelope &) const;
};
}} // namespace CydiaAPT::Provider
#endif
