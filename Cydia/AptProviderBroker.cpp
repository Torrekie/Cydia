/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderBroker.hpp"
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/AptProviderTransactionRequest.hpp"
#include "Cydia/PrivilegedClient.h"
#include "Cydia/ExtendedState.hpp"
#include "Cydia/RedactedURL.hpp"
#include <chrono>
#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace Client = CydiaRuntime::PrivilegedClient;
bool Deltas(const std::vector<AutoInstalledDelta> &values, std::map<std::string, bool> *result) {
    if (values.size() > MaximumCollectionItems) return false;
    for (const auto &value : values)
        if (!CydiaRuntime::ValidPackageName(value.package) || !CydiaRuntime::ValidArchitectureName(value.architecture) ||
            value.architecture == "any" || value.architecture == "native" ||
            !result->emplace(value.package + ':' + value.architecture, value.automatic).second) return false;
    return true;
}
unsigned Deadline(const RequestControl &control) {
    const unsigned remaining = control.remainingMilliseconds ? control.remainingMilliseconds() : 10000;
    return std::max(1u, std::min(remaining, 10000u));
}
bool Cancelled(const RequestControl &control) {
    return (control.cancelled && control.cancelled()) ||
        (control.remainingMilliseconds && !control.remainingMilliseconds());
}
}
class Broker::Implementation {
public:
    BrokerOptions options;
    Environment environment;
    std::string session, error, originalExtendedState;
    ReviewedTransaction approved;
    std::shared_ptr<const TriggerEffectEnvelope> reviewedEffects;
    ReviewPolicy approvedPolicy;
    std::vector<AutoInstalledDelta> changes;
    ReviewAuthorization authorization;
    std::unique_ptr<Client::ProviderTransaction> transaction;
    int lock = -1, status = -1;
    bool started = false, committed = false, transactionAttempted = false, transactionComplete = false, transactionDenied = false;
    bool observedCommit = false, uncertain = false;
    explicit Implementation(const BrokerOptions &value) : options(value), environment(value.policy.environment) {}
    ~Implementation() { CloseTransaction(); if (lock >= 0) close(lock); }
    bool Fail(const char *code) { error = code; return false; }
    std::string ProviderID() const { return options.recoveryAuthority ? Recovery::ProviderIdentifier() : options.authority.providerIdentifier; }
    std::string ConfigurationID() const { return options.recoveryAuthority ? options.recoveryAuthority->identity.configuration : options.authority.configurationIdentity; }
    std::string PolicyID() const { return options.recoveryAuthority ? options.recoveryAuthority->identity.policy : options.authority.policyIdentity; }
    bool AuthorityValid() const {
        const auto &a = options.authority;
        if (options.recoveryAuthority)
            return a.registrationPath.empty() && a.providerIdentifier.empty() && a.configurationIdentity.empty() && a.policyIdentity.empty() &&
                a.methodsIdentity.empty() && a.libraryIdentity.empty() && a.frontendIdentity.empty() &&
                !Recovery::SerializeRequestAuthority(*options.recoveryAuthority).empty();
        RegistrationIdentity checked;
        return ParseRegistrationIdentity(SerializeRegistrationIdentity(a), &checked);
    }
    CydiaRuntime::Privileged::Request Request(const std::string &payload) const {
        CydiaRuntime::Privileged::Request result; result.expected = environment.paths;
        if (AuthorityValid()) {
            if (options.recoveryAuthority) BrokerRequestPayload(*options.recoveryAuthority, payload, &result.payload);
            else BrokerRequestPayload(options.authority, payload, &result.payload);
        }
        return result;
    }
    bool Capture(DpkgState *state, const RequestControl &control) {
        if (lock < 0 || Cancelled(control)) return Fail("provider_frontend_lock_missing");
        if (transaction) {
            const auto result = transaction->Request(TransactionChannel::Operation::Capture, "", -1, {}, {},
                Deadline(control), control.cancelled);
            started |= result.started || result.indeterminate;
            uncertain |= result.indeterminate;
            if (!result.transportValid || !result.success || !DecodeBrokerState(result.payload, state))
                return Fail(result.errorCode.empty() ? "provider_dpkg_state_unavailable" : result.errorCode.c_str());
            if (state->nativeArchitecture != environment.nativeArchitecture ||
                state->registeredArchitectures != environment.registeredArchitectures) return Fail("provider_architectures_changed");
            return true;
        }
        const auto result = Client::Run(options.helperPath, options.finiteTriggerEffects ? "--cydia-provider-state-effects" :
            "--cydia-provider-state", Request(""), MaximumMessageBytes, Deadline(control));
        if (!result.succeeded() || !DecodeBrokerState(result.output, state)) return Fail("provider_dpkg_state_unavailable");
        if (state->nativeArchitecture != environment.nativeArchitecture ||
            state->registeredArchitectures != environment.registeredArchitectures) return Fail("provider_architectures_changed");
        return true;
    }
    bool Bound(const Binding &binding) const {
        return AuthorityValid() && !session.empty() && binding.session == session && binding.providerIdentifier == ProviderID() &&
            binding.configurationIdentity == ConfigurationID() && binding.policyIdentity == PolicyID();
    }
    void CloseTransaction() {
        if (transaction) { transaction->Close(); transaction.reset(); }
    }
    void Invalidate() {
        CloseTransaction(); authorization.Invalidate(); committed = transactionComplete = transactionAttempted = transactionDenied = false;
        approved = ReviewedTransaction(); reviewedEffects.reset(); changes.clear();
    }
    bool BeginTransaction(const RequestControl &control) {
        if (transactionAttempted) return !transactionDenied;
        transactionAttempted = transactionDenied = true;
        TransactionBeginRequest begin; begin.review = approved; begin.additionalActions = approvedPolicy.additionalActionsReviewed;
        begin.archiveWarnings = approvedPolicy.unverifiedArchiveWarningsAccepted; begin.changes = changes;
        begin.extendedState = originalExtendedState;
        begin.reviewedEffects = reviewedEffects;
        std::string bytes, digest = TransactionBeginDigest(begin);
        if (!EncodeTransactionBegin(begin, &bytes) || digest.empty()) return Fail("provider_invalid_transaction_request");
        std::string code;
        transaction = Client::ProviderTransaction::Start(options.helperPath, Request(bytes), digest, &code,
            Deadline(control), control.cancelled, bool(reviewedEffects));
        if (transaction) { transactionDenied = false; return true; }
        // Existing distributions need not install a declaration merely to use
        // the established restricted executor. Selection happens once before
        // the first mutation; a bad/present graph never falls through, and a
        // retained transaction can never retry through this legacy path.
        if (!reviewedEffects && code == "provider_native_configuration_missing") { transactionDenied = false; return true; }
        transactionDenied = true; return Fail(code.empty() ? "provider_transaction_unavailable" : code.c_str());
    }
    bool Acquire(const Message &request, const RequestControl &control) {
        if (lock >= 0) return Fail("provider_frontend_lock_already_held");
        CydiaRuntime::Privileged::Error ignored;
        // Actual transaction locks preserve Cydia's authenticated self-upgrade
        // session. They are not disposable read-only diagnostic invocations.
        lock = Client::OpenProviderLock(options.helperPath, Request("lock-frontend"), &ignored);
        if (lock < 0) return Fail("provider_frontend_lock_unavailable");
        struct flock value = {}; value.l_type = F_WRLCK; value.l_whence = SEEK_SET;
        if (fcntl(lock, F_SETLK, &value) != 0) { close(lock); lock = -1; return Fail("provider_frontend_busy"); }
        DpkgState state;
        if (!Capture(&state, control) || state.packageStateIdentity != request.binding.packageStateIdentity) {
            close(lock); lock = -1; return Fail("provider_execution_state_changed");
        }
        const auto shared = Client::Run(options.helperPath, "--cydia-provider-extended-read", Request(""), 8 * 1024 * 1024, Deadline(control));
        if (!shared.succeeded()) { close(lock); lock = -1; return Fail("provider_extended_state_unavailable"); }
        originalExtendedState = shared.output; return true;
    }
    void Execute(const Message &message, Message *reply, const RequestControl &control) {
        ParentExecutionReply result;
        // A verified RPC denial before dpkg starts is not an indeterminate
        // mutation. Return a typed executor result even on authorization error.
        const auto deny = [&](const char *code) {
            const std::string saved = code; error = saved; result.launchError = EACCES;
            reply->succeeded = Encode(result, &reply->payload);
        };
        ParentExecutionRequest request;
        if (!Decode(message.payload, &request) || !SameBinding(request.binding, approved.binding) ||
            !authorization.active() || committed || status < 3 || Cancelled(control)) {
            deny("provider_execution_not_approved"); return;
        }
        DpkgState before;
        if (!Capture(&before, control)) { deny(error.c_str()); return; }
        ParentExecutionEvidence evidence; evidence.binding = approved.binding;
        evidence.frontendLockHeld = lock >= 0; evidence.statusDescriptor = status;
        // The finite owner first drains the independently approved pending
        // pool, then derives fresh primary evidence. Pre-drain app state is
        // useful for binding only; it cannot authorize or normalize effects.
        if (!reviewedEffects && !ApplyDpkgStateEvidence(before, approved, request, &evidence, &error)) { deny(error.c_str()); return; }
        std::vector<ArchiveManifest> needed;
        std::set<std::string> ids;
        for (const auto id : request.actions)
            for (const auto &action : approved.execution.actions)
                if (action.identifier == id && action.action == ExecutionAction::Unpack) ids.insert(action.archive);
        for (const auto &archive : approved.execution.archives) if (ids.count(archive.identifier)) needed.push_back(archive);
        // Check every downloaded archive before the first mutation, even when
        // APT first schedules a removal or an already-pending configuration.
        // A bad later archive must not leave those earlier changes applied.
        const auto &requestedArchives = started ? needed : approved.execution.archives;
        if (!transaction && !requestedArchives.empty()) {
            if (!options.archives) { deny("provider_archive_evidence_unavailable"); return; }
            auto proof = options.archives(approved, requestedArchives, control);
            if (!proof.errorCode.empty()) { deny(proof.errorCode.c_str()); return; }
            if (!VerifyReviewedArchiveEvidence(requestedArchives, proof.archives,
                approvedPolicy.unverifiedArchiveWarningsAccepted, &error)) { deny(error.c_str()); return; }
            for (auto &archive : proof.archives)
                if (ids.count(archive.archive.identifier)) evidence.archives.push_back(std::move(archive));
        }
        if (!BeginTransaction(control)) { deny(error.c_str()); return; }
        if (transaction) {
            std::string payload;
            if (!Encode(request, &payload)) { deny("provider_invalid_execution_request"); return; }
            const auto child = transaction->Request(TransactionChannel::Operation::Execute, payload, status,
                approvedPolicy.protectedDpkgOptions, [&] { started = true; }, Deadline(control), control.cancelled);
            result.started = child.started || child.indeterminate; started |= result.started;
            uncertain |= child.indeterminate;
            TransactionExecutionReply settled;
            if (child.transportValid && child.success && DecodeTransactionExecutionReply(child.payload, &settled)) {
                result = settled.result;
                if (!result.started || result.exitCode || result.signal || result.launchError ||
                    settled.state.nativeArchitecture != environment.nativeArchitecture ||
                    settled.state.registeredArchitectures != environment.registeredArchitectures) {
                    result.exitCode = EIO; error = "provider_transaction_settlement_invalid";
                    uncertain = true;
                }
            } else {
                error = child.errorCode.empty() ? "provider_transaction_requires_new_review" : child.errorCode;
                result.exitCode = result.started ? EIO : -1; result.launchError = result.started ? 0 : EACCES;
                uncertain |= result.started && child.success;
            }
            reply->succeeded = Encode(result, &reply->payload); return;
        }
        AuthorizedExecution batch;
        if (Cancelled(control) || !authorization.Authorize(request, evidence, &batch, &error)) { deny(error.empty() ? "provider_cancelled" : error.c_str()); return; }
        BrokerDpkgRequest execution; execution.stateIdentity = before.packageStateIdentity; execution.action = batch.action;
        execution.arguments = batch.arguments; execution.acceptedArchiveWarnings = approvedPolicy.unverifiedArchiveWarningsAccepted;
        for (const auto &archive : batch.archives) execution.archives.push_back(archive.archive);
        std::string payload;
        if (!EncodeBrokerDpkg(execution, &payload)) { Invalidate(); deny("provider_invalid_execution_request"); return; }
        const auto child = Client::RunProviderDpkg(options.helperPath, "--cydia-provider-dpkg", Request(payload), status,
            nullptr, approvedPolicy.protectedDpkgOptions);
        result.started = child.started || child.indeterminate; started = started || result.started;
        uncertain |= child.indeterminate;
        result.exitCode = child.result.kind == CydiaRuntime::Dpkg::ResultKind::Exited ? child.result.code : -1;
        result.signal = child.result.kind == CydiaRuntime::Dpkg::ResultKind::Signaled ? child.result.code : 0;
        result.launchError = child.result.kind == CydiaRuntime::Dpkg::ResultKind::LaunchFailed ? child.result.error : 0;
        // A lost transport after start must not prevent local settlement. Use
        // a fresh bounded read after the actual child is fully reaped.
        RequestControl settle; DpkgState after;
        const bool verified = child.started && child.result.succeeded() && Capture(&after, settle) &&
            VerifyDpkgStateTransition(before, after, approved, batch, &error);
        if (!authorization.Settle(batch.batch, result, after.packageStateIdentity, verified, &error)) {
            // dpkg may exit successfully with effects we cannot establish.
            // Tell the worker the parent did not accept transaction completion.
            if (result.exitCode == 0) result.exitCode = EIO;
        }
        reply->succeeded = Encode(result, &reply->payload);
    }
    void AuthorizeArchive(const Message &message, Message *reply, const RequestControl &control) {
        ArchiveAuthorizationRequest request;
        if (!(options.capabilities & AuthorizedArchiveGrants) || !options.authorizeArchive || lock < 0 ||
            !authorization.active() || committed || started || !SameBinding(message.binding, approved.binding) ||
            !Decode(message.payload, &request) || !SameBinding(request.binding, approved.binding)) {
            Fail("provider_authorization_not_approved"); return;
        }
        const auto found = std::find_if(approved.execution.archives.begin(), approved.execution.archives.end(),
            [&](const ArchiveManifest &archive) { return archive.identifier == request.archive; });
        if (found == approved.execution.archives.end()) { Fail("provider_archive_not_reviewed"); return; }
        using Clock = std::chrono::steady_clock;
        const auto deadline = Clock::now() + std::chrono::milliseconds(std::min(60000u,
            control.remainingMilliseconds ? control.remainingMilliseconds() : 60000u));
        RequestControl bounded;
        bounded.remainingMilliseconds = [deadline, &control]() {
            const auto now = Clock::now();
            if (now >= deadline) return 0u;
            const auto left = static_cast<unsigned>(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count());
            return control.remainingMilliseconds ? std::min(left, control.remainingMilliseconds()) : left;
        };
        bounded.cancelled = [&bounded, &control]() { return Cancelled(control) || !bounded.remainingMilliseconds(); };
        ArchiveAuthorizationReply result;
        if (Cancelled(bounded)) result.status = CydiaRuntime::RepositoryArchiveAuthorizationStatus::Cancelled;
        else {
            DpkgState state;
            if (!Capture(&state, bounded) || state.packageStateIdentity != approved.binding.packageStateIdentity) {
                Fail("provider_execution_state_changed"); return;
            }
            result = options.authorizeArchive(*found, bounded);
            if (Cancelled(bounded)) {
                result = ArchiveAuthorizationReply(); result.status = CydiaRuntime::RepositoryArchiveAuthorizationStatus::Cancelled;
            }
        }
        result.message = CydiaRuntime::RedactDiagnosticURLs(result.message);
        if (!ValidArchiveAuthorizationReply(result)) { Fail("provider_invalid_authorization_reply"); return; }
        reply->succeeded = Encode(result, &reply->payload);
    }
    bool Commit(const Message &message, const RequestControl &control) {
        ExtendedStateRequest request; std::map<std::string, bool> proposed, expected;
        if (committed || (!transaction && !authorization.complete()) || !Decode(message.payload, &request) ||
            !SameBinding(request.binding, approved.binding) || !Deltas(request.changes, &proposed) ||
            !Deltas(changes, &expected) || proposed != expected || Cancelled(control))
            return Fail("provider_extended_state_not_approved");
        if (transaction) {
            std::string encoded;
            if (!Encode(request, &encoded)) return Fail("provider_invalid_transaction_request");
            const auto result = transaction->Request(TransactionChannel::Operation::Commit,
                CydiaRuntime::Privileged::SerializeFields({originalExtendedState, encoded}), -1, {},
                [&] { started = true; }, Deadline(control), control.cancelled);
            started |= result.started || result.indeterminate;
            uncertain |= result.indeterminate;
            if (!result.transportValid || !result.success || !result.started || result.indeterminate || !result.payload.empty()) {
                uncertain |= result.started;
                return Fail(result.errorCode.empty() ? "provider_extended_state_commit_failed" : result.errorCode.c_str());
            }
            observedCommit = transactionComplete = committed = true; return true;
        }
        DpkgState current;
        if (!Capture(&current, control) || current.packageStateIdentity != authorization.stateIdentity())
            return Fail("provider_execution_state_changed");
        std::vector<std::string> fields{options.extendedStatesPath, originalExtendedState};
        for (const auto &change : changes) {
            fields.push_back(change.package); fields.push_back(change.architecture); fields.push_back(change.automatic ? "1" : "0");
        }
        const auto result = Client::Run(options.helperPath, "--cydia-provider-extended-commit",
            Request(CydiaRuntime::Privileged::SerializeFields(fields)), 65536);
        if (!result.succeeded()) { Invalidate(); return Fail("provider_extended_state_commit_failed"); }
        observedCommit = committed = true; return true;
    }
};

Broker::Broker(const BrokerOptions &options) : implementation_(new Implementation(options)) {}
Broker::~Broker() {}
bool Broker::CaptureEffects(const ReviewedTransaction &review, std::shared_ptr<const TriggerEffectEnvelope> *effects,
    std::string *error) {
    auto &value = *implementation_;
    if (!effects) return false;
    effects->reset();
    if (!value.options.finiteTriggerEffects) return true;
    std::string bytes;
    if (value.lock < 0 || !value.Bound(review.binding) || !Encode(review, &bytes))
        return value.Fail("provider_trigger_capture_not_bound");
    const auto result = Client::Run(value.options.helperPath, "--cydia-provider-review-effects", value.Request(bytes), 8 * 1024 * 1024, 10000);
    std::shared_ptr<TriggerEffectEnvelope> captured(new TriggerEffectEnvelope()); std::string original, retained;
    if (!result.succeeded() || !DecodeTriggerEffectEnvelope(result.output, captured.get()) ||
        !Encode(review, &original) || !Encode(captured->primaryReview, &retained) || original != retained) {
        if (error) *error = "provider_trigger_capture_failed";
        return value.Fail("provider_trigger_capture_failed");
    }
    *effects = std::move(captured); return true;
}
bool Broker::BindSession(const Binding &binding) {
    auto &value = *implementation_;
    if (!value.AuthorityValid() || !value.session.empty() || !ValidChallenge(binding.session) ||
        (value.options.finiteTriggerEffects && !(value.options.capabilities & FiniteTriggerEffects)) ||
        binding.providerIdentifier != value.ProviderID() ||
        binding.configurationIdentity != value.environment.configurationIdentity ||
        binding.policyIdentity != value.environment.policyIdentity ||
        binding.configurationIdentity != value.ConfigurationID() || binding.policyIdentity != value.PolicyID()) return value.Fail("provider_binding_invalid");
    value.session = binding.session; return true;
}
bool Broker::Approve(const ReviewedTransaction &review, const std::vector<AutoInstalledDelta> &changes,
                     const std::set<std::uint64_t> &additionalReviewed, const std::set<std::string> &warnings,
                     const std::shared_ptr<const TriggerEffectEnvelope> &effects) {
    auto &value = *implementation_;
    if (value.uncertain) return value.Fail("provider_execution_outcome_unknown");
    value.Invalidate(); value.started = value.observedCommit = false;
    auto policy = value.options.policy; policy.environment = value.environment;
    std::string expected, shown, effectBytes;
    if (bool(effects) != value.options.finiteTriggerEffects || (effects &&
        (!Encode(review, &expected) || !Encode(effects->primaryReview, &shown) || expected != shown ||
            !EncodeTriggerEffectEnvelope(*effects, &effectBytes)))) return value.Fail("provider_trigger_review_changed");
    policy.additionalActionsReviewed = additionalReviewed; policy.unverifiedArchiveWarningsAccepted = warnings;
    std::map<std::string, bool> deltas;
    // Do not approve a manifest known to require effects this parent cannot
    // independently enumerate. Reject before the first otherwise-valid batch.
    for (const auto &action : review.execution.actions)
        if (action.action == ExecutionAction::Deconfigure || (effects && action.action == ExecutionAction::Triggers))
            return value.Fail("provider_unverified_dpkg_effects");
    if (!value.Bound(review.binding) || !Deltas(changes, &deltas) || !value.authorization.Accept(review, policy, &value.error)) return false;
    // APT stores auto flags under cache/package architecture, which differs
    // from the archive's actual "all" architecture. Removal clears flags too.
    std::map<std::string, bool> allowed;
    for (const auto &item : review.transaction.packages) {
        const auto &identity = item.second.identity;
        const bool removal = std::find(review.transaction.removes.begin(), review.transaction.removes.end(), item.first) != review.transaction.removes.end() ||
            std::find(review.transaction.purges.begin(), review.transaction.purges.end(), item.first) != review.transaction.purges.end();
        allowed[identity.baseName + ':' + identity.packageArchitecture] = !removal;
    }
    for (const auto &action : review.execution.actions)
        if (action.action == ExecutionAction::Configure && additionalReviewed.count(action.identifier))
            allowed[action.package.package + ':' + (action.package.architecture == "all" ?
                value.environment.nativeArchitecture : action.package.architecture)] = true;
    for (const auto &delta : deltas) {
        const auto found = allowed.find(delta.first);
        if (found == allowed.end() || (delta.second && !found->second)) {
            value.Invalidate(); return value.Fail("provider_unreviewed_auto_state");
        }
    }
    value.approved = review; value.reviewedEffects = effects;
    value.approvedPolicy = policy; value.changes = changes; value.error.clear(); return true;
}
void Broker::SetStatusDescriptor(int descriptor) { implementation_->status = descriptor; }
void Broker::HandleParentRequest(const Message &request, Message *reply, const RequestControl &control) {
    if (!reply) return;
    *reply = Message(); auto &value = *implementation_;
    if (!value.Bound(request.binding) || !ValidRequestBinding(request)) { reply->errorCode = "provider_binding_invalid"; return; }
    switch (request.operation) {
        case Operation::AcquireFrontendLock:
            reply->succeeded = request.payload.empty() && !Cancelled(control) && value.Acquire(request, control); break;
        case Operation::ReleaseFrontendLock:
            if (!request.payload.empty() || value.lock < 0) { value.Fail("provider_frontend_lock_missing"); break; }
            value.CloseTransaction(); close(value.lock); value.lock = -1; value.originalExtendedState.clear();
            // Preparation may take/release a lock before there is UI approval.
            // A completed transaction remains observable until the next review.
            if (value.authorization.active() && !value.committed) value.Invalidate();
            reply->succeeded = true; break;
        case Operation::CaptureStateSnapshot: {
            if (!request.payload.empty()) { value.Fail("provider_invalid_snapshot_request"); break; }
            Environment captured; CydiaRuntime::Privileged::Error error; bool read = false;
            if (value.options.recoveryAuthority) {
                Recovery::Snapshot snapshot;
                const auto &authority = *value.options.recoveryAuthority;
                read = Client::ReadRecoverySnapshot(value.options.helperPath, authority.preferences,
                    &authority.identity, &snapshot, &error, Deadline(control), control.cancelled);
                if (read) captured = Recovery::SnapshotEnvironment(snapshot);
            } else {
                RegisteredProviderSnapshot snapshot;
                read = Client::ReadProviderSnapshot(value.options.helperPath, value.options.authority.registrationPath,
                    &value.options.authority, &snapshot, &error, Deadline(control), control.cancelled);
                if (read) {
                    const auto &d = snapshot.runtime;
                    captured.paths.aptConfigOverride = d.aptConfigOverride; captured.paths.dpkgRoot = d.dpkgRootDirectory;
                    captured.paths.dpkgAdmin = d.dpkgAdminDirectory; captured.paths.dpkg = d.dpkgExecutablePath;
                    captured.paths.dpkgQuery = d.dpkgQueryExecutablePath; captured.paths.dpkgDeb = d.dpkgDebExecutablePath;
                    captured.paths.sourceList = d.sourceListPath; captured.paths.sourceParts = d.sourcePartsDirectory;
                    captured.configurationIdentity = snapshot.identity.configurationIdentity;
                    captured.policyIdentity = snapshot.identity.policyIdentity; captured.methodsIdentity = snapshot.identity.methodsIdentity;
                    captured.nativeArchitecture = d.architecture; captured.registeredArchitectures = d.registeredArchitectures;
                    captured.acquisitionArchitectures = d.acquisitionArchitectures; captured.packageStateIdentity = snapshot.packageStateIdentity;
                }
            }
            if (!read) {
                value.error = error.code.empty() ? "provider_dpkg_state_unavailable" : error.code; break;
            }
            auto updated = value.environment; updated.packageStateIdentity = captured.packageStateIdentity;
            std::string expectedBytes, actualBytes;
            if (!ValidEnvironment(captured) || !Encode(updated, &expectedBytes) || !Encode(captured, &actualBytes) || expectedBytes != actualBytes) {
                value.Fail("provider_environment_changed"); break;
            }
            reply->succeeded = Encode(updated, &reply->payload);
            if (reply->succeeded) value.environment = updated;
            break;
        }
        case Operation::AuthorizeArchive: value.AuthorizeArchive(request, reply, control); break;
        case Operation::ExecuteDpkg: value.Execute(request, reply, control); break;
        case Operation::CommitExtendedState: reply->succeeded = value.Commit(request, control); break;
        default: value.Fail("provider_parent_operation_unsupported"); break;
    }
    if (!reply->succeeded && reply->errorCode.empty()) reply->errorCode = value.error.empty() ? "provider_parent_operation_failed" : value.error;
}
bool Broker::complete() const {
    return implementation_->observedCommit;
}
bool Broker::lockHeld() const { return implementation_->lock >= 0; }
bool Broker::mutationStarted() const { return implementation_->started; }
bool Broker::indeterminate() const { return implementation_->uncertain && !implementation_->observedCommit; }
const std::string &Broker::errorCode() const { return implementation_->error; }
void Broker::Invalidate() {
    auto &value = *implementation_; value.Invalidate();
    if (value.lock >= 0) { close(value.lock); value.lock = -1; }
    value.originalExtendedState.clear();
}
}} // namespace CydiaAPT::Provider
