/* Real Session/server socket tests with only injected package values.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderServerTransport.hpp"
#include "Cydia/AptProviderSession.hpp"
#include "Cydia/AptBackendImplementation.hpp"
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <poll.h>
#include <stdexcept>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

#if !defined(CYDIA_PROVIDER_SESSION_TESTING) || !CYDIA_PROVIDER_SESSION_TESTING
#error Compile this test with CYDIA_PROVIDER_SESSION_TESTING=1
#endif

namespace {
namespace A = CydiaAPT;
namespace P = A::Provider;
void Require(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "[apt-provider-transport] " << message << '\n'; std::exit(1);
}
template<class T> std::string Encode(const T &value) {
    std::string bytes; Require(P::Encode(value, &bytes), "fixture value encoding"); return bytes;
}
template<class T> T Decode(const P::Message &value) {
    T result; Require(P::Decode(value.payload, &result), "typed response decoding"); return result;
}
std::string Frame(const P::Message &value) {
    std::string bytes; Require(P::EncodeFrame(value, &bytes), "fixture frame encoding"); return bytes;
}
P::Message Message(const std::string &bytes) {
    P::Message result; Require(P::DecodeFrame(bytes, &result), "response frame decoding"); return result;
}
P::Info Info() {
    P::Info info; info.availability = P::Availability::Ready; info.capabilities = P::RequiredCapabilities;
    info.identifier = "fixture-provider"; info.implementationVersion = "1";
    info.libraryIdentity = "fixture-library"; info.frontendIdentity = "fixture-frontend";
    auto &environment(info.environment);
    environment.paths.dpkg = "/distribution/bin/dpkg";
    environment.paths.dpkgQuery = "/distribution/bin/dpkg-query";
    environment.paths.dpkgDeb = "/distribution/bin/dpkg-deb";
    environment.paths.dpkgRoot = "/distribution"; environment.paths.dpkgAdmin = "/distribution/state/dpkg";
    environment.paths.sourceList = "/distribution/etc/apt/sources.list";
    environment.paths.sourceParts = "/distribution/etc/apt/sources.list.d";
    environment.configurationIdentity = "config-v1"; environment.policyIdentity = "policy-v1";
    environment.methodsIdentity = "methods-v1"; environment.packageStateIdentity = "state-v1";
    environment.nativeArchitecture = "native";
    environment.registeredArchitectures = environment.acquisitionArchitectures = {"native", "foreign"};
    return info;
}
class Backend : public A::Internal::BackendImplementation {
public:
    const P::ServerRequestContext *context = nullptr;
    unsigned resets = 0, installs = 0, preparations = 0, sources = 0;
    bool opened = true, throwing = false, selectionResult = true;
    std::function<void()> completed;
    void reset() override { ++resets; if (completed) completed(); }
    void createCacheViews() override {}
    std::vector<A::ErrorData> drainErrors() override { return {{"Diagnostic amont", true}}; }
    void discardErrors() override {}
    bool loadSources() override { return true; }
    bool openCache() override { return opened; }
    bool lockForTransaction() override { throw std::runtime_error("worker acquired a parent lock"); }
    void unlockForTransaction() override { throw std::runtime_error("worker released a parent lock"); }
    std::vector<A::AutoInstalledDelta> autoInstalledDeltas() override { return {}; }
    A::CacheStateSummary cacheState() override {
        if (throwing) throw std::runtime_error("must not escape or become UI text");
        A::CacheStateSummary value; value.installs = 2; return value;
    }
    bool applyStatus() override { return true; }
    bool fixBroken() override { return true; }
    bool minimizeUpgrade() override { return true; }
    bool cleanArchives() override { return true; }
    bool prepareArchives() override { ++preparations; return true; }
    A::SourceListData sourceList() override { A::SourceListData value; value.success = true; return value; }
    A::FetchResultData runFetcher(int interval) override {
        Require(interval == 10, "fetch pulse interval survives dispatch");
        A::FetchResultData value; value.completed = true; return value;
    }
    A::PackageManagerResult runPackageManager(int, A::FetchResultData *, bool *) override {
        throw std::runtime_error("worker executed dpkg directly");
    }
    A::UpdateResultData updateLists(A::AcquireStatus &, int) override {
        throw std::runtime_error("worker used an app-owned acquire status");
    }
    std::vector<A::PackageHandle> packageHandles() override { return {A::PackageHandle(7)}; }
    A::PackageLookupResult lookupPackage(const std::string &name, const std::string &arch) override {
        Require(name == "fixture" && arch == "foreign", "lookup identity survives dispatch");
        A::PackageLookupResult result; result.status = A::PackageLookupStatus::Found; result.handle = A::PackageHandle(7); return result;
    }
    A::PackageHandle packageHandle(const std::string &, const std::string &) override { return A::PackageHandle(7); }
    std::vector<A::PackageHandle> downgradeHandles(A::PackageHandle) override { return {}; }
    std::vector<A::PackageHandle> versionHandles(A::PackageHandle) override { return {A::PackageHandle(7)}; }
    A::PackageSnapshot packageSnapshot(A::PackageHandle handle) override {
        A::PackageSnapshot result; result.handle = handle; result.identifier = "fixture:foreign"; result.architecture = "foreign"; return result;
    }
    A::PackageRecordData recordData(A::PackageHandle) override { return {}; }
    A::PackageStateData packageState(A::PackageHandle) override { return {}; }
    std::vector<A::RelationData> relations(A::PackageHandle) override { return {}; }
    A::TransactionData transactionData() override { return {}; }
    bool resolveDependencies() override { return true; }
    void clearSelections() override {}
    bool prepareDistUpgrade() override { return true; }
    bool clearPackage(A::PackageHandle) override { return true; }
    bool installPackage(A::PackageHandle handle) override {
        Require(handle.value == 7, "selected package handle survives dispatch"); ++installs; return selectionResult;
    }
    bool reinstallPackage(A::PackageHandle) override { return true; }
    bool removePackage(A::PackageHandle, bool) override { return true; }
    std::vector<A::SourceHandle> sourceHandles() override { return {A::SourceHandle(9)}; }
    A::SourceSnapshot sourceSnapshot(A::SourceHandle handle) override { A::SourceSnapshot value; value.handle = handle; return value; }
    std::string sourceField(A::SourceHandle, const std::string &name) override { return name; }
    std::vector<std::uint32_t> sourceFileIDs(A::SourceHandle) override { return {23}; }
    A::SourcePreflightResult sourcePreflight(const A::SourcePreflightRequest &, const std::function<bool()> &cancelled) override {
        A::SourcePreflightResult result; result.allowed = !cancelled();
        result.status = result.allowed ? A::SourceCheckStatus::Complete : A::SourceCheckStatus::Cancelled; return result;
    }
    A::SourceResourceResult sourceResource(const A::SourceResourceRequest &request, const std::function<bool()> &cancelled) override {
        ++sources; Require(context != nullptr, "source has cooperative context");
        P::ProgressEvent event; event.type = "status"; event.current = 1; event.total = 4;
        event.sourceActivity = P::SourceActivity::Started; event.sourceURI = "https://fixture.invalid/";
        event.message = request.uri.find("wait") != std::string::npos ? "waiting" : "Téléchargement";
        Require(context->progress(event), "source progress sent before cancellation");
        A::SourceResourceResult result;
        if (request.uri.find("wait") != std::string::npos) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
            while (!cancelled() && std::chrono::steady_clock::now() < deadline)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            Require(cancelled(), "source sees cancellation over the real channel");
            result.status = A::SourceCheckStatus::Cancelled;
        } else {
            event.sourceActivity = P::SourceActivity::Finished; event.current = 4;
            Require(context->progress(event), "source completion activity sent");
            result.status = A::SourceCheckStatus::Complete; result.bytes = "metadata";
        }
        return result;
    }
};

P::ServerHooks Hooks(Backend &backend, const P::Info &info) {
    P::ServerHooks hooks;
    hooks.admit = [info](const P::Hello &, P::Info *result, std::string *) { *result = info; return true; };
    hooks.operationContext = [&backend](const P::ServerRequestContext *context) { backend.context = context; };
    hooks.buildReview = [](const A::TransactionData &, const P::Binding &, P::ExecutionManifest *manifest, std::string *) {
        P::ReviewedAction action; action.identifier = 17; action.action = P::ExecutionAction::Configure;
        action.package = {"fixture", "1", "native"}; manifest->actions = {action}; return true;
    };
    hooks.updateLists = [](int, const P::ServerRequestContext &) {
        A::UpdateResultData result; result.prepared = result.success = result.metadataComplete = true; return result;
    };
    hooks.runPackageManager = [](const P::ReviewedTransaction &review, const std::vector<A::AutoInstalledDelta> &deltas,
                                 const P::ServerRequestContext &context) {
        P::ParentExecutionRequest execution; execution.binding = review.binding; execution.batch = 1;
        execution.action = P::ExecutionAction::Configure; execution.actions = {17};
        execution.arguments = {"--configure", "fixture:native"}; P::Message response;
        P::PackageManagerReply manager;
        if (!context.parentRequest(P::Operation::ExecuteDpkg, Encode(execution), &response) || !response.succeeded) return manager;
        const auto status(Decode<P::ParentExecutionReply>(response)); manager.started = status.started;
        if (status.exitCode || status.signal || status.launchError) return manager;
        P::ExtendedStateRequest state; state.binding = review.binding; state.changes = deltas;
        if (context.parentRequest(P::Operation::CommitExtendedState, Encode(state), &response) && response.succeeded) {
            manager.result = A::PackageManagerResult::Completed; manager.archives.completed = true;
        }
        return manager;
    };
    return hooks;
}

void SocketPair(int sockets[2]) {
    Require(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "local socket pair");
#ifdef SO_NOSIGPIPE
    int one(1); setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
}
void SendBytes(int socket, const std::string &bytes) {
    std::size_t offset(0);
    while (offset != bytes.size()) {
        int flags(0);
#ifdef MSG_NOSIGNAL
        flags |= MSG_NOSIGNAL;
#endif
        const ssize_t count(send(socket, bytes.data() + offset, bytes.size() - offset, flags));
        Require(count > 0, "fixture send"); offset += count;
    }
}
void ReceiveBytes(int socket, char *bytes, std::size_t size) {
    std::size_t offset(0); const auto deadline(std::chrono::steady_clock::now() + std::chrono::seconds(5));
    while (offset != size) {
        Require(std::chrono::steady_clock::now() < deadline, "fixture receive deadline");
        struct pollfd descriptor = {socket, POLLIN, 0};
        if (poll(&descriptor, 1, 10) <= 0) continue;
        const ssize_t count(recv(socket, bytes + offset, size - offset, 0));
        Require(count > 0, "fixture channel closed unexpectedly"); offset += count;
    }
}
P::Message Receive(int socket) {
    std::string bytes(8, '\0'); ReceiveBytes(socket, &bytes[0], bytes.size());
    std::uint32_t size(0); for (unsigned i = 4; i != 8; ++i) size = (size << 8) | static_cast<unsigned char>(bytes[i]);
    Require(size && size <= P::MaximumMessageBytes - 8, "fixture reply bounded length");
    bytes.resize(8 + size); ReceiveBytes(socket, &bytes[8], size); return Message(bytes);
}
P::Hello Hello(const P::Info &info) {
    P::Hello hello; hello.expected = info.environment; hello.challenge = std::string(64, 'a');
    hello.options.repositorySecurityMode = A::RepositorySecurityMode::Distribution;
    hello.registrationPath = "/distribution/provider.plist"; return hello;
}
P::Message Greeting(const P::Info &info) {
    const auto hello(Hello(info)); P::Message request; request.sequence = 1; request.payload = Encode(hello);
    request.binding.providerIdentifier = info.identifier; request.binding.session = hello.challenge;
    request.binding.configurationIdentity = info.environment.configurationIdentity;
    request.binding.policyIdentity = info.environment.policyIdentity;
    request.binding.packageStateIdentity = info.environment.packageStateIdentity; return request;
}
struct Worker {
    Backend backend;
    P::Info info = Info();
    std::unique_ptr<P::ServerTransport> transport;
    std::unique_ptr<P::Server> server;
    int client = -1;
    P::ServerTransportResult result = P::ServerTransportResult::Failed;
    // Test-only observation after the backend has no reverse requests left,
    // then after RunOne has actually written the completed operation reply.
    std::atomic<unsigned> completion{0};
    std::thread thread;
    explicit Worker(bool observeCompletion = false) {
        int sockets[2]; SocketPair(sockets); client = sockets[0];
        transport.reset(new P::ServerTransport(sockets[1])); auto hooks(Hooks(backend, info));
        if (observeCompletion) {
            backend.completed = [this]() { completion.store(1); };
            const auto manager(hooks.runPackageManager);
            hooks.runPackageManager = [this, manager](const P::ReviewedTransaction &review,
                const std::vector<A::AutoInstalledDelta> &deltas, const P::ServerRequestContext &context) {
                const auto reply(manager(review, deltas, context)); completion.store(1); return reply;
            };
        }
        Require(transport->Attach(&hooks), "attach socket hooks"); server.reset(new P::Server(backend, hooks));
        thread = std::thread([this, observeCompletion]() {
            if (!observeCompletion) { result = transport->Serve(*server, 5000); return; }
            for (;;) {
                result = transport->RunOne(*server, 5000);
                if (completion.load() == 1) completion.store(2);
                if (result != P::ServerTransportResult::Dispatched) return;
                if (server->closed()) { result = P::ServerTransportResult::Stopped; return; }
            }
        });
    }
    ~Worker() {
        if (client >= 0) close(client);
        if (thread.joinable()) thread.join();
    }
    int TakeClient() { const int socket(client); client = -1; return socket; }
    void Finish() { if (client >= 0) { close(client); client = -1; } if (thread.joinable()) thread.join(); }
    bool CancelAfterResponse() {
        if (!completion.load()) return false;
        const auto deadline(std::chrono::steady_clock::now() + std::chrono::seconds(3));
        while (completion.load() != 2) {
            Require(std::chrono::steady_clock::now() < deadline, "completed operation response was not written");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return true;
    }
};
P::Message Call(P::Session &session, P::Operation operation, const std::string &payload = "") {
    P::Message response;
    Require(session.Call(operation, payload, &response, 2000) && response.succeeded, "real client call completed"); return response;
}
void EndToEnd() {
    Worker worker; P::Session session;
    bool locked(false), waiting(false), uncertain(false); unsigned snapshots(0), executions(0), commits(0);
    std::vector<P::ProgressEvent> progress;
    P::SessionCallbacks callbacks;
    callbacks.progress = [&](const P::ProgressEvent &event) { progress.push_back(event); if (event.message == "waiting") waiting = true; };
    callbacks.closed = [&](bool indeterminate) { uncertain = indeterminate; };
    callbacks.parentRequest = [&](const P::Message &request, P::Message *response, const P::RequestControl &) {
        response->succeeded = true;
        switch (request.operation) {
            case P::Operation::CaptureStateSnapshot: ++snapshots; response->payload = Encode(worker.info.environment); break;
            case P::Operation::AcquireFrontendLock: Require(!locked, "parent lock acquired once"); locked = true; break;
            case P::Operation::ReleaseFrontendLock: Require(locked, "parent owns released lock"); locked = false; break;
            case P::Operation::ExecuteDpkg: {
                Require(locked, "execution has parent lock"); const auto requestValue(Decode<P::ParentExecutionRequest>(request));
                Require(requestValue.actions == std::vector<std::uint64_t>{17} && requestValue.arguments.back() == "fixture:native",
                    "real reverse RPC retains exact reviewed identities");
                ++executions; P::ParentExecutionReply result; result.started = true; result.exitCode = 0;
                response->payload = Encode(result); break;
            }
            case P::Operation::CommitExtendedState: {
                Require(locked && executions == 1 && Decode<P::ExtendedStateRequest>(request).changes.empty(),
                    "metadata commit follows the exact execution"); ++commits; break;
            }
            default: Require(false, "unexpected reverse operation in real client");
        }
    };
    Require(session.StartConnected(worker.TakeClient(), worker.info, Hello(worker.info), callbacks, 2000), "real client/server handshake");
    const auto reset(Decode<P::CacheReply>(Call(session, P::Operation::Reset)));
    Require(reset.binding.cacheEpoch == session.binding().cacheEpoch && !reset.opened, "client adopts reset epoch");
    Call(session, P::Operation::OpenCache);
    Require(session.binding().cacheEpoch == reset.binding.cacheEpoch + 1, "client adopts subsequent cache epoch");
    Require(Decode<A::CacheStateSummary>(Call(session, P::Operation::CacheState)).installs == 2, "cache values over real channel");
    Require(Decode<bool>(Call(session, P::Operation::LockForTransaction)), "parent lock before native review");
    Call(session, P::Operation::TransactionData); Require(!session.binding().review.empty(), "real reviewed binding");
    Call(session, P::Operation::PrepareArchives);
    Call(session, P::Operation::UnlockForTransaction); // The native sheet is presented with no held lock.
    Call(session, P::Operation::LockForTransaction);
    Call(session, P::Operation::RunFetcher, Encode(std::uint32_t(10)));
    const auto execution(Decode<P::PackageManagerReply>(Call(session, P::Operation::RunPackageManager)));
    Require(execution.started && execution.result == A::PackageManagerResult::Completed && commits == 1 &&
        session.binding().review.empty() && !session.indeterminate(), "execution and commit settle without a stale review");
    Call(session, P::Operation::UnlockForTransaction);
    A::SourceResourceRequest source; source.uri = "https://fixture.invalid/Release";
    Require(Decode<A::SourceResourceResult>(Call(session, P::Operation::SourceResource, Encode(source))).bytes == "metadata", "source bytes over channel");
    Require(progress.size() == 2 && progress[0].sourceActivity == P::SourceActivity::Started &&
        progress[1].sourceActivity == P::SourceActivity::Finished && progress[0].message == "Téléchargement",
        "typed source activity and upstream text reach the client");
    source.uri = "https://fixture.invalid/wait"; P::Message cancelled;
    Require(!session.Call(P::Operation::SourceResource, Encode(source), &cancelled, 2000, [&]() { return waiting; }) &&
        session.lastError() == "provider_cancelled" && session.active() && !session.indeterminate(),
        "real cancellation acknowledges and settles on the same server");
    Call(session, P::Operation::LoadSources);
    session.Close(); worker.Finish();
    Require(!uncertain && !locked && snapshots >= 5 && worker.result == P::ServerTransportResult::EndOfStream,
        "settled client close leaves no lock or unknown mutation");
}
void InterleavedParentCancellation() {
    Worker worker; const int socket(worker.client);
    auto request(Greeting(worker.info)); SendBytes(socket, Frame(request));
    Require(Receive(socket).succeeded, "manual transport handshake");
    request.operation = P::Operation::Reset; request.sequence = 2; request.payload.clear(); SendBytes(socket, Frame(request));
    const auto parent(Receive(socket)); Require(parent.operation == P::Operation::CaptureStateSnapshot, "reverse snapshot is pending");
    P::Message cancel(request); cancel.operation = P::Operation::Cancel; cancel.sequence = 3; cancel.payload = Encode(std::uint64_t(2));
    P::Message response(parent); response.kind = P::MessageKind::ParentResponse; response.succeeded = true;
    response.payload = Encode(worker.info.environment);
    // Coalescing forces one reader to separate cancellation from the parent
    // reply without losing either or recursively consuming the same bytes.
    SendBytes(socket, Frame(cancel) + Frame(response));
    const auto acknowledged(Receive(socket)); const auto reset(Receive(socket));
    Require(P::ValidateReply(cancel, acknowledged) && acknowledged.succeeded && P::ValidateReply(request, reset) && reset.succeeded,
        "interleaved cancellation gets its own reply and preserves the pending parent response");
    request.sequence = 4; request.operation = P::Operation::LoadSources; request.binding = Decode<P::CacheReply>(reset).binding;
    SendBytes(socket, Frame(request)); Require(Receive(socket).succeeded, "sequence remains synchronized after interleaved cancellation");
    worker.Finish(); Require(worker.result == P::ServerTransportResult::EndOfStream, "interleaved stream closes cleanly");
}
void LateCancellation() {
    Worker worker(true); P::Session session;
    bool locked(false), uncertain(false); unsigned executions(0), commits(0);
    P::SessionCallbacks callbacks;
    callbacks.closed = [&](bool value) { uncertain = value; };
    callbacks.parentRequest = [&](const P::Message &request, P::Message *reply, const P::RequestControl &) {
        reply->succeeded = true;
        switch (request.operation) {
            case P::Operation::CaptureStateSnapshot: reply->payload = Encode(worker.info.environment); break;
            case P::Operation::AcquireFrontendLock: Require(!locked, "late-cancel parent lock is acquired once"); locked = true; break;
            case P::Operation::ReleaseFrontendLock: Require(locked, "late-cancel parent releases its lock"); locked = false; break;
            case P::Operation::ExecuteDpkg: {
                Require(locked, "completed mutation retains the parent lock"); ++executions;
                P::ParentExecutionReply result; result.started = true; result.exitCode = 0; reply->payload = Encode(result); break;
            }
            case P::Operation::CommitExtendedState:
                Require(locked && executions == 1, "completed mutation commits only after its execution"); ++commits; break;
            default: Require(false, "unexpected late-cancel reverse request");
        }
    };
    Require(session.StartConnected(worker.TakeClient(), worker.info, Hello(worker.info), callbacks, 2000), "late-cancel handshake");
    P::Message response;
    // The callback becomes true only after RunOne has written the response.
    // This exercises the real Session's cancellation before response adoption,
    // without relying on sleeps to win a transport race or replaying a request.
    Require(!session.Call(P::Operation::Reset, "", &response, 4000, [&]() { return worker.CancelAfterResponse(); }) &&
        response.succeeded && Decode<P::CacheReply>(response).binding.cacheEpoch == 1 &&
        session.binding().cacheEpoch == 1 && session.lastError() == "provider_cancelled" && session.active() &&
        !session.indeterminate() && worker.backend.resets == 1,
        "late reset cancellation adopts completed epoch and keeps the session without replay");
    worker.completion.store(0);
    Call(session, P::Operation::OpenCache);
    Call(session, P::Operation::LockForTransaction); Call(session, P::Operation::TransactionData);
    Require(!session.binding().review.empty(), "native review exists before completed mutation");
    Require(!session.Call(P::Operation::RunPackageManager, "", &response, 4000, [&]() { return worker.CancelAfterResponse(); }) &&
        response.succeeded && Decode<P::PackageManagerReply>(response).result == A::PackageManagerResult::Completed &&
        session.lastCallExecutionStarted() && session.mutationStarted() && session.binding().review.empty() &&
        session.active() && !session.indeterminate() && session.lastError() == "provider_cancelled" && executions == 1 && commits == 1,
        "late mutation cancellation preserves actual execution and commit while consuming the review");
    Require(!session.Call(P::Operation::RunPackageManager, "", &response) &&
        session.lastError() == "provider_review_or_lock_required" && executions == 1 && commits == 1,
        "completed mutation cannot be retried under its consumed review");
    Call(session, P::Operation::UnlockForTransaction); Call(session, P::Operation::LoadSources);
    session.Close(); worker.Finish();
    Require(!uncertain && !locked && worker.result == P::ServerTransportResult::EndOfStream,
        "late cancellation settles before continued work and clean close");
}
void InvalidLateCancellation() {
    for (unsigned invalid = 0; invalid != 4; ++invalid) {
        Worker worker; const int socket(worker.client);
        auto request(Greeting(worker.info)); SendBytes(socket, Frame(request)); Require(Receive(socket).succeeded, "late-cancel rejection handshake");
        request.operation = P::Operation::LoadSources; request.sequence = 2; request.payload.clear();
        SendBytes(socket, Frame(request)); Require(Receive(socket).succeeded, "completed request for late-cancel rejection");
        P::Message cancel(request); cancel.operation = P::Operation::Cancel; cancel.sequence = 3; cancel.payload = Encode(std::uint64_t(2));
        if (invalid == 0) {
            SendBytes(socket, Frame(cancel)); const auto acknowledgement(Receive(socket));
            Require(P::ValidateReply(cancel, acknowledgement) && acknowledgement.succeeded, "one exact late cancellation is acknowledged");
            ++cancel.sequence; // A second acknowledgement for that target is forbidden.
        } else if (invalid == 1) {
            ++request.sequence; SendBytes(socket, Frame(request)); Require(Receive(socket).succeeded, "new request supersedes old cancellation target");
            ++cancel.sequence; // Target remains the older completed request.
        } else if (invalid == 2) cancel.binding.policyIdentity = "another-policy";
        else ++cancel.sequence; // A sequence gap is not late cancellation.
        SendBytes(socket, Frame(cancel)); worker.Finish();
        Require(worker.result == P::ServerTransportResult::Failed &&
            worker.server->lastError() == (invalid == 3 ? "provider_invalid_request" : "provider_invalid_cancel_request"),
            "duplicate, stale-target, changed-binding and out-of-sequence late cancellations fail closed");
    }
}
void BrokenStreams() {
    for (const std::string &bytes : {std::string(), std::string("CYA"), std::string("CYAP\0\0\0\x10short", 13),
                                   std::string("CYAP\xff\xff\xff\xff", 8)}) {
        int sockets[2]; SocketPair(sockets); Backend backend;
        P::ServerTransport transport(sockets[1]); auto hooks(Hooks(backend, Info())); transport.Attach(&hooks); P::Server server(backend, hooks);
        if (!bytes.empty()) SendBytes(sockets[0], bytes);
        close(sockets[0]);
        const auto result(transport.RunOne(server, 100));
        Require(result == (bytes.empty() ? P::ServerTransportResult::EndOfStream : P::ServerTransportResult::Failed),
            "clean EOF differs from truncation/oversized frames");
        Require(!transport.valid() && backend.resets == 0, "invalid input cannot reach package state");
    }
    {
        int sockets[2]; SocketPair(sockets); Backend backend; P::ServerTransport transport(sockets[1]);
        auto hooks(Hooks(backend, Info())); transport.Attach(&hooks); P::Server server(backend, hooks);
        Require(transport.RunOne(server, 10) == P::ServerTransportResult::TimedOut && !transport.valid(), "idle read has a finite deadline");
        close(sockets[0]);
    }
    {
        int sockets[2]; SocketPair(sockets); Backend backend; P::ServerTransport transport(sockets[1]);
        auto hooks(Hooks(backend, Info())); transport.Attach(&hooks); P::Server server(backend, hooks);
        Require(transport.RunOne(server, 100, []() { return true; }) == P::ServerTransportResult::Stopped && !transport.valid(),
            "worker stop closes its owned socket without dispatch"); close(sockets[0]);
    }
    {
        int sockets[2]; SocketPair(sockets); int small(4096);
        Require(setsockopt(sockets[1], SOL_SOCKET, SO_SNDBUF, &small, sizeof(small)) == 0, "small write buffer");
        Backend backend; auto info(Info()); info.implementationVersion.assign(1024 * 1024, 'v');
        P::ServerTransport transport(sockets[1], 20); auto hooks(Hooks(backend, info)); transport.Attach(&hooks); P::Server server(backend, hooks);
        SendBytes(sockets[0], Frame(Greeting(info)));
        Require(transport.RunOne(server, 100) == P::ServerTransportResult::Failed &&
            transport.lastError() == "provider_write_timeout", "unread large reply has a finite write deadline"); close(sockets[0]);
    }
}
}
int main() {
    EndToEnd(); InterleavedParentCancellation(); LateCancellation(); InvalidLateCancellation(); BrokenStreams();
    std::cout << "[apt-provider-transport] real client/server protocol and bounded socket failures passed\n";
}
