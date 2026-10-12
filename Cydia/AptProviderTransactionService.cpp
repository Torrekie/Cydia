/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionService.hpp"
#include "Cydia/RuntimeState.hpp"
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <fcntl.h>
#include <limits>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
#if defined(CYDIA_TRANSACTION_SERVICE_TESTING)
// The host fixture supplies only its disposable private staging directory.
// Production always derives this path from the installed Cydia package.
std::string TransactionServiceTestingStateDirectory();
#endif
namespace {
namespace P = CydiaRuntime::Privileged;
namespace TC = TransactionChannel;
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Same(const Binding &left, const Binding &right) {
    std::string a, b; return Encode(left, &a) && Encode(right, &b) && a == b;
}
bool Nonce(std::string *result) {
    unsigned char bytes[32];
#ifdef __APPLE__
    arc4random_buf(bytes, sizeof(bytes));
#else
    const int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    std::size_t offset = 0;
    while (offset < sizeof(bytes)) {
        const auto count = read(fd, bytes + offset, sizeof(bytes) - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return false; }
        offset += count;
    }
    close(fd);
#endif
    result->clear(); const char hex[] = "0123456789abcdef";
    for (const auto byte : bytes) { *result += hex[byte >> 4]; *result += hex[byte & 15]; }
    return true;
}
bool Authenticated(const TransactionServiceOptions &options, std::string *error) {
    P::ApplicationProcessIdentity application; uid_t uid = 0;
    return options.authenticate && options.authenticate(&application, &uid, error) &&
        P::ValidApplicationProcessIdentity(application) && application == options.application &&
        uid == options.applicationUID && application.pid == std::to_string(getppid()) ? true :
        Fail(error, "provider_lease_authority_changed");
}
bool Policy(const CydiaRuntime::PackageDatabasePaths &paths, const TransactionBeginRequest &begin,
    const P::Request &request, BrokerEnvironment *selected, TransactionOwnerOptions *owner, std::string *error) {
    if (!BindResolvedBrokerRuntime(request, selected)) return Fail(error, "provider_authority_changed");
    auto &runtime = selected->runtime; auto &policy = owner->policy; P::Error failure;
    if (!P::RuntimeSnapshot(selected->environment, &runtime.binding.packageStateIdentity, &failure))
        return Fail(error, "provider_dpkg_state_unavailable");
    const auto &binding = begin.review.binding;
    if (binding.providerIdentifier != runtime.binding.providerIdentifier || binding.configurationIdentity != runtime.binding.configurationIdentity ||
        binding.policyIdentity != runtime.binding.policyIdentity || binding.packageStateIdentity != runtime.binding.packageStateIdentity)
        return Fail(error, "provider_lease_state_changed");
    runtime.binding.session = binding.session;
    policy.environment.paths = selected->environment;
    policy.environment.configurationIdentity = runtime.binding.configurationIdentity;
    policy.environment.policyIdentity = runtime.binding.policyIdentity; policy.environment.methodsIdentity = runtime.binding.methodsIdentity;
    policy.environment.packageStateIdentity = runtime.binding.packageStateIdentity;
    policy.environment.nativeArchitecture = runtime.architecture;
    policy.environment.registeredArchitectures = runtime.registeredArchitectures;
    policy.environment.acquisitionArchitectures = runtime.acquisitionArchitectures;
    policy.protectedDpkgOptions = runtime.dpkgOptions; policy.layout.prefix = runtime.packageInstallPrefix;
    if (policy.layout.prefix == "/") policy.layout.foreignPrefixes.push_back("/var/jb");
    policy.additionalActionsReviewed = begin.additionalActions; policy.unverifiedArchiveWarningsAccepted = begin.archiveWarnings;
    const int descriptor = P::OpenFrontendLock(selected->environment.dpkgAdmin, "lock-frontend", &failure);
    if (descriptor < 0) return Fail(error, "provider_frontend_lock_required");
    struct stat identity; struct flock lock = {}; lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
    const bool valid = !fstat(descriptor, &identity) && S_ISREG(identity.st_mode) && identity.st_nlink == 1 &&
        !fcntl(descriptor, F_GETLK, &lock) && lock.l_type == F_WRLCK && lock.l_pid == getppid();
    close(descriptor);
    if (!valid) return Fail(error, "provider_frontend_lock_required");
    owner->lock.device = identity.st_dev; owner->lock.inode = identity.st_ino;
    owner->privateStateDirectory = paths.CydiaStateDirectory(); owner->selected = *selected;
#if defined(CYDIA_TRANSACTION_SERVICE_TESTING)
    owner->privateStateDirectory = TransactionServiceTestingStateDirectory();
#endif
    owner->review = begin.review; owner->changes = begin.changes; owner->expectedExtendedState = begin.extendedState;
    return true;
}
struct Descriptors {
    std::vector<int> values;
    ~Descriptors() { for (int fd : values) close(fd); }
};
struct ChildScope {
    TC::Frame frame;
    Descriptors descriptors;
    bool started = false, settled = false;
};
}
bool ServeProviderTransaction(int socket, const CydiaRuntime::PackageDatabasePaths &paths,
    const TransactionServiceOptions &options, std::string *error) {
    if (error) error->clear();
    TC::Channel channel(socket);
    const unsigned timeout = options.nonmutatingMilliseconds ? std::min(options.nonmutatingMilliseconds, 60000u) : 30000u;
    const auto peerClosed = [&]() {
        char byte; const auto count = recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
        return count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK);
    };
    TC::Frame request; Descriptors descriptors;
    if (!channel.valid() || !channel.Receive(&request, &descriptors.values, timeout)) return Fail(error, "provider_transaction_closed");
    const auto sendFailure = [&](const std::string &code) {
        TC::Frame reply = request; reply.event = TC::Event::Settled; reply.payload.clear(); reply.success = false;
        reply.errorCode = code.empty() ? "provider_transaction_unavailable" : code;
        if (error) *error = reply.errorCode;
        channel.Send(reply, {}, timeout); return false;
    };
    if (request.event != TC::Event::Request || request.operation != TC::Operation::Begin || !descriptors.values.empty())
        return sendFailure("provider_transaction_binding_invalid");
    std::string failure, payload; P::Request wrapped; P::Error privilegedError;
    TransactionBeginRequest begin; BrokerEnvironment selected; TransactionOwnerOptions ownerOptions;
    if (!Authenticated(options, &failure)) return sendFailure(failure);
    if (!P::ParseRequest(request.payload, &wrapped, &privilegedError) ||
        !ResolveBrokerRequest(paths, wrapped, options.applicationUID, &selected, &payload, &privilegedError))
        return sendFailure(privilegedError.code.empty() ? "provider_authority_changed" : privilegedError.code);
    if (!DecodeTransactionBegin(payload, &begin) || TransactionBeginDigest(begin) != request.reviewDigest ||
        request.scopedChildren != static_cast<bool>(begin.reviewedEffects))
        return sendFailure("provider_transaction_review_mismatch");
    if (!options.prepareEnvironment || !options.prepareEnvironment(&selected, &failure) || !options.execute)
        return sendFailure(failure.empty() ? "provider_transaction_unavailable" : failure);
    if (!Policy(paths, begin, wrapped, &selected, &ownerOptions, &failure) || !Nonce(&ownerOptions.nonce))
        return sendFailure(failure.empty() ? "provider_transaction_nonce_failed" : failure);
    ownerOptions.application = options.application; ownerOptions.applicationUID = options.applicationUID;
    ownerOptions.authenticate = options.authenticate; ownerOptions.execute = options.execute; ownerOptions.reviewDigest = request.reviewDigest;
    const bool scoped = request.scopedChildren;
    ownerOptions.reviewedEffects = begin.reviewedEffects;
    TransactionOwner *activeOwner = nullptr;
    std::uint64_t childOrdinal = 0;
    bool scopeActive = false, scopeCancelled = false, mutationInRequest = false;
    const auto childChannels = [&](const TC::ChildDescriptor &description, TransactionEffectChildChannels *channels, std::string *reason) {
        if (!activeOwner || !channels || scopeActive || scopeCancelled || childOrdinal == UINT64_MAX)
            return Fail(reason, "provider_transaction_child_invalid");
        auto scope = std::make_shared<ChildScope>(); scope->frame = request;
        scope->frame.payload.clear(); scope->frame.event = TC::Event::ChildNeeded;
        scope->frame.childOrdinal = ++childOrdinal;
        if (!TC::EncodeChildDescriptor(description, &scope->frame.childDescriptor) || !channel.Send(scope->frame, {}, timeout)) {
            activeOwner->TransportLost(); return Fail(reason, "provider_transaction_closed");
        }
        TC::Frame response;
        if (!channel.Receive(&response, &scope->descriptors.values, timeout) || !Authenticated(options, reason) ||
            response.operation != request.operation || response.sequence != request.sequence || response.nonce != request.nonce ||
            response.reviewDigest != request.reviewDigest || !response.scopedChildren ||
            response.childOrdinal != scope->frame.childOrdinal || response.childDescriptor != scope->frame.childDescriptor) {
            activeOwner->TransportLost(); return Fail(reason, "provider_transaction_child_invalid");
        }
        if (response.event == TC::Event::ChildDenied) {
            scopeCancelled = true; activeOwner->Cancel(); return Fail(reason, response.errorCode.c_str());
        }
        if (response.event != TC::Event::ChildChannels || scope->descriptors.values.size() != 2 ||
            !TC::ValidChildDescriptors(scope->descriptors.values[0], scope->descriptors.values[1])) {
            activeOwner->TransportLost(); return Fail(reason, "provider_transaction_child_invalid");
        }
        scopeActive = true;
        channels->inputDescriptor = scope->descriptors.values[0]; channels->statusDescriptor = scope->descriptors.values[1];
        channels->started = [&, scope] {
            if (scope->started || scope->settled) { activeOwner->TransportLost(); return; }
            scope->started = mutationInRequest = true;
            auto event = scope->frame; event.event = TC::Event::ChildStarted; event.success = event.mutationStarted = true;
            if (!channel.Send(event, {}, timeout)) activeOwner->TransportLost();
        };
        channels->settled = [&, scope](const ParentExecutionReply &result) {
            if (scope->settled || result.started != scope->started) { activeOwner->TransportLost(); return; }
            scope->settled = true;
            for (int fd : scope->descriptors.values) close(fd);
            scope->descriptors.values.clear();
            auto event = scope->frame; event.event = TC::Event::ChildSettled; event.success = true; event.mutationStarted = result.started;
            TC::Frame response; Descriptors received;
            if (!Encode(result, &event.payload) || !channel.Send(event, {}, timeout) ||
                !channel.Receive(&response, &received.values, timeout) || !received.values.empty() || !Authenticated(options, nullptr) ||
                response.operation != event.operation || response.sequence != event.sequence || response.nonce != event.nonce ||
                response.reviewDigest != event.reviewDigest || !response.scopedChildren || response.childOrdinal != event.childOrdinal ||
                response.childDescriptor != event.childDescriptor || response.mutationStarted != event.mutationStarted ||
                (response.event != TC::Event::ChildReleased && response.event != TC::Event::ChildCancelled)) {
                activeOwner->TransportLost(); return;
            }
            scopeActive = false;
            if (response.event == TC::Event::ChildCancelled) { scopeCancelled = true; activeOwner->Cancel(); }
        };
        return true;
    };
    if (scoped) {
        ownerOptions.primaryChildChannels = [&](const ParentExecutionRequest &execution, TransactionEffectChildChannels *channels, std::string *reason) {
            TC::ChildDescriptor descriptor; descriptor.primaryBatch = execution.batch;
            descriptor.primaryAction = static_cast<unsigned>(execution.action); descriptor.primaryActions = execution.actions;
            return childChannels(descriptor, channels, reason);
        };
        ownerOptions.effectChildChannels = [&](const TriggerDrainPlan &plan, TransactionEffectChildChannels *channels, std::string *reason) {
            TC::ChildDescriptor descriptor; descriptor.purpose = TC::ChildPurpose::TriggerDrain;
            descriptor.envelopeIdentity = plan.envelopeIdentity; descriptor.checkpointIdentity = plan.checkpointIdentity;
            descriptor.pass = plan.pass; descriptor.primaryCheckpoint = plan.primaryCheckpoint; descriptor.incorporateDeferred = plan.incorporateDeferred;
            for (const auto &package : plan.targets) descriptor.targets.push_back({package.package, package.version, package.architecture});
            return childChannels(descriptor, channels, reason);
        };
    }
    TransactionOwner owner(ownerOptions);
    activeOwner = &owner;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
    const auto cancelled = [&]() { return scopeCancelled || peerClosed() || (!mutationInRequest && std::chrono::steady_clock::now() >= deadline); };
    if (!owner.Begin(&failure, cancelled)) return sendFailure(failure);
    TC::Frame reply = request; reply.event = TC::Event::Settled; reply.success = true; reply.payload.clear(); reply.nonce = ownerOptions.nonce;
    if (!channel.Send(reply, {}, timeout)) { owner.TransportLost(); return Fail(error, channel.error().c_str()); }
    std::uint64_t sequence = 0;
    for (;;) {
        request = TC::Frame();
        if (!channel.Receive(&request, &descriptors.values, timeout)) {
            owner.TransportLost(); return Fail(error, channel.error().c_str());
        }
        const bool bound = request.event == TC::Event::Request && request.operation != TC::Operation::Begin &&
            sequence != std::numeric_limits<std::uint64_t>::max() && request.sequence == sequence + 1 &&
            request.nonce == ownerOptions.nonce && request.reviewDigest == ownerOptions.reviewDigest && request.scopedChildren == scoped;
        if (!bound || !Authenticated(options, &failure)) {
            owner.Cancel(); return sendFailure(bound ? failure : "provider_transaction_binding_invalid");
        }
        ++sequence; reply = request; reply.event = TC::Event::Settled; reply.payload.clear();
        deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
        mutationInRequest = false;
        TransactionLeaseEnvelope envelope; envelope.nonce = request.nonce; envelope.reviewDigest = request.reviewDigest; envelope.sequence = sequence;
        bool started = false;
        const auto notifyStarted = [&]() {
            if (started) return; started = true;
            mutationInRequest = true;
            if (scoped && request.operation == TC::Operation::Execute) return;
            TC::Frame event = reply; event.event = TC::Event::Started; event.success = true; event.mutationStarted = true;
            if (!channel.Send(event, {}, timeout)) owner.TransportLost();
        };
        failure.clear(); bool success = false;
        if (request.operation == TC::Operation::Capture && request.payload.empty()) {
            DpkgState state; success = owner.Capture(envelope, &state, &failure, cancelled) && EncodeBrokerState(state, &reply.payload);
        } else if (request.operation == TC::Operation::Execute) {
            ParentExecutionRequest execution; TransactionExecutionReply outcome;
            if (((scoped && descriptors.values.empty()) || (!scoped && descriptors.values.size() == 2 && descriptors.values[1] >= 3)) && Decode(request.payload, &execution)) {
                success = owner.Execute(envelope, execution, scoped ? -1 : descriptors.values[0], scoped ? -1 : descriptors.values[1],
                    &outcome.result, &outcome.state, &failure, cancelled, notifyStarted);
                if (success && !EncodeTransactionExecutionReply(outcome, &reply.payload)) {
                    success = false; failure = "provider_transaction_result_invalid";
                }
            }
        } else if (request.operation == TC::Operation::Commit) {
            std::vector<std::string> fields; ExtendedStateRequest commit;
            if (P::ParseFields(request.payload, 2, &fields, &privilegedError) && Decode(fields[1], &commit) &&
                Same(commit.binding, ownerOptions.review.binding))
                success = owner.Commit(envelope, commit.changes, fields[0], &failure, notifyStarted);
        } else if (request.operation == TC::Operation::Close && request.payload.empty()) success = owner.Close(&failure);
        // Execute is synchronous: all passed descriptors can be closed only
        // after its actual child and owner-side state verification settle.
        for (const int fd : descriptors.values) close(fd);
        descriptors.values.clear();
        reply.success = success; reply.mutationStarted = started || mutationInRequest; reply.indeterminate = owner.indeterminate();
        if (!success) { reply.payload.clear(); reply.errorCode = failure.empty() ? "provider_transaction_request_invalid" : failure; }
        if (!channel.Send(reply, {}, timeout)) { owner.TransportLost(); return Fail(error, channel.error().c_str()); }
        if (!success) { owner.Cancel(); return Fail(error, reply.errorCode.c_str()); }
        if (request.operation == TC::Operation::Close) return true;
    }
}
}}
