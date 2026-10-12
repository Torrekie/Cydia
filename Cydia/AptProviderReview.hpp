/* Parent-owned execution review policy. No executor or provider activation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderReview_HPP
#define Cydia_AptProviderReview_HPP
#include "Cydia/AptProviderProtocol.hpp"

namespace CydiaAPT { namespace Provider {

struct ReviewPolicy {
    Environment environment;
    CydiaPackages::ArchiveLayout layout;
    // Exact protected DPkg::Options, independently recovered and validated by
    // Privileged::ValidateDpkgArguments. They form the argv prefix; the worker
    // cannot add, omit or reorder them. Execution actions never belong here.
    std::vector<std::string> protectedDpkgOptions;
    // Parent UI approval of actions not represented by TransactionData's six
    // lists (for example an already-pending configure, trigger recipient or
    // exact installed version deconfigured while another archive unpacks).
    std::set<std::uint64_t> additionalActionsReviewed;
    std::set<std::string> unverifiedArchiveWarningsAccepted;
};

struct VerifiedArchiveEvidence {
    // Parent independently resolves the selected index/source and reads the
    // protected regular archive. Never copy this from a worker reply. All
    // hashes and size are recomputed; inspection verifies exact control fields
    // and the active layout. fileIdentity identifies the retained descriptor
    // and protected path chain for the final executor recheck.
    ArchiveManifest archive;
    CydiaPackages::ArchivePolicyResult inspection;
    std::string fileIdentity;
};

// Compare a complete requested archive set with independently observed parent
// evidence. This does not authorize a mutation or retain protected copies.
bool VerifyReviewedArchiveEvidence(const std::vector<ArchiveManifest> &expected,
    const std::vector<VerifiedArchiveEvidence> &observed,
    const std::set<std::string> &approvedWarnings, std::string *error);

struct ParentExecutionEvidence {
    Binding binding;
    bool frontendLockHeld = false;
    bool stateVerified = false;
    std::string stateIdentity;
    // Parent-created status channel; the worker's numerical fd is replaced.
    int statusDescriptor = -1;
    std::vector<VerifiedArchiveEvidence> archives;
    // Resolution of legacy unqualified dpkg operands from fresh local state,
    // not just from the packages visible in this review (which may omit a
    // coinstalled foreign instance). Explicit name:architecture needs no alias.
    std::map<std::string, ExecutionPackage> barePackageTargets;
    // Fresh structured dpkg enumeration under the parent lock. A global
    // --pending is allowed only if this exact complete set is reviewed.
    bool pendingTargetsKnown = false;
    std::vector<ExecutionPackage> pendingTargets;
    // Unpack's --auto-deconfigure and implicit trigger processing can affect
    // other packages. The parent must independently bound those effects too.
    bool deconfigurationTargetsKnown = false;
    std::vector<ExecutionPackage> deconfigurationTargets;
    bool triggerTargetsKnown = false;
    std::vector<ExecutionPackage> triggerTargets;
};

struct AuthorizedExecution {
    std::uint64_t batch = 0;
    ExecutionAction action = ExecutionAction::Unpack;
    std::vector<std::uint64_t> actions;
    std::vector<std::string> arguments; // Parent status descriptor substituted.
    std::vector<VerifiedArchiveEvidence> archives;
};

/* Pure, dormant authorization model. Accept only after the parent UI has
 * approved this complete manifest and independently bound it to the selected
 * source/policy/state snapshot. No worker boolean constitutes that approval.
 * Authorize requires fresh parent evidence, consumes one batch slot and
 * prevents concurrent/replayed execution. The actual parent broker must also
 * call ValidateDpkgArguments and recheck/retain file and environment evidence
 * through its direct cydo launch; this class neither opens nor executes files.
 * Settle accepts only parent-observed execution results and a fresh structured
 * state comparison allowing exactly the authorized batch effects. Failure,
 * transport loss or unknown effects invalidate the review, never auto-retry.
 */
class ReviewAuthorization {
    ReviewedTransaction review_;
    ReviewPolicy policy_;
    std::map<std::uint64_t, ReviewedAction> actions_;
    std::map<std::string, ArchiveManifest> archives_;
    std::set<std::uint64_t> completed_;
    AuthorizedExecution pending_;
    std::string stateIdentity_;
    std::uint64_t nextBatch_ = 1;
    bool active_ = false;
public:
    bool Accept(const ReviewedTransaction &review, const ReviewPolicy &policy, std::string *error);
    bool Authorize(const ParentExecutionRequest &request, const ParentExecutionEvidence &evidence,
                   AuthorizedExecution *authorized, std::string *error);
    bool Settle(std::uint64_t batch, const ParentExecutionReply &result,
                const std::string &nextStateIdentity, bool stateTransitionVerified, std::string *error);
    void Invalidate();
    bool active() const { return active_; }
    bool complete() const { return active_ && pending_.batch == 0 && completed_.size() == actions_.size(); }
    const std::string &stateIdentity() const { return stateIdentity_; }
};

}} // namespace CydiaAPT::Provider
#endif
