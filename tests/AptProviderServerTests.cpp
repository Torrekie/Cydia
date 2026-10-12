/* Worker dispatch tests: no APT library, subprocess or package mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderServer.hpp"
#include "Cydia/AptBackendImplementation.hpp"
#include <cstdlib>
#include <iostream>
#include <stdexcept>

namespace {
namespace A = CydiaAPT;
namespace P = A::Provider;
void Require(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "[apt-provider-server] " << message << '\n'; std::exit(1);
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
    std::function<bool(const P::ServerRequestContext &)> fetch;
    void reset() override { ++resets; }
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
        A::FetchResultData value; value.completed = !fetch || fetch(*context); return value;
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
    A::SourceResourceResult sourceResource(const A::SourceResourceRequest &, const std::function<bool()> &cancelled) override {
        ++sources; Require(context != nullptr, "source has cooperative context");
        P::ProgressEvent event; event.type = "download"; event.current = 1; event.total = 4;
        (void) context->progress(event);
        A::SourceResourceResult result; result.status = cancelled() ? A::SourceCheckStatus::Cancelled : A::SourceCheckStatus::Complete;
        if (result.status == A::SourceCheckStatus::Complete) result.bytes = "metadata";
        return result;
    }
};

struct Fixture {
    Backend backend;
    P::Info info = Info();
    P::ServerHooks hooks;
    std::unique_ptr<P::Server> server;
    P::Binding binding;
    std::uint64_t next = 1, parent = 0;
    unsigned polls = 0, cancelAfter = 0, managerCalls = 0, snapshots = 0, executions = 0, commits = 0;
    std::string controlFrame;
    std::vector<P::Message> events;
    bool parentLocked = false, changedState = false, wrongParentBinding = false, falseStarted = false;
    bool denySnapshot = false, omitCommit = false, throwEmission = false;
    Fixture() {
        hooks.admit = [this](const P::Hello &hello, P::Info *result, std::string *) {
            Require(hello.registrationPath == "/distribution/provider.plist", "admission sees registration"); *result = info; return true;
        };
        hooks.pollControl = [this](std::string *frame, const P::ServerControl &) {
            ++polls; if (!controlFrame.empty() && polls >= cancelAfter) frame->swap(controlFrame); return true;
        };
        hooks.emitFrame = [this](const std::string &frame, const P::ServerControl &) {
            if (throwEmission) throw std::runtime_error("fixture transport exception");
            events.push_back(Message(frame)); return true;
        };
        hooks.operationContext = [this](const P::ServerRequestContext *context) { backend.context = context; };
        hooks.buildReview = [](const A::TransactionData &, const P::Binding &, P::ExecutionManifest *manifest, std::string *) {
            P::ReviewedAction action; action.identifier = 17; action.action = P::ExecutionAction::Configure;
            action.package = {"fixture", "1", "native"}; manifest->actions = {action}; return true;
        };
        hooks.updateLists = [](int interval, const P::ServerRequestContext &) {
            Require(interval == 12, "update hook gets pulse interval");
            A::UpdateResultData result; result.prepared = result.success = result.metadataComplete = true; return result;
        };
        hooks.runPackageManager = [this](const P::ReviewedTransaction &review, const std::vector<A::AutoInstalledDelta> &deltas,
                                        const P::ServerRequestContext &context) {
            ++managerCalls; P::ParentExecutionRequest request;
            request.binding = review.binding; request.batch = 1; request.action = P::ExecutionAction::Configure;
            request.actions = {17}; request.arguments = {"--configure", "fixture:native"};
            P::Message response;
            const bool ok(context.parentRequest(P::Operation::ExecuteDpkg, Encode(request), &response));
            P::PackageManagerReply result;
            if (ok && response.succeeded) {
                result.started = !falseStarted && Decode<P::ParentExecutionReply>(response).started;
                result.result = A::PackageManagerResult::Completed;
                if (!omitCommit) {
                    P::ExtendedStateRequest state; state.binding = review.binding; state.changes = deltas;
                    if (!context.parentRequest(P::Operation::CommitExtendedState, Encode(state), &response) || !response.succeeded)
                        result.result = A::PackageManagerResult::Failed;
                }
            }
            return result;
        };
        hooks.parentExchange = [this](const std::string &frame, std::string *output, const P::ServerControl &) {
            const auto request(Message(frame));
            Require(request.kind == P::MessageKind::ParentRequest && request.sequence == ++parent &&
                P::SameBinding(request.binding, binding), "reverse requests retain active binding and independent sequence");
            P::Message response(request); response.kind = P::MessageKind::ParentResponse; response.payload.clear(); response.succeeded = true;
            switch (request.operation) {
                case P::Operation::CaptureStateSnapshot: {
                    ++snapshots; auto environment(info.environment);
                    if (denySnapshot) { response.succeeded = false; response.errorCode = "fixture_snapshot_denied"; break; }
                    if (changedState) environment.packageStateIdentity = "state-v2";
                    response.payload = Encode(environment); break;
                }
                case P::Operation::AcquireFrontendLock: Require(!parentLocked, "parent lock double acquisition"); parentLocked = true; break;
                case P::Operation::ReleaseFrontendLock: Require(parentLocked, "parent lock release ownership"); parentLocked = false; break;
                case P::Operation::ExecuteDpkg: {
                    Require(parentLocked, "only parent executes under its lock"); ++executions;
                    const auto execution(Decode<P::ParentExecutionRequest>(request));
                    Require(execution.actions == std::vector<std::uint64_t>{17}, "exact action reaches parent broker");
                    P::ParentExecutionReply result; result.started = true; result.exitCode = 0; response.payload = Encode(result); break;
                }
                case P::Operation::CommitExtendedState: ++commits; break;
                default: Require(false, "unexpected parent operation");
            }
            if (wrongParentBinding) response.binding.policyIdentity = "other-policy";
            *output = Frame(response); return true;
        };
        server.reset(new P::Server(backend, hooks));
    }
    P::Message Request(P::Operation operation, const std::string &payload = "") {
        P::Message request; request.sequence = next++; request.operation = operation; request.binding = binding; request.payload = payload; return request;
    }
    P::Message Call(P::Operation operation, const std::string &payload = "") {
        const auto request(Request(operation, payload)); std::string output;
        Require(server->DispatchFrame(Frame(request), &output), "server dispatch unexpectedly closed");
        const auto response(Message(output)); Require(P::ValidateReply(request, response), "response changed the request envelope");
        if (response.succeeded) {
            if (operation == P::Operation::Reset || operation == P::Operation::OpenCache) binding = Decode<P::CacheReply>(response).binding;
            else if (operation == P::Operation::TransactionData) binding = Decode<P::ReviewedTransaction>(response).binding;
            else if (operation == P::Operation::InstallPackage) { ++binding.selectionRevision; binding.review.clear(); }
            else if (operation == P::Operation::RunPackageManager) binding.review.clear();
        }
        return response;
    }
    void Hello() {
        P::Hello hello; hello.challenge = std::string(64, 'a'); hello.expected = info.environment;
        hello.options.repositorySecurityMode = A::RepositorySecurityMode::Distribution;
        hello.registrationPath = "/distribution/provider.plist";
        binding.providerIdentifier = info.identifier; binding.session = hello.challenge;
        binding.configurationIdentity = info.environment.configurationIdentity; binding.policyIdentity = info.environment.policyIdentity;
        binding.packageStateIdentity = info.environment.packageStateIdentity;
        const auto response(Call(P::Operation::Hello, Encode(hello))); P::Info verified;
        Require(P::ValidateHelloReply(hello, response, &verified) && server->ready(), "client Hello validation accepts server admission");
    }
    void Review() { Hello(); Call(P::Operation::Reset); Call(P::Operation::TransactionData); }
};

void Framing() {
    P::Message message; message.sequence = 1;
    const std::string wire(Frame(message)); P::ServerFrameReader reader;
    std::string frame; bool complete(false); std::size_t consumed(0);
    for (std::size_t i = 0; i != wire.size(); ++i) {
        Require(reader.Push(wire.data() + i, 1, &consumed, &frame, &complete) && consumed == 1,
            "partial frame reader consumes bounded chunks");
        Require(complete == (i + 1 == wire.size()), "partial frame reported complete too early");
    }
    Require(frame == wire, "incremental framing changed bytes");
    const auto two(wire + wire);
    Require(reader.Push(two.data(), two.size(), &consumed, &frame, &complete) && complete && consumed == wire.size(),
        "reader stops at one frame instead of accepting pipelined bytes");
    const std::string oversized("CYAP\xff\xff\xff\xff", 8); P::ServerFrameReader bounded;
    Require(!bounded.Push(oversized.data(), oversized.size(), &consumed, &frame, &complete) && consumed == 8 &&
        bounded.error() == "provider_message_too_large", "oversized header rejected before body allocation");
    P::ServerFrameReader malformed;
    Require(!malformed.Push("NOPE0001", 8, &consumed, &frame, &complete), "bad magic rejected");
}
void DispatchAndReview() {
    Fixture fixture; fixture.Hello();
    const auto reset(Decode<P::CacheReply>(fixture.Call(P::Operation::Reset)));
    Require(!reset.opened && reset.binding.cacheEpoch == 1 && fixture.backend.resets == 1 && fixture.snapshots == 1,
        "reset establishes epoch without claiming an opened cache");
    Require(Decode<A::CacheStateSummary>(fixture.Call(P::Operation::CacheState)).installs == 2, "cache value dispatch");
    Require(Decode<std::vector<A::ErrorData>>(fixture.Call(P::Operation::DrainErrors)).front().message == "Diagnostic amont",
        "upstream diagnostic text survives server dispatch");
    P::LookupRequest lookup; lookup.name = "fixture"; lookup.preferredArchitecture = "foreign";
    Require(Decode<A::PackageLookupResult>(fixture.Call(P::Operation::LookupPackage, Encode(lookup))).handle.value == 7, "lookup dispatch");
    fixture.Call(P::Operation::TransactionData); const auto oldReview(fixture.binding.review);
    fixture.backend.selectionResult = false;
    Require(!Decode<bool>(fixture.Call(P::Operation::InstallPackage, Encode(A::PackageHandle(7)))) &&
        fixture.binding.selectionRevision == 1 && fixture.server->binding().review.empty(),
        "false selection result still invalidates review and advances revision");
    fixture.Call(P::Operation::TransactionData);
    Require(fixture.binding.review != oldReview, "repeated preview does not reuse an earlier review token");
    Require(Decode<bool>(fixture.Call(P::Operation::LockForTransaction)) && fixture.parentLocked, "parent owns the lock");
    Require(Decode<bool>(fixture.Call(P::Operation::PrepareArchives)) && fixture.backend.preparations == 1, "reviewed prepare dispatch");
    Require(Decode<A::FetchResultData>(fixture.Call(P::Operation::RunFetcher, Encode(std::uint32_t(10)))).completed, "reviewed fetch dispatch");
    const auto manager(Decode<P::PackageManagerReply>(fixture.Call(P::Operation::RunPackageManager)));
    Require(manager.started && manager.result == A::PackageManagerResult::Completed && fixture.managerCalls == 1 &&
        fixture.executions == 1 && fixture.commits == 1 && fixture.server->binding().review.empty(),
        "only explicit parent execution and state commit settle the review");
    fixture.Call(P::Operation::UnlockForTransaction);
    Require(!fixture.parentLocked && fixture.backend.context == nullptr, "context and parent lock cleared");
    Require(Decode<A::UpdateResultData>(fixture.Call(P::Operation::UpdateLists, Encode(std::uint32_t(12)))).success,
        "update uses explicit status adapter hook");
}
void FailureBoundaries() {
    {
        Fixture fixture; P::ServerLimits limits; limits.exchangeMessages = 2;
        fixture.server.reset(new P::Server(fixture.backend, fixture.hooks, limits)); fixture.Hello();
        const auto request(fixture.Request(P::Operation::Reset)); std::string output;
        Require(!fixture.server->DispatchFrame(Frame(request), &output) && fixture.backend.resets == 0,
            "parent traffic shares the active request's bounded message budget");
    }
    {
        Fixture fixture; fixture.Hello(); fixture.denySnapshot = true;
        const auto denied(fixture.Call(P::Operation::Reset));
        Require(!denied.succeeded && fixture.backend.resets == 0 && fixture.server->binding().cacheEpoch == 0,
            "denied snapshot cannot reset the backend or advance its cache epoch");
        fixture.denySnapshot = false; fixture.Call(P::Operation::Reset); fixture.backend.opened = false;
        const auto previous(fixture.binding); fixture.changedState = true;
        const auto failed(Decode<P::CacheReply>(fixture.Call(P::Operation::OpenCache)));
        Require(!failed.opened && P::SameBinding(failed.binding, previous) && P::SameBinding(fixture.server->binding(), previous),
            "failed open retains the old epoch and package-state binding");
        fixture.backend.opened = true;
        const auto opened(Decode<P::CacheReply>(fixture.Call(P::Operation::OpenCache)));
        Require(opened.binding.cacheEpoch == previous.cacheEpoch + 1 && opened.binding.packageStateIdentity == "state-v2",
            "successful cache reply adopts only the parent-approved state in its payload");
    }
    {
        Fixture fixture; fixture.Hello(); fixture.Call(P::Operation::Reset);
        const auto request(fixture.Request(P::Operation::CacheState)); std::string output;
        Require(fixture.server->DispatchFrame(Frame(request), &output), "first sequence accepted");
        Require(!fixture.server->DispatchFrame(Frame(request), &output) && fixture.server->closed(), "replayed sequence closes server");
    }
    {
        Fixture fixture; fixture.Hello(); fixture.Call(P::Operation::Reset);
        auto request(fixture.Request(P::Operation::CacheState)); request.binding.policyIdentity = "other-policy"; std::string output;
        Require(!fixture.server->DispatchFrame(Frame(request), &output), "wrong policy binding rejected");
    }
    {
        Fixture fixture; fixture.Review();
        const auto denied(fixture.Call(P::Operation::PrepareArchives));
        Require(!denied.succeeded && denied.errorCode == "provider_review_or_lock_required" && fixture.backend.preparations == 0,
            "reviewed operation cannot bypass parent lock");
        fixture.Call(P::Operation::LockForTransaction); fixture.changedState = true;
        const auto changed(fixture.Call(P::Operation::PrepareArchives));
        Require(!changed.succeeded && changed.errorCode == "provider_package_state_changed" && fixture.backend.preparations == 0,
            "parent state drift blocks the backend before acquisition");
    }
    {
        Fixture fixture; fixture.Hello(); fixture.Call(P::Operation::Reset);
        fixture.Call(P::Operation::LockForTransaction);
        Require(fixture.Call(P::Operation::TransactionData).succeeded && !fixture.server->binding().review.empty(),
            "native review may be captured under the parent's short frontend lock");
        fixture.Call(P::Operation::UnlockForTransaction);
    }
    {
        Fixture fixture; fixture.Hello(); fixture.wrongParentBinding = true;
        const auto request(fixture.Request(P::Operation::Reset)); std::string output;
        Require(!fixture.server->DispatchFrame(Frame(request), &output) && fixture.backend.resets == 0,
            "malformed parent reply cannot establish cache");
    }
    {
        Fixture fixture; fixture.Review(); fixture.Call(P::Operation::LockForTransaction); fixture.falseStarted = true;
        const auto request(fixture.Request(P::Operation::RunPackageManager)); std::string output;
        Require(!fixture.server->DispatchFrame(Frame(request), &output) && fixture.executions == 1,
            "worker cannot hide parent-observed execution");
    }
    {
        Fixture fixture; fixture.Review(); fixture.Call(P::Operation::LockForTransaction); fixture.omitCommit = true;
        const auto request(fixture.Request(P::Operation::RunPackageManager)); std::string output;
        Require(!fixture.server->DispatchFrame(Frame(request), &output) && fixture.executions == 1 && !fixture.commits &&
            fixture.server->lastError() == "provider_incomplete_execution", "completed execution cannot imply an unacknowledged state commit");
    }
    {
        Fixture fixture; fixture.Hello(); fixture.Call(P::Operation::Reset); fixture.backend.throwing = true;
        const auto request(fixture.Request(P::Operation::CacheState)); std::string output;
        Require(!fixture.server->DispatchFrame(Frame(request), &output) && fixture.backend.context == nullptr &&
            fixture.server->lastError() == "provider_operation_callback_failed", "callback exception closes cleanly without leaking exception text");
    }
    {
        Fixture fixture; fixture.hooks.runPackageManager = {}; fixture.server.reset(new P::Server(fixture.backend, fixture.hooks));
        P::Message request; request.sequence = 1; P::Hello hello;
        hello.challenge = std::string(64, 'a'); hello.expected = fixture.info.environment;
        hello.options.repositorySecurityMode = A::RepositorySecurityMode::Distribution; request.payload = Encode(hello);
        std::string output;
        Require(!fixture.server->DispatchFrame(Frame(request), &output) && fixture.server->lastError() == "provider_server_hooks_incomplete",
            "missing execution bridge cannot advertise a ready provider");
    }
}
void ArchiveAuthorization() {
    for (unsigned variant = 0; variant != 5; ++variant) {
        Fixture fixture; unsigned grants = 0;
        if (variant != 1) fixture.info.capabilities |= P::AuthorizedArchiveGrants;
        fixture.hooks.buildReview = [](const A::TransactionData &, const P::Binding &, P::ExecutionManifest *manifest, std::string *) {
            P::ArchiveManifest archive; archive.identifier = "approved"; manifest->archives = {archive}; return true;
        };
        const auto original = fixture.hooks.parentExchange;
        fixture.hooks.parentExchange = [&](const std::string &frame, std::string *output, const P::ServerControl &control) {
            const auto request = Message(frame);
            if (request.operation != P::Operation::AuthorizeArchive) return original(frame, output, control);
            Require(request.sequence == ++fixture.parent && P::SameBinding(request.binding, fixture.binding), "grant parent sequence/binding");
            const auto grant = Decode<P::ArchiveAuthorizationRequest>(request);
            Require(grant.archive == "approved" && P::SameBinding(grant.binding, fixture.binding), "grant exact approved archive");
            ++grants; P::Message response(request); response.kind = P::MessageKind::ParentResponse; response.succeeded = true;
            P::ArchiveAuthorizationReply result; result.status = CydiaRuntime::RepositoryArchiveAuthorizationStatus::Authorized;
            result.transportURL = "https://cdn.invalid/file?token=secret";
            response.payload = variant == 4 ? "malformed grant" : Encode(result);
            *output = Frame(response); return true;
        };
        fixture.backend.fetch = [&](const P::ServerRequestContext &context) {
            P::ArchiveAuthorizationRequest request; request.binding = fixture.binding;
            request.archive = variant == 2 ? "unapproved" : "approved";
            if (variant == 3) ++request.binding.selectionRevision;
            P::Message response;
            const bool sent = context.parentRequest(P::Operation::AuthorizeArchive, Encode(request), &response);
            return sent && response.succeeded;
        };
        fixture.server.reset(new P::Server(fixture.backend, fixture.hooks));
        fixture.Review(); fixture.Call(P::Operation::LockForTransaction);
        const auto request = fixture.Request(P::Operation::RunFetcher, Encode(std::uint32_t(10))); std::string output;
        const bool dispatched = fixture.server->DispatchFrame(Frame(request), &output);
        if (!variant) Require(dispatched && Message(output).succeeded && grants == 1, "negotiated reviewed fetch may authorize archive");
        else Require(!dispatched && grants == (variant == 4 ? 1u : 0u), "unnegotiated/stale/unknown request and malformed parent grant rejected");
    }
}
void CancellationAndProgress() {
    Fixture fixture; fixture.Hello(); fixture.polls = 0; fixture.cancelAfter = 3;
    P::Message cancel; cancel.operation = P::Operation::Cancel; cancel.sequence = fixture.next + 1;
    cancel.binding = fixture.binding; cancel.payload = Encode(fixture.next); fixture.controlFrame = Frame(cancel);
    A::SourceResourceRequest request; request.uri = "https://fixture.invalid/Release";
    const auto result(Decode<A::SourceResourceResult>(fixture.Call(P::Operation::SourceResource, Encode(request))));
    ++fixture.next;
    Require(result.status == A::SourceCheckStatus::Cancelled && fixture.backend.sources == 1 && fixture.events.size() == 2,
        "active cancellation settles the same operation and emits progress plus acknowledgement");
    Require(fixture.events[0].kind == P::MessageKind::Event && fixture.events[0].sequence == cancel.sequence - 1 &&
        fixture.events[0].operation == P::Operation::Progress && P::ValidateReply(cancel, fixture.events[1]) && fixture.events[1].succeeded,
        "progress and cancellation use their distinct request sequences");
    Require(fixture.Call(P::Operation::LoadSources).succeeded, "settled cancellation keeps session usable");
    {
        Fixture ending; ending.Hello(); ending.Call(P::Operation::Reset);
        ending.polls = 0; ending.cancelAfter = 2; ending.throwEmission = true;
        P::Message cancel; cancel.operation = P::Operation::Cancel; cancel.sequence = ending.next + 1;
        cancel.binding = ending.binding; cancel.payload = Encode(ending.next); ending.controlFrame = Frame(cancel);
        const auto request(ending.Request(P::Operation::CacheState)); std::string output;
        Require(!ending.server->DispatchFrame(Frame(request), &output) && ending.backend.context == nullptr,
            "throwing final cancellation acknowledgement still clears the backend context");
    }
}
}
int main() {
    Framing(); DispatchAndReview(); FailureBoundaries(); CancellationAndProgress(); ArchiveAuthorization();
    std::cout << "[apt-provider-server] bounded framing, binding, reverse authority and cancellation passed\n";
}
