/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderSession.hpp"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <poll.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

#if !defined(CYDIA_PROVIDER_SESSION_TESTING) || !CYDIA_PROVIDER_SESSION_TESTING
#error Compile this focused test with CYDIA_PROVIDER_SESSION_TESTING=1
#endif

namespace {
namespace P = CydiaAPT::Provider;
using Clock = std::chrono::steady_clock;

void Require(bool condition, const char *message) {
    if (condition) return;
    std::fprintf(stderr, "[apt-provider-session] %s\n", message);
    std::exit(1);
}

P::Info Provider() {
    P::Info info;
    info.availability = P::Availability::Ready;
    info.capabilities = P::RequiredCapabilities;
    info.identifier = "fixture-provider"; info.implementationVersion = "1";
    info.libraryIdentity = "fixture-library"; info.frontendIdentity = "fixture-frontend";
    auto &environment(info.environment);
    environment.paths.dpkg = "/distribution/bin/dpkg";
    environment.paths.dpkgQuery = "/distribution/bin/dpkg-query";
    environment.paths.dpkgDeb = "/distribution/bin/dpkg-deb";
    environment.paths.dpkgRoot = "/distribution";
    environment.paths.dpkgAdmin = "/distribution/state/dpkg";
    environment.paths.sourceList = "/distribution/etc/apt/sources.list";
    environment.paths.sourceParts = "/distribution/etc/apt/sources.list.d";
    environment.configurationIdentity = "configuration-v1";
    environment.policyIdentity = "policy-v1"; environment.methodsIdentity = "methods-v1";
    environment.packageStateIdentity = "state-v1";
    environment.nativeArchitecture = "native";
    environment.registeredArchitectures = {"native", "foreign"};
    environment.acquisitionArchitectures = environment.registeredArchitectures;
    return info;
}

bool Bytes(int descriptor, char *bytes, size_t length) {
    size_t offset(0);
    const auto deadline(Clock::now() + std::chrono::seconds(5));
    while (offset != length) {
        if (Clock::now() >= deadline) return false;
        struct pollfd waiting = {descriptor, POLLIN, 0};
        if (poll(&waiting, 1, 25) <= 0) continue;
        const ssize_t count(recv(descriptor, bytes + offset, length - offset, 0));
        if (count <= 0) return false;
        offset += count;
    }
    return true;
}

bool Receive(int descriptor, P::Message *message) {
    std::string bytes(8, '\0');
    if (!Bytes(descriptor, &bytes[0], bytes.size())) return false;
    std::uint32_t size(0);
    for (unsigned i(4); i != 8; ++i) size = (size << 8) | static_cast<unsigned char>(bytes[i]);
    if (size > P::MaximumMessageBytes - 8) return false;
    bytes.resize(8 + size);
    return Bytes(descriptor, &bytes[8], size) && P::DecodeFrame(bytes, message);
}

bool Send(int descriptor, const P::Message &message) {
    std::string bytes;
    if (!P::EncodeFrame(message, &bytes)) return false;
    size_t offset(0);
    while (offset != bytes.size()) {
        int flags(0);
#ifdef MSG_NOSIGNAL
        flags |= MSG_NOSIGNAL;
#endif
        const ssize_t count(send(descriptor, bytes.data() + offset, bytes.size() - offset, flags));
        if (count <= 0) return false;
        offset += count;
    }
    return true;
}

P::Message Reply(const P::Message &request) {
    P::Message reply(request);
    reply.kind = request.kind == P::MessageKind::ParentRequest ? P::MessageKind::ParentResponse : P::MessageKind::Response;
    reply.succeeded = true; reply.payload.clear();
    return reply;
}

enum class Mode {
    Normal, Malformed, ChangedBinding, Cancel, IgnoreCancel, ChangedState, ApprovedState,
    LostExecution, CompletedExecution, FailedExecution, MultipleBatches, FalseStarted, BlockedWrite
};

struct Peer {
    int client = -1, server = -1;
    Mode mode;
    std::thread thread;
    std::atomic<bool> denied{false};
    std::atomic<bool> stopping{false};
    explicit Peer(Mode selected) : mode(selected) {
        int sockets[2]; Require(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "fixture channel creation");
        client = sockets[0]; server = sockets[1];
        if (mode == Mode::BlockedWrite) {
            int smallBuffer(4096);
            Require(setsockopt(client, SOL_SOCKET, SO_SNDBUF, &smallBuffer, sizeof(smallBuffer)) == 0,
                "fixture bounded send buffer");
        }
#ifdef SO_NOSIGPIPE
        int one(1); setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        thread = std::thread([this]() { Run(); });
    }
    ~Peer() {
        stopping = true;
        shutdown(server, SHUT_RDWR);
        if (client >= 0) close(client);
        thread.join(); close(server);
    }
    int TakeClient() { const int value(client); client = -1; return value; }

    bool Reverse(const P::Message &active, P::Operation operation, std::uint64_t sequence,
                 const std::string &payload, P::Message *response) {
        P::Message request;
        request.kind = P::MessageKind::ParentRequest; request.sequence = sequence;
        request.operation = operation; request.binding = active.binding; request.payload = payload;
        return Send(server, request) && Receive(server, response) && P::ValidateReply(request, *response);
    }

    void Run() {
        P::Message hello;
        if (!Receive(server, &hello)) return;
        if (mode == Mode::Malformed) {
            const char malformed[] = "NOPE\0\0\0\1x";
            (void) send(server, malformed, sizeof(malformed) - 1, 0); return;
        }
        P::Hello decoded;
        if (!P::Decode(hello.payload, &decoded) || !P::ValidHello(decoded)) return;
        P::Message greeting(Reply(hello));
        const P::Info info(Provider());
        if (!P::Encode(info, &greeting.payload) || !Send(server, greeting)) return;
        std::uint64_t parentSequence(0);
        bool managerReturned(false);
        for (;;) {
            P::Message request;
            if (!Receive(server, &request)) return;
            P::Message response(Reply(request));
            switch (request.operation) {
                case P::Operation::Reset: case P::Operation::OpenCache: {
                    P::CacheReply cache; cache.opened = true; cache.binding = request.binding;
                    ++cache.binding.cacheEpoch; cache.binding.selectionRevision = 0; cache.binding.review.clear();
                    if (request.operation == P::Operation::OpenCache && mode == Mode::ApprovedState) {
                        P::Message state;
                        if (!Reverse(request, P::Operation::CaptureStateSnapshot, ++parentSequence, "", &state) || !state.succeeded) return;
                        P::Environment environment;
                        if (!P::Decode(state.payload, &environment)) return;
                        cache.binding.packageStateIdentity = environment.packageStateIdentity;
                    } else if (request.operation == P::Operation::OpenCache && mode == Mode::ChangedState) {
                        cache.binding.packageStateIdentity = "unapproved-state";
                    }
                    if (!P::Encode(cache, &response.payload)) return;
                    break;
                }
                case P::Operation::CacheState: {
                    if (managerReturned) { shutdown(server, SHUT_RDWR); return; }
                    CydiaAPT::CacheStateSummary cache; cache.installs = 3;
                    if (!P::Encode(cache, &response.payload)) return;
                    if (mode == Mode::ChangedBinding) response.binding.policyIdentity = "unexpected-policy";
                    break;
                }
                case P::Operation::InstallPackage:
                    if (!P::Encode(true, &response.payload)) return;
                    break;
                case P::Operation::TransactionData: {
                    P::ReviewedTransaction review; review.binding = request.binding; review.binding.review = "review-v1";
                    if (!P::Encode(review, &response.payload)) return;
                    break;
                }
                case P::Operation::LockForTransaction: {
                    P::Message lock;
                    if (!Reverse(request, P::Operation::AcquireFrontendLock, ++parentSequence, "", &lock)) return;
                    denied = !lock.succeeded;
                    if (!P::Encode(lock.succeeded, &response.payload)) return;
                    break;
                }
                case P::Operation::RunPackageManager: {
                    P::ParentExecutionRequest execution; execution.binding = request.binding;
                    execution.arguments = {"--configure", "fixture-package"};
                    std::string payload; P::Message executed;
                    if (!P::Encode(execution, &payload) ||
                        !Reverse(request, P::Operation::ExecuteDpkg, ++parentSequence, payload, &executed)) return;
                    if (mode == Mode::LostExecution) { shutdown(server, SHUT_RDWR); return; }
                    if (mode == Mode::MultipleBatches &&
                        !Reverse(request, P::Operation::ExecuteDpkg, ++parentSequence, payload, &executed)) return;
                    P::PackageManagerReply manager;
                    manager.result = mode == Mode::FailedExecution ? CydiaAPT::PackageManagerResult::Failed :
                        CydiaAPT::PackageManagerResult::Completed;
                    manager.started = mode != Mode::FalseStarted;
                    if (!P::Encode(manager, &response.payload)) return;
                    managerReturned = true;
                    break;
                }
                case P::Operation::SourceResource: {
                    if (mode != Mode::Cancel && mode != Mode::IgnoreCancel) return;
                    P::Message cancellation;
                    if (!Receive(server, &cancellation) || cancellation.operation != P::Operation::Cancel) return;
                    if (mode == Mode::IgnoreCancel) { P::Message unused; (void) Receive(server, &unused); return; }
                    std::uint64_t target(0);
                    if (!P::Decode(cancellation.payload, &target) || target != request.sequence) return;
                    if (!Send(server, Reply(cancellation))) return;
                    response.succeeded = false; response.errorCode = "cancelled";
                    break;
                }
                default: return;
            }
            if (!Send(server, response)) return;
            if (mode == Mode::BlockedWrite && request.operation == P::Operation::Reset) {
                // Leave a full request blocked in the sender until it observes
                // cancellation. The destructor stops this read-free fixture.
                while (!stopping) std::this_thread::sleep_for(std::chrono::milliseconds(5));
                return;
            }
        }
    }
};

void Start(P::Session *session, Peer *peer, const P::SessionCallbacks &callbacks = P::SessionCallbacks()) {
    P::Info provider(Provider()); P::Hello hello; hello.expected = provider.environment;
    hello.options.repositorySecurityMode = CydiaAPT::RepositorySecurityMode::Distribution;
    Require(session->StartConnected(peer->TakeClient(), provider, hello, callbacks, 1000), "normal session handshake");
    Require(P::ValidChallenge(session->binding().session), "session generates a bounded fresh challenge");
    P::Message reply;
    Require(session->Call(P::Operation::Reset, "", &reply) && reply.succeeded && session->binding().cacheEpoch == 1,
        "reset establishes an initial cache epoch");
}

void NormalAndAuthority() {
    Peer peer(Mode::Normal); P::Session session; Start(&session, &peer);
    P::Message reply;
    Require(session.Call(P::Operation::CacheState, "", &reply), "ordinary response");
    CydiaAPT::CacheStateSummary cache;
    Require(P::Decode(reply.payload, &cache) && cache.installs == 3, "ordinary cache payload");
    std::string package; P::Encode(CydiaAPT::PackageHandle(1), &package);
    Require(session.Call(P::Operation::InstallPackage, package, &reply) && session.binding().selectionRevision == 1,
        "selection edits invalidate prior review and advance revision");
    Require(session.Call(P::Operation::TransactionData, "", &reply) && session.binding().review == "review-v1",
        "review remains bound to the selected cache and revision");
    Require(!session.Call(P::Operation::PrepareArchives, "", &reply) && session.active(),
        "reviewed work cannot run before parent lock ownership");
    Require(session.Call(P::Operation::LockForTransaction, "", &reply) && peer.denied && !session.parentLockHeld(),
        "missing parent executor callbacks never grant privileged operation authority");
}

void InvalidFramesAndState() {
    {
        Peer peer(Mode::Malformed); P::Session session; P::Hello hello; hello.expected = Provider().environment;
        hello.options.repositorySecurityMode = CydiaAPT::RepositorySecurityMode::Distribution;
        Require(!session.StartConnected(peer.TakeClient(), Provider(), hello) && !session.active(),
            "malformed handshake disconnects");
    }
    {
        Peer peer(Mode::ChangedBinding); P::Session session; Start(&session, &peer); P::Message reply;
        Require(!session.Call(P::Operation::CacheState, "", &reply) && !session.active() && !session.indeterminate(),
            "a response cannot change the established policy binding");
    }
    {
        Peer peer(Mode::ChangedState); P::Session session; Start(&session, &peer); P::Message reply;
        Require(!session.Call(P::Operation::OpenCache, "", &reply) && !session.active(),
            "a worker cannot approve its own changed package-state identity");
    }
    {
        Peer peer(Mode::ApprovedState); P::Session session; P::SessionCallbacks callbacks;
        callbacks.parentRequest = [](const P::Message &request, P::Message *reply, const P::RequestControl &) {
            if (request.operation != P::Operation::CaptureStateSnapshot) return;
            P::Environment environment(Provider().environment); environment.packageStateIdentity = "verified-state-v2";
            reply->succeeded = P::Encode(environment, &reply->payload);
        };
        Start(&session, &peer, callbacks); P::Message reply;
        Require(session.Call(P::Operation::OpenCache, "", &reply) && session.binding().cacheEpoch == 2 &&
            session.binding().packageStateIdentity == "verified-state-v2", "only a parent-verified state transition is accepted");
    }
}

void Cancellation() {
    {
        Peer peer(Mode::Cancel); P::Session session; Start(&session, &peer); P::Message reply;
        const auto start(Clock::now());
        Require(!session.Call(P::Operation::SourceResource, "", &reply, 1000, [&]() {
            return Clock::now() - start >= std::chrono::milliseconds(20);
        }) && session.active() && session.lastError() == "provider_cancelled", "cooperative cancellation settles on the same worker");
        Require(session.Call(P::Operation::CacheState, "", &reply), "cancellation drained both responses before another request");
    }
    {
        Peer peer(Mode::IgnoreCancel); P::Session session; Start(&session, &peer); P::Message reply;
        const auto start(Clock::now());
        Require(!session.Call(P::Operation::SourceResource, "", &reply, 30) && !session.active() &&
            session.lastError() == "provider_cancellation_unsettled", "unsettled cancellation disconnects after its finite grace period");
        Require(Clock::now() - start < std::chrono::seconds(4), "timeout remains bounded");
    }
    {
        Peer peer(Mode::BlockedWrite); P::Session session; Start(&session, &peer); P::Message reply;
        const std::string largePayload(4u * 1024u * 1024u, 'x');
        const auto start(Clock::now());
        unsigned checks(0);
        Require(!session.Call(P::Operation::SourceResource, largePayload, &reply, 60000, [&]() {
            // Allow the first write even when frame serialization takes time.
            return ++checks > 2 && Clock::now() - start >= std::chrono::milliseconds(20);
        }) && !session.active() && !session.indeterminate() && session.lastError() == "provider_cancelled",
            "a partially written request observes cancellation without interleaving frames");
        Require(Clock::now() - start < std::chrono::seconds(2), "blocked writes observe cancellation promptly");
    }
}

void SettledMutation() {
    for (Mode mode : {Mode::CompletedExecution, Mode::FailedExecution, Mode::MultipleBatches, Mode::FalseStarted}) {
        Peer peer(mode); P::Session session; P::SessionCallbacks callbacks;
        unsigned executions(0);
        callbacks.parentRequest = [&](const P::Message &request, P::Message *reply, const P::RequestControl &) {
            if (request.operation == P::Operation::AcquireFrontendLock) { reply->succeeded = true; return; }
            if (request.operation == P::Operation::ExecuteDpkg) {
                P::ParentExecutionReply executed;
                // A later batch that fails to launch must not erase an earlier
                // batch's started state in the same manager operation.
                executed.started = ++executions == 1; executed.exitCode = executed.started ? 0 : -1;
                reply->succeeded = P::Encode(executed, &reply->payload);
            }
        };
        Start(&session, &peer, callbacks); P::Message reply;
        Require(session.Call(P::Operation::TransactionData, "", &reply) &&
            session.Call(P::Operation::LockForTransaction, "", &reply), "settlement fixture review and parent lock");
        if (mode == Mode::FalseStarted) {
            Require(!session.Call(P::Operation::RunPackageManager, "", &reply) && session.indeterminate() &&
                session.lastError() == "provider_invalid_execution_reply", "a worker cannot deny an observed executor start");
        } else {
            Require(session.Call(P::Operation::RunPackageManager, "", &reply) && reply.succeeded &&
                session.mutationStarted() && session.lastCallExecutionStarted() && !session.indeterminate(),
                "typed terminal manager reply settles effects while preserving this call's observed start");
            Require(!session.Call(P::Operation::CacheState, "", &reply) && !session.active() && !session.indeterminate(),
                "a later read disconnect cannot make a settled transaction indeterminate");
            Require(!session.lastCallExecutionStarted(), "a later read does not inherit a prior executor start");
            if (mode == Mode::MultipleBatches) Require(executions == 2, "all executor batches were observed");
        }
    }
}

void LostMutation() {
    Peer peer(Mode::LostExecution); P::Session session; P::SessionCallbacks callbacks;
    callbacks.parentRequest = [](const P::Message &request, P::Message *reply, const P::RequestControl &) {
        if (request.operation == P::Operation::AcquireFrontendLock) { reply->succeeded = true; return; }
        if (request.operation == P::Operation::ExecuteDpkg) {
            // Fixture only: records that an executor started; no process runs.
            P::ParentExecutionReply executed; executed.started = true; executed.exitCode = 0;
            reply->succeeded = P::Encode(executed, &reply->payload);
        }
    };
    Start(&session, &peer, callbacks); P::Message reply;
    Require(session.Call(P::Operation::TransactionData, "", &reply) &&
        session.Call(P::Operation::LockForTransaction, "", &reply), "mutation fixture review and parent lock");
    Require(!session.Call(P::Operation::RunPackageManager, "", &reply) && session.indeterminate() && session.mutationStarted(),
        "lost reply after execution is indeterminate, not a retry or fallback");
}
} // namespace

int main() {
    NormalAndAuthority(); InvalidFramesAndState(); Cancellation(); LostMutation(); SettledMutation();
    std::puts("[apt-provider-session] handshake, binding, authority, cancellation and indeterminate outcomes passed");
}
