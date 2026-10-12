/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionLease.hpp"
#include "Cydia/ExtendedState.hpp"
#include <algorithm>
#include <limits>

namespace CydiaAPT { namespace Provider {
namespace {
bool Error(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Digest(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
bool Path(const std::string &value) {
    if (value.size() < 2 || value.size() > 4096 || value.front() != '/' || value.back() == '/' ||
        value.find("//") != std::string::npos || value.find("/./") != std::string::npos ||
        value.find("/../") != std::string::npos || value.compare(value.size() - 2, 2, "/.") == 0 ||
        (value.size() >= 3 && value.compare(value.size() - 3, 3, "/..") == 0)) return false;
    for (unsigned char c : value) if (c < 32 || c == 127) return false;
    return true;
}
bool SameArchive(const ArchiveManifest &a, const ArchiveManifest &b) {
    std::string left, right; return Encode(a, &left) && Encode(b, &right) && left == right;
}
bool Deltas(const std::vector<AutoInstalledDelta> &values, std::map<std::string, bool> *result) {
    if (values.size() > MaximumCollectionItems) return false;
    for (const auto &value : values)
        if (!CydiaRuntime::ValidPackageName(value.package) || !CydiaRuntime::ValidArchitectureName(value.architecture) ||
            value.architecture == "all" || value.architecture == "any" || value.architecture == "native" ||
            !result->emplace(value.package + ':' + value.architecture, value.automatic).second) return false;
    return true;
}
}
bool TransactionLease::Fail(std::string *error, const char *code) {
    // A bad concurrent request cannot erase the fact that a child or CAS may
    // already be in flight. Their owner must observe settlement first.
    cancelled_ = true;
    if (phase_ != TransactionLeasePhase::Executing && phase_ != TransactionLeasePhase::ExecutingEffects && phase_ != TransactionLeasePhase::Committing &&
        phase_ != TransactionLeasePhase::Committed && phase_ != TransactionLeasePhase::Closed)
        phase_ = TransactionLeasePhase::Failed;
    return Error(error, code);
}
bool TransactionLease::Context(const TransactionLeaseContext &context, std::string *error) const {
    if (!CydiaRuntime::Privileged::ValidApplicationProcessIdentity(context.application) ||
        !(context.application == identity_.application) || context.lock.device != identity_.lock.device ||
        context.lock.inode != identity_.lock.inode || context.lock.inode == 0 ||
        std::to_string(context.lockOwner) != identity_.application.pid ||
        context.operatingIdentity != identity_.operatingIdentity ||
        context.nativeConfigurationIdentity != identity_.nativeConfigurationIdentity)
        return Error(error, "provider_lease_authority_changed");
    return true;
}
bool TransactionLease::Copies(const TransactionLeaseContext &context, std::string *error) const {
    if (context.stagedArchives.size() != archives_.size()) return Error(error, "provider_lease_staging_changed");
    std::map<std::string, const StagedArchiveEvidence *> observed;
    for (const auto &copy : context.stagedArchives)
        if (!observed.emplace(copy.identity.file.metadata.path, &copy).second) return Error(error, "provider_lease_staging_changed");
    for (const auto &archive : archives_) {
        const auto &expected = archive.second.copy;
        const auto found = observed.find(expected.identity.file.metadata.path);
        if (found == observed.end() || !SameInstalledComponent(expected.identity, found->second->identity) ||
            expected.hashes != found->second->hashes)
            return Error(error, "provider_lease_staging_changed");
    }
    return true;
}
bool TransactionLease::Request(const TransactionLeaseEnvelope &envelope, const TransactionLeaseContext &context, std::string *error) {
    if (!Expects(envelope)) return Fail(error, "provider_lease_request_invalid");
    ++nextSequence_;
    if (!Context(context, error) || !Copies(context, error) || context.stateIdentity != authorization_.stateIdentity() ||
        !components_.Observe(completedUnpacks_, context.components, error))
        return Fail(error, "provider_lease_state_changed");
    return true;
}
bool TransactionLease::Expects(const TransactionLeaseEnvelope &envelope) const {
    return phase_ == TransactionLeasePhase::Ready && !cancelled_ && !uncertain_ && envelope.nonce == identity_.nonce &&
        envelope.reviewDigest == identity_.reviewDigest && envelope.sequence == nextSequence_ &&
        nextSequence_ != std::numeric_limits<std::uint64_t>::max();
}
bool TransactionLease::Begin(const TransactionLeaseIdentity &identity, const ReviewedTransaction &review,
    const ReviewPolicy &policy, const TransactionLeaseContext &context,
    const std::vector<RetainedTransactionArchive> &staged, const std::vector<RetainedComponentArchive> &replacements,
    const std::vector<AutoInstalledDelta> &deltas, std::string *error) {
    if (initialized_) return Fail(error, "provider_lease_reused");
    initialized_ = true; identity_ = identity; review_ = review;
    if (!CydiaRuntime::Privileged::ValidApplicationProcessIdentity(identity.application) || !identity.lock.inode ||
        !ValidChallenge(identity.nonce) || !Digest(identity.reviewDigest) || !Digest(identity.originIdentity) ||
        !Digest(identity.operatingIdentity) || !Digest(identity.nativeConfigurationIdentity) || !Digest(identity.platformIdentity) ||
        !Digest(identity.extendedStateIdentity) || (!identity.effectIdentity.empty() && !Digest(identity.effectIdentity)) ||
        !Path(identity.stagingDirectory) || !Context(context, error) ||
        context.stateIdentity != review.binding.packageStateIdentity ||
        !authorization_.Accept(review, policy, error) || !Deltas(deltas, &deltas_))
        return Fail(error, "provider_lease_admission_invalid");
    std::map<std::string, bool> allowed;
    for (const auto &item : review.transaction.packages) {
        const auto &package = item.second.identity;
        const bool removal = std::find(review.transaction.removes.begin(), review.transaction.removes.end(), item.first) != review.transaction.removes.end() ||
            std::find(review.transaction.purges.begin(), review.transaction.purges.end(), item.first) != review.transaction.purges.end();
        allowed[package.baseName + ':' + package.packageArchitecture] = !removal;
    }
    for (const auto &action : review.execution.actions)
        if (action.action == ExecutionAction::Configure && policy.additionalActionsReviewed.count(action.identifier))
            allowed[action.package.package + ':' + (action.package.architecture == "all" ? policy.environment.nativeArchitecture : action.package.architecture)] = true;
    for (const auto &delta : deltas_) {
        const auto found = allowed.find(delta.first);
        if (found == allowed.end() || (delta.second && !found->second)) return Fail(error, "provider_lease_auto_state_unreviewed");
    }
    if (staged.size() != review.execution.archives.size()) return Fail(error, "provider_lease_archives_incomplete");
    std::vector<VerifiedArchiveEvidence> sources;
    for (const auto &archive : staged) sources.push_back(archive.source);
    if (!VerifyReviewedArchiveEvidence(review.execution.archives, sources, policy.unverifiedArchiveWarningsAccepted, error))
        return Fail(error, "provider_lease_archive_unverified");
    std::set<std::string> copyPaths, copyIdentities;
    for (const auto &archive : staged) {
        const auto &source = archive.source.archive;
        const auto &copy = archive.copy.identity;
        const auto &file = copy.file;
        const std::string prefix = identity.stagingDirectory + '/';
        // The source may legitimately offer SHA512 without SHA256. Keep all
        // approved algorithms and add the local content identity; neither is
        // a substitute for independently hashing the retained staged bytes.
        auto requiredHashes = source.hashes;
        requiredHashes.emplace("SHA256", file.sha256);
        const auto sha256 = archive.copy.hashes.find("SHA256");
        if (!Path(file.metadata.path) ||
            file.metadata.path.compare(0, prefix.size(), prefix) != 0 || file.metadata.path.find('/', prefix.size()) != std::string::npos ||
            file.metadata.size != source.size || file.metadata.mode != 0600 || file.metadata.uid != 0 ||
            copy.kind != ComponentFileKind::Regular || copy.links != 1 || !copy.inode || !Digest(copy.parentsIdentity) ||
            !Digest(file.sha256) || archive.copy.hashes != requiredHashes ||
            sha256 == archive.copy.hashes.end() || sha256->second != file.sha256 ||
            !copyPaths.insert(file.metadata.path).second ||
            !copyIdentities.insert(std::to_string(copy.device) + ':' + std::to_string(copy.inode)).second ||
            !archives_.emplace(source.identifier, archive).second)
            return Fail(error, "provider_lease_archive_unverified");
    }
    for (const auto &replacement : replacements) {
        const auto stagedArchive = archives_.find(replacement.archive.archive.identifier);
        if (stagedArchive == archives_.end() || !SameArchive(stagedArchive->second.source.archive, replacement.archive.archive) ||
            stagedArchive->second.source.fileIdentity != replacement.archive.fileIdentity)
            return Fail(error, "provider_lease_successor_archive_changed");
    }
    if (!Copies(context, error)) return Fail(error, "provider_lease_staging_changed");
    if (!components_.Begin(review, policy, context.components, replacements,
        identity.nativeConfigurationIdentity, identity.platformIdentity, error)) return Fail(error, "provider_lease_components_unverified");
    executor_ = policy.environment.paths.dpkg;
    phase_ = TransactionLeasePhase::Ready;
    if (error) error->clear();
    return true;
}
bool TransactionLease::Capture(const TransactionLeaseEnvelope &envelope, const TransactionLeaseContext &context, std::string *error) {
    return Request(envelope, context, error);
}
bool TransactionLease::Authorize(const TransactionLeaseEnvelope &envelope, const TransactionLeaseContext &context,
    const ParentExecutionRequest &request, const ParentExecutionEvidence &evidence, const ComponentClosureEvidence &closure,
    AuthorizedExecution *result, std::string *error) {
    if (!result || !Request(envelope, context, error)) return Fail(error, "provider_lease_execution_invalid");
    if (closure.executable != executor_) return Fail(error, "provider_lease_executor_changed");
    if (!components_.AuthorizeLaunch(closure, error)) return Fail(error, "provider_lease_executor_unverified");
    ParentExecutionEvidence retained(evidence); retained.archives.clear();
    if (evidence.stateIdentity != context.stateIdentity) return Fail(error, "provider_lease_state_changed");
    std::set<std::string> needed;
    for (const auto identifier : request.actions)
        for (const auto &action : review_.execution.actions)
            if (action.identifier == identifier && action.action == ExecutionAction::Unpack) needed.insert(action.archive);
    for (const auto &archive : needed) retained.archives.push_back(archives_.at(archive).source);
    if (!authorization_.Authorize(request, retained, &pending_, error)) return Fail(error, "provider_lease_batch_not_authorized");
    *result = pending_;
    // Keep original manifest identity; only substitute the private copy in the
    // actual argv returned to the privileged executor.
    for (const auto &archive : pending_.archives) {
        const auto &copy = archives_.at(archive.archive.identifier).copy.identity.file.metadata.path;
        for (auto &argument : result->arguments) if (argument == archive.archive.path) argument = copy;
    }
    childStarted_ = false; phase_ = TransactionLeasePhase::Executing;
    if (error) error->clear();
    return true;
}
bool TransactionLease::Started(std::uint64_t batch, std::string *error) {
    if (phase_ != TransactionLeasePhase::Executing || childStarted_ || !batch || batch != pending_.batch)
        return Fail(error, "provider_lease_child_invalid");
    childStarted_ = everStarted_ = true;
    return true;
}
bool TransactionLease::Settle(std::uint64_t batch, const ParentExecutionReply &reply, const TransactionLeaseContext &context,
    bool transitionVerified, std::string *error) {
    if (phase_ != TransactionLeasePhase::Executing || !batch || batch != pending_.batch)
        return Fail(error, "provider_lease_settlement_invalid");
    auto completed(completedUnpacks_);
    for (const auto id : pending_.actions)
        for (const auto &action : review_.execution.actions)
            if (action.identifier == id && action.action == ExecutionAction::Unpack) completed.insert(id);
    // Even a missing start notification must never erase an observed child.
    everStarted_ = everStarted_ || reply.started;
    const bool success = childStarted_ && reply.started && !reply.exitCode && !reply.signal && !reply.launchError;
    const bool captured = success && Context(context, error) && Copies(context, error) &&
        components_.Observe(completed, context.components, error);
    const bool settled = authorization_.Settle(batch, reply, context.stateIdentity, captured && transitionVerified, error);
    pending_ = AuthorizedExecution(); childStarted_ = false;
    phase_ = settled && !cancelled_ && !uncertain_ ? TransactionLeasePhase::Ready : TransactionLeasePhase::Failed;
    if (settled) completedUnpacks_.swap(completed);
    if (phase_ != TransactionLeasePhase::Ready) return Error(error, "provider_lease_requires_new_review");
    if (error) error->clear();
    return true;
}
bool TransactionLease::BeginCommit(const TransactionLeaseEnvelope &envelope, const TransactionLeaseContext &context,
    const std::vector<AutoInstalledDelta> &changes, const std::string &baseline, std::string *error) {
    if (!Request(envelope, context, error)) return false;
    std::map<std::string, bool> proposed;
    if (!authorization_.complete() || !Deltas(changes, &proposed) || proposed != deltas_ ||
        baseline != identity_.extendedStateIdentity) return Fail(error, "provider_lease_commit_not_authorized");
    phase_ = TransactionLeasePhase::Committing;
    return true;
}
bool TransactionLease::AuthorizeEffects(const TransactionLeaseContext &context, const std::string &effect,
    std::uint64_t pass, const ComponentClosureEvidence &closure, std::string *error) {
    if (phase_ != TransactionLeasePhase::Ready || cancelled_ || uncertain_ || identity_.effectIdentity.empty() ||
        effect != identity_.effectIdentity || !pass || pass != nextEffectPass_ ||
        nextEffectPass_ == std::numeric_limits<std::uint64_t>::max() || !Context(context, error) ||
        !Copies(context, error) || context.stateIdentity != authorization_.stateIdentity() ||
        closure.executable != executor_ || !components_.Observe(completedUnpacks_, context.components, error) ||
        !components_.AuthorizeLaunch(closure, error))
        return Fail(error, "provider_lease_effect_not_authorized");
    ++nextEffectPass_; pendingEffectPass_ = pass; childStarted_ = false; phase_ = TransactionLeasePhase::ExecutingEffects;
    if (error) error->clear(); return true;
}
bool TransactionLease::StartedEffects(std::uint64_t pass, std::string *error) {
    if (phase_ != TransactionLeasePhase::ExecutingEffects || childStarted_ || !pass || pass != pendingEffectPass_)
        return Fail(error, "provider_lease_child_invalid");
    childStarted_ = everStarted_ = true; return true;
}
bool TransactionLease::SettleEffects(std::uint64_t pass, const ParentExecutionReply &reply,
    const TransactionLeaseContext &context, bool verified, std::string *error) {
    if (phase_ != TransactionLeasePhase::ExecutingEffects || !pass || pass != pendingEffectPass_)
        return Fail(error, "provider_lease_settlement_invalid");
    everStarted_ = everStarted_ || reply.started;
    const bool success = childStarted_ && reply.started && !reply.exitCode && !reply.signal && !reply.launchError;
    const bool captured = success && Context(context, error) && Copies(context, error) &&
        components_.Observe(completedUnpacks_, context.components, error);
    const bool settled = authorization_.AdvanceEffects(authorization_.stateIdentity(), context.stateIdentity, captured && verified, error);
    pendingEffectPass_ = 0; childStarted_ = false;
    phase_ = settled && !cancelled_ && !uncertain_ ? TransactionLeasePhase::Ready : TransactionLeasePhase::Failed;
    if (phase_ != TransactionLeasePhase::Ready) return Error(error, "provider_lease_requires_new_review");
    if (error) error->clear(); return true;
}
bool TransactionLease::SettleCommit(bool committed, std::string *error) {
    if (phase_ != TransactionLeasePhase::Committing) return Fail(error, "provider_lease_commit_invalid");
    committed_ = committed;
    phase_ = committed ? TransactionLeasePhase::Committed : TransactionLeasePhase::Failed;
    if (!committed) return Error(error, "provider_lease_commit_failed");
    if (error) error->clear();
    return true;
}
void TransactionLease::Cancel() {
    cancelled_ = true;
    if (phase_ == TransactionLeasePhase::Ready) phase_ = TransactionLeasePhase::Failed;
}
void TransactionLease::TransportLost() {
    if (phase_ == TransactionLeasePhase::Executing || phase_ == TransactionLeasePhase::ExecutingEffects || phase_ == TransactionLeasePhase::Committing) uncertain_ = true;
    Cancel();
}
bool TransactionLease::Close(std::string *error) {
    if (phase_ == TransactionLeasePhase::Executing || phase_ == TransactionLeasePhase::ExecutingEffects || phase_ == TransactionLeasePhase::Committing)
        return Error(error, "provider_lease_child_not_settled");
    initialized_ = true; phase_ = TransactionLeasePhase::Closed; authorization_.Invalidate(); components_.Invalidate();
    return true;
}
}} // namespace CydiaAPT::Provider
