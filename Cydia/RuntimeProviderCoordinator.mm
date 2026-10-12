/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeProviderCoordinator.hpp"
#include "Cydia/AptProviderArchiveEvidence.hpp"
#include "Cydia/AptProviderBroker.hpp"
#include "Cydia/AptProviderSession.hpp"
#include "Cydia/DatabaseStatus.h"
#include "Cydia/PrivilegedClient.h"
#include "Cydia/PackageDatabasePaths.hpp"

namespace CydiaAPT {
namespace {
namespace P = Provider;
namespace Client = CydiaRuntime::PrivilegedClient;
InitializationOptions startupOptions;
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
}
void ConfigureRuntimeProviderStartup(const InitializationOptions &options) { startupOptions = options; }

class RuntimeProviderCoordinator::Implementation {
public:
    InitializationOptions options = startupOptions;
    std::shared_ptr<SessionContext> context;
    P::RegisteredProviderSnapshot selected;
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
bool RuntimeProviderCoordinator::external() const { return implementation_->context != nullptr; }
bool RuntimeProviderCoordinator::healthy() const {
    return implementation_->initialized && (!implementation_->context || !implementation_->context->closed);
}
bool RuntimeProviderCoordinator::ready() const { return healthy(); }
bool RuntimeProviderCoordinator::indeterminate() const {
    return implementation_->context && implementation_->context->uncertain;
}

bool RuntimeProviderCoordinator::AcceptOpenedCache(const AptBackend &backend) {
    auto &state(*implementation_);
    if (!external()) return true;
    const auto descriptor(ActiveRuntimeDescriptor());
    P::Binding binding; P::RegisteredProviderSnapshot snapshot; CydiaRuntime::Privileged::Error error;
    if (!descriptor || !backend.providerBinding(&binding) ||
        binding.providerIdentifier != descriptor->binding.providerIdentifier || binding.session != descriptor->binding.session ||
        binding.configurationIdentity != descriptor->binding.configurationIdentity || binding.policyIdentity != descriptor->binding.policyIdentity ||
        !Client::ReadProviderSnapshot(descriptor->privilegedHelperPath, state.selected.identity.registrationPath,
            &state.selected.identity, &snapshot, &error, 4000, {}) || snapshot.packageStateIdentity != binding.packageStateIdentity)
        return false;
    P::RegisteredProviderSnapshot expected(state.selected);
    expected.packageStateIdentity = snapshot.packageStateIdentity;
    snapshot.runtime.repositorySecurityMode = expected.runtime.repositorySecurityMode;
    // The snapshot codec omits the live session; a cache refresh cannot change
    // any registered path, option, architecture or distribution component.
    if (P::SerializeRegisteredProviderSnapshot(expected) != P::SerializeRegisteredProviderSnapshot(snapshot)) return false;
    if (!UpdateRuntimeDescriptorPackageState(descriptor->binding, binding.packageStateIdentity)) return false;
    state.selected = snapshot;
    return true;
}

bool RuntimeProviderCoordinator::Select(AptBackend **backend, AcquireStatus &progress, NSString *preference,
    NSString *securityPreference, bool allowRecovery, NSString **diagnostic) {
    auto &state(*implementation_);
    if (diagnostic) *diagnostic = nil;
    if (!backend || indeterminate()) {
        if (diagnostic) *diagnostic = CydiaRuntimeProviderLocalize(@"BROKEN_HELP");
        return false;
    }
    const bool recovery([preference isEqualToString:@"recovery"]);
    P::SelectionResult selection;
    if (!recovery) {
        const std::string helper(state.options.helperPath);
        auto reader = [helper](const std::string &path, const P::RegistrationIdentity *expected,
            P::RegisteredProviderSnapshot *snapshot, CydiaRuntime::Privileged::Error *error,
            unsigned timeout, const std::function<bool()> &cancelled) {
            return Client::ReadProviderSnapshot(helper, path, expected, snapshot, error, timeout, cancelled);
        };
        selection = P::DiscoverProvider(CydiaRuntime::PackageDatabasePaths::Current(), state.options,
            Bytes(securityPreference), reader);
    }
    std::unique_ptr<AptBackend> candidate;
    std::shared_ptr<SessionContext> context;
    RuntimeDescriptor descriptor;
    if (!recovery && selection.ready()) {
        context = std::make_shared<SessionContext>();
        P::BrokerOptions broker;
        broker.helperPath = selection.snapshot.runtime.privilegedHelperPath;
        broker.extendedStatesPath = selection.snapshot.runtime.extendedStatesPath;
        broker.authority = selection.snapshot.identity;
        broker.policy.environment = selection.hello.expected;
        broker.policy.layout.prefix = selection.snapshot.runtime.packageInstallPrefix;
        if (broker.policy.layout.prefix == "/") broker.policy.layout.foreignPrefixes.push_back("/var/jb");
        broker.policy.protectedDpkgOptions = selection.snapshot.runtime.dpkgOptions;
        const std::weak_ptr<SessionContext> weak(context);
        broker.archives = [weak](const P::ReviewedTransaction &, const std::vector<P::ArchiveManifest> &archives,
            const P::RequestControl &control) {
            P::BrokerArchiveEvidence evidence;
            auto context(weak.lock());
            if (!context || !context->archives) evidence.errorCode = "provider_archive_review_missing";
            else context->archives->Verify(archives, &evidence.archives, control.cancelled, &evidence.errorCode);
            return evidence;
        };
        context->broker.reset(new P::Broker(broker));
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
                context->closed = true; context->uncertain |= uncertain;
                context->broker->Invalidate();
            }
        };
        std::unique_ptr<P::Session> session(new P::Session());
        if (session->Start(selection.snapshot.executable, selection.probe, selection.hello, callbacks) &&
            context->broker->BindSession(session->binding())) {
            descriptor = selection.snapshot.runtime;
            descriptor.binding.session = session->binding().session;
            descriptor.binding.providerIdentifier = session->binding().providerIdentifier;
            descriptor.binding.libraryIdentity = selection.probe.info.libraryIdentity;
            descriptor.binding.frontendIdentity = selection.probe.info.frontendIdentity;
            descriptor.binding.configurationIdentity = session->binding().configurationIdentity;
            descriptor.binding.policyIdentity = session->binding().policyIdentity;
            descriptor.binding.methodsIdentity = selection.hello.expected.methodsIdentity;
            descriptor.binding.packageStateIdentity = session->binding().packageStateIdentity;
            RemoteBackendOptions backendOptions;
            backendOptions.status = &progress;
            backendOptions.operationContext = [context](AcquireStatus *status, int fd) { context->Operation(status, fd); };
            backendOptions.cancelled = [context]() { return context->progress && context->progress->pollProviderCancellation(); };
            if (ValidateRuntimeDescriptor(descriptor, descriptor.binding))
                candidate.reset(new AptBackend(std::move(session), backendOptions));
        }
        if (!candidate) {
            selection.availability = P::Availability::Broken;
            selection.errorCode = "provider_session_unavailable";
            context.reset();
        }
    }
    if (!candidate && !recovery && !allowRecovery) {
        if (diagnostic) *diagnostic = CydiaRuntimeProviderLocalize(
            selection.availability == P::Availability::Missing ? @"MISSING_HELP" :
            selection.availability == P::Availability::Unsupported ? @"UNSUPPORTED_HELP" : @"BROKEN_HELP");
        return false;
    }

    // No operation may overlap this commit. Destruction closes the old worker
    // before replacing global path getters or its privileged authority.
    delete *backend; *backend = nullptr;
    state.context.reset(); state.ClearReview();
    state.initialized = false;
    ResetRuntimeDescriptor(); Client::ClearProviderAuthority(); Client::ClearLockBridge();
    if (candidate && !AdoptRuntimeDescriptor(descriptor, descriptor.binding)) {
        candidate.reset(); context.reset();
        selection.availability = P::Availability::Broken;
    }
    if (candidate) {
        Client::ConfigureProviderAuthority(descriptor.privilegedHelperPath, selection.snapshot.identity,
            selection.hello.expected.paths);
        Client::ConfigureLockBridge(descriptor.privilegedHelperPath, selection.hello.expected.paths);
        state.context = context; state.selected = selection.snapshot;
        *backend = candidate.release();
        state.initialized = true;
        state.status = [[CydiaRuntimeProviderStatus alloc] initWithPreference:preference
            state:CydiaRuntimeProviderStateExternalActive providerName:String(selection.probe.info.identifier)
            providerVersion:String(selection.probe.info.implementationVersion) aptVersion:nil diagnostic:nil];
        return true;
    }
    InitializationOptions options(state.options);
    options.repositorySecurityMode = EffectiveRepositorySecurityMode(Bytes(securityPreference), false);
    std::string architecture;
    const bool initialized(Initialize(options, &architecture));
    state.initialized = initialized;
    *backend = new AptBackend(progress);
    Client::ConfigureLockBridge(options.helperPath, Client::CurrentExpectedEnvironment());
    NSString *detail(nil);
    if (!recovery) detail = CydiaRuntimeProviderLocalize(
        selection.availability == P::Availability::Missing ? @"MISSING_HELP" :
        selection.availability == P::Availability::Unsupported ? @"UNSUPPORTED_HELP" : @"BROKEN_HELP");
    if (!initialized) detail = CydiaRuntimeProviderLocalize(@"BROKEN_HELP");
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
    if (!external()) { state.captured = true; return true; }
    if (!backend.providerReview(&state.reviewed) || !P::Encode(state.reviewed, &state.reviewBytes)) {
        if (error) *error = "provider_review_missing"; return false;
    }
    state.deltas = backend.autoInstalledDeltas();
    state.context->archives = P::ArchiveEvidenceSnapshot::Capture(*ActiveRuntimeDescriptor(), state.reviewed,
        state.selected.executableSearchPath, {}, error);
    state.captured = state.context->archives != nullptr;
    return state.captured;
}
bool RuntimeProviderCoordinator::ApproveReview(AptBackend &backend, const std::set<std::uint64_t> &shownActions,
    const std::set<std::string> &shownWarnings, std::string *error) {
    auto &state(*implementation_);
    if (!state.captured || state.approved || !ReviewUnchanged(backend)) {
        if (error) *error = "provider_review_changed"; return false;
    }
    if (external() && !state.context->broker->Approve(state.reviewed, state.deltas, shownActions, shownWarnings)) {
        if (error) *error = state.context->broker->errorCode(); return false;
    }
    state.approved = true; return true;
}
bool RuntimeProviderCoordinator::ReviewUnchanged(const AptBackend &backend) const {
    const auto &state(*implementation_);
    if (!state.captured) return false;
    if (!external()) return true;
    P::ReviewedTransaction current; std::string bytes;
    return healthy() && backend.providerReview(&current) && P::Encode(current, &bytes) && bytes == state.reviewBytes;
}
void RuntimeProviderCoordinator::InvalidateReview() { implementation_->ClearReview(); }
bool RuntimeProviderCoordinator::executionComplete() const {
    return !external() || (implementation_->approved && implementation_->context->broker->complete());
}
const Provider::ReviewedTransaction *RuntimeProviderCoordinator::review() const {
    return external() && implementation_->captured ? &implementation_->reviewed : nullptr;
}
}
