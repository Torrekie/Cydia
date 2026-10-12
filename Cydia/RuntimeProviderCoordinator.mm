/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeProviderCoordinator.hpp"
#include "Cydia/AptProviderArchiveEvidence.hpp"
#include "Cydia/AptProviderBroker.hpp"
#include "Cydia/AptProviderSession.hpp"
#include "Cydia/AptProviderLaunch.hpp"
#include "Cydia/AptRecoverySnapshot.hpp"
#include "Cydia/DatabaseStatus.h"
#include "Cydia/PrivilegedClient.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include <cstdlib>

namespace CydiaAPT {
namespace {
namespace P = Provider;
namespace Client = CydiaRuntime::PrivilegedClient;
InitializationOptions startupOptions;
std::string startupConfigurationOverride;
NSString *String(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}
std::string Bytes(NSString *s) {
    const char *bytes([s UTF8String]);
    return bytes ? std::string(bytes, [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) : std::string();
}
struct SessionContext {
    std::unique_ptr<P::Broker> broker;
    std::shared_ptr<P::ArchiveEvidenceSnapshot> archives;
    AcquireStatus *progress = nullptr;
    bool closed = false, uncertain = false;
    void Operation(AcquireStatus *status, int fd) {
        if (progress) progress->endProviderOperation();
        progress = status;
        if (progress) progress->beginProviderOperation();
        broker->SetStatusDescriptor(fd);
    }
};
struct RemoteCandidate {
    std::unique_ptr<AptBackend> backend;
    std::shared_ptr<SessionContext> context;
    RuntimeDescriptor descriptor;
};
RemoteCandidate StartCandidate(AcquireStatus &progress, const RuntimeDescriptor &runtime,
    const std::string &executable, const P::ProbeResult &probe, const P::Hello &hello,
    P::BrokerOptions broker, const std::shared_ptr<const P::RecoveryLaunchCapsule> &capsule = {}) {
    RemoteCandidate result; result.context = std::make_shared<SessionContext>();
    broker.helperPath = runtime.privilegedHelperPath; broker.extendedStatesPath = runtime.extendedStatesPath;
    broker.capabilities = probe.info.capabilities; broker.policy.environment = hello.expected;
    broker.policy.layout.prefix = runtime.packageInstallPrefix;
    if (broker.policy.layout.prefix == "/") broker.policy.layout.foreignPrefixes.push_back("/var/jb");
    broker.policy.protectedDpkgOptions = runtime.dpkgOptions;
    const std::weak_ptr<SessionContext> weak(result.context);
    broker.archives = [weak](const P::ReviewedTransaction &, const std::vector<P::ArchiveManifest> &archives,
        const P::RequestControl &control) {
        P::BrokerArchiveEvidence evidence; auto context(weak.lock());
        if (!context || !context->archives) evidence.errorCode = "provider_archive_review_missing";
        else context->archives->Verify(archives, &evidence.archives, control.cancelled, &evidence.errorCode);
        return evidence;
    };
    broker.authorizeArchive = [weak](const P::ArchiveManifest &archive, const P::RequestControl &control) {
        P::ArchiveAuthorizationReply result; auto context(weak.lock());
        CydiaRuntime::RepositoryArchiveAuthorizationRequest request; bool commercial(false); std::string error;
        if (!context || !context->archives || !context->archives->AuthorizationRequest(
            archive, &request, &commercial, control.cancelled, &error)) return result;
        if (!commercial) { result.status = CydiaRuntime::RepositoryArchiveAuthorizationStatus::NotRequired; return result; }
        result = CydiaRuntime::AuthorizeRepositoryArchive(request, control.cancelled);
        CydiaRuntime::RepositoryArchiveAuthorizationRequest rechecked; bool stillCommercial(false);
        if (!context->archives->AuthorizationRequest(archive, &rechecked, &stillCommercial, control.cancelled, &error) ||
            !stillCommercial) return P::ArchiveAuthorizationReply();
        return result;
    };
    result.context->broker.reset(new P::Broker(broker));
    P::SessionCallbacks callbacks;
    callbacks.parentRequest = [weak](const P::Message &request, P::Message *reply, const P::RequestControl &control) {
        if (auto context = weak.lock()) context->broker->HandleParentRequest(request, reply, control);
        else reply->errorCode = "provider_parent_unavailable";
    };
    callbacks.progress = [weak](const P::ProgressEvent &event) {
        if (auto context = weak.lock()) if (context->progress) context->progress->updateProviderProgress(event);
    };
    callbacks.closed = [weak](bool uncertain) {
        if (auto context = weak.lock()) {
            context->closed = true; context->uncertain |= uncertain; context->broker->Invalidate();
        }
    };
    std::unique_ptr<P::Session> session(new P::Session());
    const bool started = capsule ? session->StartRecovery(executable, probe, hello, capsule, callbacks) :
        session->Start(executable, probe, hello, callbacks);
    if (started && result.context->broker->BindSession(session->binding())) {
        result.descriptor = runtime;
        result.descriptor.origin = capsule ? RuntimeDescriptorOrigin::RecoveryWorker : RuntimeDescriptorOrigin::External;
        auto &binding = result.descriptor.binding; const auto &admitted = session->binding();
        binding.session = admitted.session; binding.providerIdentifier = admitted.providerIdentifier;
        binding.libraryIdentity = probe.info.libraryIdentity; binding.frontendIdentity = probe.info.frontendIdentity;
        binding.configurationIdentity = admitted.configurationIdentity; binding.policyIdentity = admitted.policyIdentity;
        binding.methodsIdentity = hello.expected.methodsIdentity; binding.packageStateIdentity = admitted.packageStateIdentity;
        RemoteBackendOptions options; options.status = &progress;
        const auto context(result.context);
        options.operationContext = [context](AcquireStatus *status, int fd) { context->Operation(status, fd); };
        options.cancelled = [context]() { return context->progress && context->progress->pollProviderCancellation(); };
        if (ValidateRuntimeDescriptor(result.descriptor, binding)) result.backend.reset(new AptBackend(std::move(session), options));
    }
    if (!result.backend) result.context.reset();
    return result;
}
// A handshake proves the protocol, not that this runtime can read the selected
// sources and package database. Keep the previous backend until these ordinary
// read-only operations and the helper's fresh authority check both succeed.
bool CaptureOpenedAuthority(const AptBackend &backend, const RuntimeDescriptor &descriptor,
    P::RegisteredProviderSnapshot *selected, Recovery::Snapshot *recovery, P::Binding *binding) {
    CydiaRuntime::Privileged::Error error;
    if (!binding || !backend.providerBinding(binding) ||
        binding->providerIdentifier != descriptor.binding.providerIdentifier || binding->session != descriptor.binding.session ||
        binding->configurationIdentity != descriptor.binding.configurationIdentity || binding->policyIdentity != descriptor.binding.policyIdentity)
        return false;
    if (descriptor.origin == RuntimeDescriptorOrigin::RecoveryWorker) {
        Recovery::Snapshot snapshot, expected(*recovery);
        const auto authority(Recovery::AuthorityRequest(*recovery));
        if (!Client::ReadRecoverySnapshot(descriptor.privilegedHelperPath, authority.preferences, &authority.identity,
            &snapshot, &error, 4000, {}) || snapshot.packageStateIdentity != binding->packageStateIdentity) return false;
        expected.packageStateIdentity = snapshot.packageStateIdentity;
        if (Recovery::SerializeSnapshot(expected) != Recovery::SerializeSnapshot(snapshot)) return false;
        *recovery = std::move(snapshot);
    } else {
        P::RegisteredProviderSnapshot snapshot, expected(*selected);
        if (!Client::ReadProviderSnapshot(descriptor.privilegedHelperPath, selected->identity.registrationPath,
            &selected->identity, &snapshot, &error, 4000, {}) || snapshot.packageStateIdentity != binding->packageStateIdentity) return false;
        expected.packageStateIdentity = snapshot.packageStateIdentity;
        snapshot.runtime.repositorySecurityMode = expected.runtime.repositorySecurityMode;
        if (P::SerializeRegisteredProviderSnapshot(expected) != P::SerializeRegisteredProviderSnapshot(snapshot)) return false;
        *selected = std::move(snapshot);
    }
    return true;
}
bool AdmitCandidate(RemoteCandidate *candidate, P::RegisteredProviderSnapshot *selected, Recovery::Snapshot *recovery) {
    if (!candidate || !candidate->backend) return false;
    AptBackend &backend(*candidate->backend);
    backend.discardErrors();
    const bool loaded(backend.loadSources());
    const auto sourceErrors(backend.drainErrors());
    bool accepted(loaded);
    for (const auto &error : sourceErrors) accepted &= error.warning;
    if (accepted) accepted = backend.openCache();
    const auto cacheErrors(backend.drainErrors());
    for (const auto &error : cacheErrors) accepted &= error.warning;
    P::Binding binding;
    accepted = accepted && CaptureOpenedAuthority(backend, candidate->descriptor, selected, recovery, &binding);
    candidate->context->Operation(nullptr, -1);
    if (accepted) {
        candidate->descriptor.binding.packageStateIdentity = binding.packageStateIdentity;
        accepted = ValidateRuntimeDescriptor(candidate->descriptor, candidate->descriptor.binding);
    }
    if (!accepted) { candidate->backend.reset(); candidate->context.reset(); }
    return accepted;
}
}
void ConfigureRuntimeProviderStartup(const InitializationOptions &options) {
    startupOptions = options;
    const char *configuration = std::getenv("APT_CONFIG");
    startupConfigurationOverride = configuration ? configuration : "";
}

class RuntimeProviderCoordinator::Implementation {
public:
    InitializationOptions options = startupOptions;
    std::shared_ptr<SessionContext> context;
    P::RegisteredProviderSnapshot selected;
    Recovery::Snapshot recovery;
    std::string preference, securityPreference;
    bool recoveryWorker = false;
    CydiaRuntimeProviderStatus *__strong status;
    P::ReviewedTransaction reviewed;
    std::vector<AutoInstalledDelta> deltas;
    std::string reviewBytes;
    bool captured = false, approved = false, initialized = false;

    Implementation() : status([[CydiaRuntimeProviderStatus alloc] initWithPreference:@"automatic"
        state:CydiaRuntimeProviderStateUnchecked providerName:nil providerVersion:nil aptVersion:nil diagnostic:nil]) {}

    void ClearReview() {
        captured = approved = false; reviewed = P::ReviewedTransaction(); deltas.clear(); reviewBytes.clear();
        if (context) context->archives.reset();
    }
};

RuntimeProviderCoordinator::RuntimeProviderCoordinator() : implementation_(new Implementation()) {}
RuntimeProviderCoordinator::~RuntimeProviderCoordinator() = default;
CydiaRuntimeProviderStatus *RuntimeProviderCoordinator::Status() const { return implementation_->status; }
bool RuntimeProviderCoordinator::external() const { return remote() && !implementation_->recoveryWorker; }
bool RuntimeProviderCoordinator::remote() const { return implementation_->context != nullptr; }
bool RuntimeProviderCoordinator::healthy() const {
    return implementation_->initialized && (!implementation_->context || !implementation_->context->closed);
}
bool RuntimeProviderCoordinator::ready() const { return healthy(); }
bool RuntimeProviderCoordinator::indeterminate() const {
    return implementation_->context && implementation_->context->uncertain;
}

bool RuntimeProviderCoordinator::AcceptOpenedCache(const AptBackend &backend) {
    auto &state(*implementation_);
    if (!remote()) return true;
    const auto descriptor(ActiveRuntimeDescriptor());
    P::Binding binding;
    return descriptor && CaptureOpenedAuthority(backend, *descriptor, &state.selected, &state.recovery, &binding) &&
        UpdateRuntimeDescriptorPackageState(descriptor->binding, binding.packageStateIdentity);
}

bool RuntimeProviderCoordinator::Select(AptBackend **backend, AcquireStatus &progress, NSString *preference,
    NSString *securityPreference, bool allowRecovery, NSString **diagnostic, bool explicitRequest) {
    auto &state(*implementation_);
    if (diagnostic) *diagnostic = nil;
    if (!backend || indeterminate()) {
        if (diagnostic) *diagnostic = CydiaRuntimeProviderLocalize(@"BROKEN_HELP");
        return false;
    }
    const std::string nextPreference(Bytes(preference)), nextSecurity(Bytes(securityPreference));
    // A security-only edit on the transitional in-process engine is an
    // existing reversible local override. It does not require or imply a
    // verified worker, and cannot destroy a working backend on failure.
    if (explicitRequest && state.initialized && !remote() && state.preference == nextPreference &&
        state.securityPreference != nextSecurity) {
        if (!SetRepositorySecurityMode(EffectiveRepositorySecurityMode(nextSecurity, false))) {
            if (diagnostic) *diagnostic = CydiaRuntimeProviderLocalize(@"BROKEN_HELP"); return false;
        }
        state.ClearReview(); state.securityPreference = nextSecurity;
        return true;
    }
    const bool requestedRecovery([preference isEqualToString:@"recovery"]);
    P::SelectionResult selection;
    RemoteCandidate candidate;
    P::ProbeResult selectedProbe;
    P::Environment selectedEnvironment;
    Recovery::Snapshot recoverySnapshot;
    if (!requestedRecovery) {
        const std::string helper(state.options.helperPath);
        auto reader = [helper](const std::string &path, const P::RegistrationIdentity *expected,
            P::RegisteredProviderSnapshot *snapshot, CydiaRuntime::Privileged::Error *error,
            unsigned timeout, const std::function<bool()> &cancelled) {
            return Client::ReadProviderSnapshot(helper, path, expected, snapshot, error, timeout, cancelled);
        };
        selection = P::DiscoverProvider(CydiaRuntime::PackageDatabasePaths::Current(), state.options, nextSecurity, reader);
        if (selection.ready()) {
            P::BrokerOptions broker; broker.authority = selection.snapshot.identity;
            candidate = StartCandidate(progress, selection.snapshot.runtime, selection.snapshot.executable,
                selection.probe, selection.hello, broker);
            if (AdmitCandidate(&candidate, &selection.snapshot, &recoverySnapshot)) {
                selectedProbe = selection.probe; selectedEnvironment = selection.hello.expected;
                selectedEnvironment.packageStateIdentity = selection.snapshot.packageStateIdentity;
            }
            else { selection.availability = P::Availability::Broken; selection.errorCode = "provider_session_unavailable"; }
        }
    }
    if (!candidate.backend && (requestedRecovery || allowRecovery)) {
        Recovery::Preferences choices;
        choices.aptConfigOverride = startupConfigurationOverride; choices.securityPreference = nextSecurity;
        choices.translation = state.options.translation; choices.languages = state.options.languages;
        choices.maxParallel = state.options.maxParallel; choices.forceEssential = state.options.forceEssential;
        CydiaRuntime::Privileged::Error error;
        if (Client::ReadRecoverySnapshot(state.options.helperPath, choices, nullptr, &recoverySnapshot, &error, 4000, {})) {
            const auto bytes(Recovery::SerializeSnapshot(recoverySnapshot)); std::string launchError;
            const auto capsule(P::RecoveryLaunchCapsule::Create(bytes, state.options.cacheDirectory, &launchError));
            if (capsule) {
                P::Hello hello; hello.options = recoverySnapshot.startup; hello.expected = Recovery::SnapshotEnvironment(recoverySnapshot);
                if (hello.options.repositorySecurityMode != RepositorySecurityMode::Distribution)
                    hello.requiredCapabilities |= P::ExplicitSecurityOverrides;
                const auto probe(P::ProbeRecovery(recoverySnapshot.executable, hello.expected, capsule));
                Recovery::Snapshot checked;
                if (probe.compatible() && probe.info.identifier == Recovery::ProviderIdentifier() &&
                    probe.info.libraryIdentity == recoverySnapshot.identity.libraries &&
                    probe.info.frontendIdentity == recoverySnapshot.identity.frontend &&
                    (probe.info.capabilities & hello.requiredCapabilities) == hello.requiredCapabilities &&
                    Client::ReadRecoverySnapshot(state.options.helperPath, choices, &recoverySnapshot.identity, &checked, &error, 4000, {}) &&
                    Recovery::SerializeSnapshot(checked) == bytes) {
                    P::BrokerOptions broker;
                    broker.recoveryAuthority = std::make_shared<const Recovery::RequestAuthority>(Recovery::AuthorityRequest(recoverySnapshot));
                    candidate = StartCandidate(progress, recoverySnapshot.runtime, recoverySnapshot.executable, probe, hello, broker, capsule);
                    if (AdmitCandidate(&candidate, &selection.snapshot, &recoverySnapshot)) {
                        selectedProbe = probe; selectedEnvironment = Recovery::SnapshotEnvironment(recoverySnapshot);
                    }
                }
            }
        }
    }
    // An explicit request never silently substitutes the transitional engine.
    // All candidate work above was read-only and leaves the old backend intact.
    if (!candidate.backend && (explicitRequest || (!requestedRecovery && !allowRecovery))) {
        if (diagnostic) *diagnostic = CydiaRuntimeProviderLocalize(requestedRecovery ? @"BROKEN_HELP" :
            selection.availability == P::Availability::Missing ? @"MISSING_HELP" :
            selection.availability == P::Availability::Unsupported ? @"UNSUPPORTED_HELP" : @"BROKEN_HELP");
        return false;
    }
    if (candidate.backend) {
        // Validate before touching the working selection. Adoption is a pure
        // immutable descriptor swap under Database's gate; if it unexpectedly
        // fails, restore the prior descriptor and keep its live backend.
        const auto previous(ActiveRuntimeDescriptor()); const bool previousTrust(CachedRepositoryTrustValid());
        ResetRuntimeDescriptor();
        if (!AdoptRuntimeDescriptor(candidate.descriptor, candidate.descriptor.binding)) {
            if (previous && AdoptRuntimeDescriptor(*previous, previous->binding)) SetRuntimeDescriptorTrustValid(previous->binding, previousTrust);
            if (diagnostic) *diagnostic = CydiaRuntimeProviderLocalize(@"BROKEN_HELP"); return false;
        }
        delete *backend; *backend = nullptr;
        state.ClearReview(); state.context.reset(); Client::ClearProviderAuthority(); Client::ClearLockBridge();
        const auto &descriptor(candidate.descriptor);
        state.recoveryWorker = descriptor.origin == RuntimeDescriptorOrigin::RecoveryWorker;
        if (state.recoveryWorker) Client::ConfigureRecoveryAuthority(descriptor.privilegedHelperPath,
            Recovery::AuthorityRequest(recoverySnapshot), selectedEnvironment.paths);
        else Client::ConfigureProviderAuthority(descriptor.privilegedHelperPath, selection.snapshot.identity, selectedEnvironment.paths);
        Client::ConfigureLockBridge(descriptor.privilegedHelperPath, selectedEnvironment.paths);
        state.context = candidate.context; state.selected = selection.snapshot; state.recovery = recoverySnapshot;
        *backend = candidate.backend.release(); state.initialized = true;
        state.preference = nextPreference; state.securityPreference = nextSecurity;
        state.status = [[CydiaRuntimeProviderStatus alloc] initWithPreference:preference
            state:state.recoveryWorker ? CydiaRuntimeProviderStateRecoveryActive : CydiaRuntimeProviderStateExternalActive
            providerName:state.recoveryWorker ? CydiaRuntimeProviderLocalize(@"RECOVERY") : String(selectedProbe.info.identifier)
            providerVersion:String(selectedProbe.info.implementationVersion) aptVersion:nil diagnostic:nil];
        return true;
    }
    // Transitional startup fallback only. No running operation can arrive
    // here, and no explicit Settings choice is reported as a worker success.
    delete *backend; *backend = nullptr;
    state.ClearReview(); state.context.reset(); state.recoveryWorker = false; state.initialized = false;
    state.selected = P::RegisteredProviderSnapshot(); state.recovery = Recovery::Snapshot();
    ResetRuntimeDescriptor(); Client::ClearProviderAuthority(); Client::ClearLockBridge();
    InitializationOptions options(state.options);
    options.repositorySecurityMode = EffectiveRepositorySecurityMode(nextSecurity, false);
    std::string architecture; const bool initialized(Initialize(options, &architecture));
    state.initialized = initialized; *backend = new AptBackend(progress);
    Client::ConfigureLockBridge(options.helperPath, Client::CurrentExpectedEnvironment());
    NSString *detail(CydiaRuntimeProviderLocalize(requestedRecovery || !initialized ? @"BROKEN_HELP" :
        selection.availability == P::Availability::Missing ? @"MISSING_HELP" :
        selection.availability == P::Availability::Unsupported ? @"UNSUPPORTED_HELP" : @"BROKEN_HELP"));
    state.preference = nextPreference; state.securityPreference = nextSecurity;
    state.status = [[CydiaRuntimeProviderStatus alloc] initWithPreference:preference
        state:initialized ? CydiaRuntimeProviderStateRecoveryActive : CydiaRuntimeProviderStateBroken
        providerName:initialized ? CydiaRuntimeProviderLocalize(@"RECOVERY") : nil
        providerVersion:nil aptVersion:nil diagnostic:detail];
    if (!initialized && diagnostic) *diagnostic = detail;
    return initialized;
}

bool RuntimeProviderCoordinator::CaptureReview(AptBackend &backend, TransactionData *transaction, std::string *error) {
    auto &state(*implementation_); state.ClearReview();
    *transaction = backend.transactionData();
    if (!remote()) { state.captured = true; return true; }
    if (!backend.providerReview(&state.reviewed) || !P::Encode(state.reviewed, &state.reviewBytes)) {
        if (error) *error = "provider_review_missing"; return false;
    }
    state.deltas = backend.autoInstalledDeltas();
    state.context->archives = P::ArchiveEvidenceSnapshot::Capture(*ActiveRuntimeDescriptor(), state.reviewed,
        state.recoveryWorker ? state.recovery.acquisitionSearchPath : state.selected.executableSearchPath, {}, error);
    state.captured = state.context->archives != nullptr;
    return state.captured;
}
bool RuntimeProviderCoordinator::ApproveReview(AptBackend &backend, const std::set<std::uint64_t> &shownActions,
    const std::set<std::string> &shownWarnings, std::string *error) {
    auto &state(*implementation_);
    if (!state.captured || state.approved || !ReviewUnchanged(backend)) {
        if (error) *error = "provider_review_changed"; return false;
    }
    if (remote() && !state.context->broker->Approve(state.reviewed, state.deltas, shownActions, shownWarnings)) {
        if (error) *error = state.context->broker->errorCode(); return false;
    }
    state.approved = true; return true;
}
bool RuntimeProviderCoordinator::ReviewUnchanged(const AptBackend &backend) const {
    const auto &state(*implementation_);
    if (!state.captured) return false;
    if (!remote()) return true;
    P::ReviewedTransaction current; std::string bytes;
    return healthy() && backend.providerReview(&current) && P::Encode(current, &bytes) && bytes == state.reviewBytes;
}
void RuntimeProviderCoordinator::InvalidateReview() { implementation_->ClearReview(); }
bool RuntimeProviderCoordinator::executionComplete() const {
    return !remote() || (implementation_->approved && implementation_->context->broker->complete());
}
const Provider::ReviewedTransaction *RuntimeProviderCoordinator::review() const {
    return remote() && implementation_->captured ? &implementation_->reviewed : nullptr;
}
}
