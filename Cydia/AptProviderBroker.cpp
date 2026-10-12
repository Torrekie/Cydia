/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderBroker.hpp"
#include "Cydia/AptProviderBrokerPrivileged.hpp"
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
    ReviewPolicy approvedPolicy;
    std::vector<AutoInstalledDelta> changes;
    ReviewAuthorization authorization;
    int lock = -1, status = -1;
    bool started = false, committed = false;
    explicit Implementation(const BrokerOptions &value) : options(value), environment(value.policy.environment) {}
    ~Implementation() { if (lock >= 0) close(lock); }
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
        const auto result = Client::Run(options.helperPath, "--cydia-provider-state", Request(""), MaximumMessageBytes, Deadline(control));
        if (!result.succeeded() || !DecodeBrokerState(result.output, state)) return Fail("provider_dpkg_state_unavailable");
        if (state->nativeArchitecture != environment.nativeArchitecture ||
            state->registeredArchitectures != environment.registeredArchitectures) return Fail("provider_architectures_changed");
        return true;
    }
    bool Bound(const Binding &binding) const {
        return AuthorityValid() && !session.empty() && binding.session == session && binding.providerIdentifier == ProviderID() &&
            binding.configurationIdentity == ConfigurationID() && binding.policyIdentity == PolicyID();
    }
    void Invalidate() { authorization.Invalidate(); committed = false; approved = ReviewedTransaction(); changes.clear(); }
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
        if (!ApplyDpkgStateEvidence(before, approved, request, &evidence, &error)) { deny(error.c_str()); return; }
        std::vector<ArchiveManifest> needed;
        std::set<std::string> ids;
        for (const auto id : request.actions)
            for (const auto &action : approved.execution.actions)
                if (action.identifier == id && action.action == ExecutionAction::Unpack) ids.insert(action.archive);
        for (const auto &archive : approved.execution.archives) if (ids.count(archive.identifier)) needed.push_back(archive);
        if (!needed.empty()) {
            if (!options.archives) { deny("provider_archive_evidence_unavailable"); return; }
            auto proof = options.archives(approved, needed, control);
            if (!proof.errorCode.empty()) { deny(proof.errorCode.c_str()); return; }
            evidence.archives = std::move(proof.archives);
        }
        AuthorizedExecution batch;
        if (Cancelled(control) || !authorization.Authorize(request, evidence, &batch, &error)) { deny(error.empty() ? "provider_cancelled" : error.c_str()); return; }
        BrokerDpkgRequest execution; execution.stateIdentity = before.packageStateIdentity; execution.action = batch.action;
        execution.arguments = batch.arguments; execution.acceptedArchiveWarnings = approvedPolicy.unverifiedArchiveWarningsAccepted;
        for (const auto &archive : batch.archives) execution.archives.push_back(archive.archive);
        std::string payload;
        if (!EncodeBrokerDpkg(execution, &payload)) { Invalidate(); deny("provider_invalid_execution_request"); return; }
        const auto child = Client::RunProviderDpkg(options.helperPath, "--cydia-provider-dpkg", Request(payload), status);
        result.started = child.started || child.indeterminate; started = started || result.started;
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
        if (committed || !authorization.complete() || !Decode(message.payload, &request) ||
            !SameBinding(request.binding, approved.binding) || !Deltas(request.changes, &proposed) ||
            !Deltas(changes, &expected) || proposed != expected || Cancelled(control))
            return Fail("provider_extended_state_not_approved");
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
        committed = true; return true;
    }
};

Broker::Broker(const BrokerOptions &options) : implementation_(new Implementation(options)) {}
Broker::~Broker() {}
bool Broker::BindSession(const Binding &binding) {
    auto &value = *implementation_;
    if (!value.AuthorityValid() || !value.session.empty() || !ValidChallenge(binding.session) ||
        binding.providerIdentifier != value.ProviderID() ||
        binding.configurationIdentity != value.environment.configurationIdentity ||
        binding.policyIdentity != value.environment.policyIdentity ||
        binding.configurationIdentity != value.ConfigurationID() || binding.policyIdentity != value.PolicyID()) return value.Fail("provider_binding_invalid");
    value.session = binding.session; return true;
}
bool Broker::Approve(const ReviewedTransaction &review, const std::vector<AutoInstalledDelta> &changes,
                     const std::set<std::uint64_t> &additionalReviewed, const std::set<std::string> &warnings) {
    auto &value = *implementation_; value.Invalidate(); value.started = false;
    auto policy = value.options.policy; policy.environment = value.environment;
    policy.additionalActionsReviewed = additionalReviewed; policy.unverifiedArchiveWarningsAccepted = warnings;
    std::map<std::string, bool> deltas;
    // Do not approve a manifest known to require effects this parent cannot
    // independently enumerate. Reject before the first otherwise-valid batch.
    for (const auto &action : review.execution.actions)
        if (action.action == ExecutionAction::Deconfigure)
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
    value.approved = review; value.approvedPolicy = policy; value.changes = changes; value.error.clear(); return true;
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
            close(value.lock); value.lock = -1; value.originalExtendedState.clear();
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
bool Broker::complete() const { return implementation_->committed && implementation_->authorization.complete(); }
bool Broker::lockHeld() const { return implementation_->lock >= 0; }
bool Broker::mutationStarted() const { return implementation_->started; }
const std::string &Broker::errorCode() const { return implementation_->error; }
void Broker::Invalidate() {
    auto &value = *implementation_; value.Invalidate();
    if (value.lock >= 0) { close(value.lock); value.lock = -1; }
    value.originalExtendedState.clear();
}
}} // namespace CydiaAPT::Provider
