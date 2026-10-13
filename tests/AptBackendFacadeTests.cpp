/* Public Cydia backend facade exercised through a process-protocol peer.
 * No APT implementation, privileged executor or package manager is mocked into
 * the facade: this executable links only its remote implementation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptBackend.hpp"
#include "Cydia/RuntimeProviderAdmission.hpp"
#include "Cydia/AptProviderSession.hpp"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <poll.h>
#include <set>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

#if !defined(CYDIA_PROVIDER_SESSION_TESTING) || !CYDIA_PROVIDER_SESSION_TESTING
#error Compile this fixture with CYDIA_PROVIDER_SESSION_TESTING=1
#endif
// The facade only forwards this opaque UI context; no UIKit implementation is
// required or accessed in this host fixture.
namespace CydiaAPT { class AcquireStatus {}; }

namespace {
namespace A = CydiaAPT;
namespace P = A::Provider;
using Clock = std::chrono::steady_clock;
void Require(bool condition, const char *message) {
    if (condition) return;
    std::fprintf(stderr, "[apt-backend-facade] %s\n", message); std::exit(1);
}
P::Info Info() {
    P::Info info; info.availability = P::Availability::Ready; info.capabilities = P::RequiredCapabilities;
    info.identifier = "fixture"; info.implementationVersion = "1";
    info.libraryIdentity = "library-v1"; info.frontendIdentity = "frontend-v1";
    auto &e(info.environment);
    e.paths.dpkg = "/distribution/bin/dpkg"; e.paths.dpkgQuery = "/distribution/bin/dpkg-query";
    e.paths.dpkgDeb = "/distribution/bin/dpkg-deb"; e.paths.dpkgRoot = "/distribution";
    e.paths.dpkgAdmin = "/distribution/state/dpkg"; e.paths.sourceList = "/distribution/etc/apt/sources.list";
    e.paths.sourceParts = "/distribution/etc/apt/sources.list.d";
    e.configurationIdentity = "configuration-v1"; e.policyIdentity = "policy-v1";
    e.methodsIdentity = "methods-v1"; e.packageStateIdentity = "state-v1";
    e.nativeArchitecture = "native"; e.registeredArchitectures = {"native", "foreign"};
    e.acquisitionArchitectures = e.registeredArchitectures; return info;
}
bool Bytes(int fd, char *bytes, size_t count) {
    const auto end(Clock::now() + std::chrono::seconds(5));
    while (count != 0 && Clock::now() < end) {
        pollfd wait = {fd, POLLIN, 0};
        if (poll(&wait, 1, 25) <= 0) continue;
        const ssize_t n(recv(fd, bytes, count, 0));
        if (n <= 0) return false;
        bytes += n; count -= n;
    }
    return count == 0;
}
bool Read(int fd, P::Message *message) {
    std::string bytes(8, '\0'); if (!Bytes(fd, &bytes[0], 8)) return false;
    std::uint32_t n(0); for (unsigned i(4); i != 8; ++i) n = (n << 8) | static_cast<unsigned char>(bytes[i]);
    if (n == 0 || n > P::MaximumMessageBytes - 8) return false;
    bytes.resize(n + 8); return Bytes(fd, &bytes[8], n) && P::DecodeFrame(bytes, message);
}
bool Send(int fd, const P::Message &message) {
    std::string bytes; if (!P::EncodeFrame(message, &bytes)) return false;
    size_t offset(0);
    while (offset < bytes.size()) {
        int flags(0);
#ifdef MSG_NOSIGNAL
        flags |= MSG_NOSIGNAL;
#endif
        const ssize_t n(send(fd, bytes.data() + offset, bytes.size() - offset, flags));
        if (n <= 0) return false;
        offset += n;
    }
    return true;
}
P::Message Reply(const P::Message &request) {
    P::Message reply(request); reply.kind = P::MessageKind::Response; reply.succeeded = true; reply.payload.clear(); return reply;
}
template<class T> void Encode(const T &value, P::Message *reply) { Require(P::Encode(value, &reply->payload), "fixture encoding"); }
template<class T> T Decode(const P::Message &request) { T value; Require(P::Decode(request.payload, &value), "request payload schema"); return value; }
bool Changes(P::Operation operation) {
    switch (operation) {
        case P::Operation::ApplyStatus: case P::Operation::FixBroken: case P::Operation::MinimizeUpgrade:
        case P::Operation::ResolveDependencies: case P::Operation::ClearSelections: case P::Operation::PrepareDistUpgrade:
        case P::Operation::ClearPackage: case P::Operation::InstallPackage: case P::Operation::ReinstallPackage:
        case P::Operation::RemovePackage: return true;
        default: return false;
    }
}
enum class Mode {
    Complete, FailedReply, MalformedValue, MalformedVoid, WrongHandle, Disconnect, LostExecution,
    SourceStatuses, SourceBudget, CancelSource, CancelFetch, CancelManager, SensitiveDiagnostics, DeniedRelease,
    SourceFalse, SourceRejected, SourceError, CacheFalse, CacheError, SourceMalformed, SourceDisconnect
};
struct Peer {
    int client = -1, server = -1;
    Mode mode; std::thread thread; std::set<P::Operation> seen;
    explicit Peer(Mode mode) : mode(mode) {
        int sockets[2]; Require(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "fixture socketpair");
        client = sockets[0]; server = sockets[1];
#ifdef SO_NOSIGPIPE
        const int one(1); setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        thread = std::thread([this]() { run(); });
    }
    ~Peer() { shutdown(server, SHUT_RDWR); if (client >= 0) close(client); if (thread.joinable()) thread.join(); close(server); }
    int take() { const int fd(client); client = -1; return fd; }
    bool reverse(const P::Message &active, P::Operation op, std::uint64_t sequence, const std::string &payload) {
        P::Message request; request.kind = P::MessageKind::ParentRequest; request.operation = op;
        request.sequence = sequence; request.binding = active.binding; request.payload = payload;
        P::Message reply; return Send(server, request) && Read(server, &reply) && P::ValidateReply(request, reply) && reply.succeeded;
    }
    bool settleCancellation(const P::Message &active) {
        P::Message cancel;
        if (!Read(server, &cancel)) return false;
        Require(cancel.operation == P::Operation::Cancel && Decode<std::uint64_t>(cancel) == active.sequence,
            "cancellation targets the active operation");
        return Send(server, Reply(cancel));
    }
    void run() {
        P::Message hello; if (!Read(server, &hello)) return;
        P::Hello initialization(Decode<P::Hello>(hello)); Require(P::ValidHello(initialization), "valid fixture handshake");
        P::Message greeting(Reply(hello)); Encode(Info(), &greeting); if (!Send(server, greeting)) return;
        P::Binding binding(hello.binding); std::uint64_t parentSequence(0);
        for (;;) {
            P::Message request; if (!Read(server, &request)) return;
            Require(P::SameBinding(request.binding, binding), "facade preserves the session epoch/revision/review binding");
            seen.insert(request.operation); P::Message response(Reply(request));
            switch (request.operation) {
                case P::Operation::Reset: case P::Operation::OpenCache: {
                    P::CacheReply cache; cache.opened = true; cache.binding = binding;
                    if (request.operation == P::Operation::OpenCache && mode == Mode::CacheFalse) cache.opened = false;
                    else { ++cache.binding.cacheEpoch; cache.binding.selectionRevision = 0; cache.binding.review.clear(); }
                    Encode(cache, &response); binding = cache.binding; break;
                }
                case P::Operation::CreateCacheViews: case P::Operation::DiscardErrors: case P::Operation::ClearSelections:
                    Require(request.payload.empty(), "void request is empty");
                    if (mode == Mode::MalformedVoid) response.payload = "unexpected";
                    break;
                case P::Operation::DrainErrors:
                    Encode(std::vector<A::ErrorData>{{mode == Mode::SensitiveDiagnostics ?
                        "Download https://user:password@fixture.invalid/private-token/file?secret=value failed" : "upstream diagnostic",
                        !(mode == Mode::SourceError || (mode == Mode::CacheError && seen.count(P::Operation::OpenCache))),
                        mode == Mode::SensitiveDiagnostics ? "provider_frontend_busy" : ""}}, &response); break;
                case P::Operation::CacheState: {
                    if (mode == Mode::Disconnect) { shutdown(server, SHUT_RDWR); return; }
                    A::CacheStateSummary cache; cache.installs = 4; Encode(cache, &response);
                    if (mode == Mode::FailedReply) { response.succeeded = false; response.errorCode = "fixture_rejected"; }
                    if (mode == Mode::SensitiveDiagnostics) {
                        response.succeeded = false;
                        response.errorCode = "https://user:password@fixture.invalid/private-token?secret=value";
                    }
                    if (mode == Mode::MalformedValue) response.payload = "invalid";
                    break;
                }
                case P::Operation::LoadSources:
                    Require(request.payload.empty(), "source request is empty");
                    if (mode == Mode::SourceDisconnect) { shutdown(server, SHUT_RDWR); return; }
                    Encode(mode != Mode::SourceFalse, &response);
                    if (mode == Mode::SourceRejected) {
                        response.succeeded = false; response.errorCode = "fixture_source_configuration_rejected"; response.payload.clear();
                    }
                    if (mode == Mode::SourceMalformed) response.payload = "invalid";
                    break;
                case P::Operation::ApplyStatus: case P::Operation::FixBroken:
                case P::Operation::MinimizeUpgrade: case P::Operation::CleanArchives: case P::Operation::PrepareArchives:
                case P::Operation::ResolveDependencies: case P::Operation::PrepareDistUpgrade:
                    Require(request.payload.empty(), "boolean request is empty"); Encode(true, &response); break;
                case P::Operation::ClearPackage: case P::Operation::InstallPackage: case P::Operation::ReinstallPackage:
                    Require(Decode<A::PackageHandle>(request).value == 7, "exact package handle"); Encode(true, &response); break;
                case P::Operation::RemovePackage: {
                    const auto removal(Decode<P::RemoveRequest>(request));
                    Require(removal.handle.value == 7 && removal.purge, "removal retains purge and exact handle"); Encode(true, &response); break;
                }
                case P::Operation::LockForTransaction:
                    Encode(reverse(request, P::Operation::AcquireFrontendLock, ++parentSequence, ""), &response); break;
                case P::Operation::UnlockForTransaction:
                    if (mode == Mode::DeniedRelease) {
                        response.succeeded = false; response.errorCode = "fixture_unlock_denied"; break;
                    }
                    Require(reverse(request, P::Operation::ReleaseFrontendLock, ++parentSequence, ""), "parent unlock callback"); break;
                case P::Operation::AutoInstalledDeltas:
                    Encode(std::vector<A::AutoInstalledDelta>{{"fixture", "foreign", true}}, &response); break;
                case P::Operation::SourceList: {
                    A::SourceListData sources; sources.success = true; sources.uris = {"https://fixture.invalid/"}; Encode(sources, &response); break;
                }
                case P::Operation::RunFetcher: {
                    Require(Decode<std::uint32_t>(request) == 13, "fetch interval forwarded");
                    A::FetchResultData fetch; fetch.completed = true;
                    if (mode == Mode::CancelFetch) {
                        if (!settleCancellation(request)) return;
                        fetch.completed = false;
                    }
                    A::FetchFailureData warning; warning.kind = A::FetchDiagnosticKind::UnsignedRepository; warning.package = "fixture:foreign";
                    fetch.warnings.push_back(warning); Encode(fetch, &response); break;
                }
                case P::Operation::UpdateLists: {
                    Require(Decode<std::uint32_t>(request) == 17, "update interval forwarded");
                    A::UpdateResultData update; update.prepared = update.success = update.metadataComplete = true;
                    Encode(update, &response); break;
                }
                case P::Operation::PackageHandles:
                    Encode(std::vector<A::PackageHandle>{A::PackageHandle(7)}, &response); break;
                case P::Operation::DowngradeHandles: case P::Operation::VersionHandles:
                    Require(Decode<A::PackageHandle>(request).value == 7, "version lookup uses its exact handle");
                    Encode(std::vector<A::PackageHandle>{A::PackageHandle(8)}, &response); break;
                case P::Operation::LookupPackage: case P::Operation::PackageHandle: {
                    const auto lookup(Decode<P::LookupRequest>(request));
                    Require(lookup.name == "fixture:foreign" && lookup.preferredArchitecture == "foreign", "lookup architecture retained");
                    if (request.operation == P::Operation::PackageHandle) Encode(A::PackageHandle(7), &response);
                    else { A::PackageLookupResult found; found.status = A::PackageLookupStatus::Found; found.handle = A::PackageHandle(7); Encode(found, &response); }
                    break;
                }
                case P::Operation::PackageSnapshot: {
                    const auto handle(Decode<A::PackageHandle>(request)); A::PackageSnapshot package; package.handle = handle;
                    package.architecture = "foreign"; package.version = "1";
                    if (mode == Mode::WrongHandle) package.handle = A::PackageHandle(99);
                    Encode(package, &response); break;
                }
                case P::Operation::RecordData: {
                    Require(Decode<A::PackageHandle>(request).value == 7, "record handle");
                    A::PackageRecordData record; record.fields["Architecture"] = "foreign"; Encode(record, &response); break;
                }
                case P::Operation::PackageState: {
                    Require(Decode<A::PackageHandle>(request).value == 7, "state handle");
                    A::PackageStateData state; state.installedVersion = true; Encode(state, &response); break;
                }
                case P::Operation::Relations: {
                    Require(Decode<A::PackageHandle>(request).value == 7, "relations handle");
                    A::RelationData relation; relation.relationship = "Depends";
                    A::RelationClauseData clause; clause.package = "dependency:any"; clause.providers = {A::PackageHandle(8)};
                    relation.clauses.push_back(clause); Encode(std::vector<A::RelationData>{relation}, &response); break;
                }
                case P::Operation::TransactionData: {
                    P::ReviewedTransaction review; review.binding = binding; review.binding.review = "review-v1";
                    review.transaction.installs = {"fixture:foreign"}; Encode(review, &response); binding = review.binding; break;
                }
                case P::Operation::RunPackageManager: {
                    P::ParentExecutionRequest execution; execution.binding = request.binding;
                    execution.arguments = {"--configure", "fixture:foreign"}; std::string payload;
                    Require(P::Encode(execution, &payload), "execution fixture encoding");
                    Require(reverse(request, P::Operation::ExecuteDpkg, ++parentSequence, payload), "fixture executor callback");
                    if (mode == Mode::LostExecution) { shutdown(server, SHUT_RDWR); return; }
                    if (mode == Mode::CancelManager && !settleCancellation(request)) return;
                    P::PackageManagerReply manager; manager.started = true; manager.result = A::PackageManagerResult::Completed;
                    manager.archives.completed = true; Encode(manager, &response); binding.review.clear(); break;
                }
                case P::Operation::SourceHandles:
                    Encode(std::vector<A::SourceHandle>{A::SourceHandle(9)}, &response); break;
                case P::Operation::SourceSnapshot: {
                    A::SourceSnapshot source; source.handle = Decode<A::SourceHandle>(request); source.label = "Fixture";
                    Encode(source, &response); break;
                }
                case P::Operation::SourceField: {
                    const auto field(Decode<P::SourceFieldRequest>(request)); Require(field.handle.value == 9 && field.name == "Origin", "source field payload");
                    Encode(std::string("fixture-origin"), &response); break;
                }
                case P::Operation::SourceFileIDs:
                    Require(Decode<A::SourceHandle>(request).value == 9, "source files handle"); Encode(std::vector<std::uint32_t>{23}, &response); break;
                case P::Operation::SourcePreflight: {
                    const auto check(Decode<A::SourcePreflightRequest>(request));
                    Require(check.definition == "deb https://fixture.invalid/ ./" && check.previouslyAuthenticated &&
                        check.candidatePublicKey == "explicit-key", "preflight preserves draft and trust inputs");
                    A::SourcePreflightResult result;
                    result.status = mode == Mode::SourceStatuses ? A::SourceCheckStatus::TimedOut : A::SourceCheckStatus::Complete;
                    result.allowed = result.status == A::SourceCheckStatus::Complete;
                    result.architecture = A::SourceArchitectureAvailability::Supported;
                    A::FetchFailureData warning; warning.kind = A::FetchDiagnosticKind::UnsignedRepository;
                    if (mode == Mode::SensitiveDiagnostics) {
                        result.errors.push_back({"Key https://user:password@fixture.invalid/private-token?secret=value unavailable",
                            false, "provider_frontend_busy"});
                        warning.error = "Failed https://fixture.invalid/private-token?secret=value";
                        warning.uri = "https://fixture.invalid/private-token?secret=value";
                    }
                    result.warnings.push_back(warning); Encode(result, &response); break;
                }
                case P::Operation::SourceResource: {
                    const auto resource(Decode<A::SourceResourceRequest>(request));
                    Require(resource.uri == "https://fixture.invalid/Release" && resource.maximumBytes == 1024,
                        "resource preserves bounded request");
                    if (mode == Mode::SourceBudget) std::this_thread::sleep_for(std::chrono::milliseconds(80));
                    A::SourceResourceResult result; result.status = A::SourceCheckStatus::Complete; result.bytes = "fixture metadata";
                    if (mode == Mode::SensitiveDiagnostics)
                        result.errors.push_back({"Fetch https://user:password@fixture.invalid/private-token?secret=value failed",
                            false, "provider_frontend_busy"});
                    if (mode == Mode::SourceStatuses) result.status = A::SourceCheckStatus::SizeLimit;
                    if (mode == Mode::CancelSource) {
                        P::Message cancel;
                        if (!Read(server, &cancel)) return;
                        Require(cancel.operation == P::Operation::Cancel && Decode<std::uint64_t>(cancel) == request.sequence,
                            "source cancellation targets the active source request");
                        if (!Send(server, Reply(cancel))) return;
                        result.status = A::SourceCheckStatus::Cancelled; result.bytes.clear();
                    }
                    Encode(result, &response); break;
                }
                default: Require(false, "unexpected facade operation");
            }
            if (response.succeeded && Changes(request.operation)) { ++binding.selectionRevision; binding.review.clear(); }
            if (!Send(server, response)) return;
        }
    }
};
std::unique_ptr<P::Session> Session(Peer &peer, bool *executed = nullptr, bool *closed = nullptr, bool *locked = nullptr) {
    std::unique_ptr<P::Session> session(new P::Session); P::Hello hello; hello.expected = Info().environment;
    hello.options.repositorySecurityMode = A::RepositorySecurityMode::Distribution;
    P::SessionCallbacks callbacks;
    callbacks.parentRequest = [executed, locked](const P::Message &request, P::Message *reply, const P::RequestControl &) {
        if (request.operation == P::Operation::AcquireFrontendLock || request.operation == P::Operation::ReleaseFrontendLock) {
            reply->succeeded = true;
            if (locked != nullptr) *locked = request.operation == P::Operation::AcquireFrontendLock;
        }
        if (request.operation == P::Operation::ExecuteDpkg) {
            if (executed != nullptr) *executed = true;
            P::ParentExecutionReply result; result.started = true; result.exitCode = 0;
            reply->succeeded = P::Encode(result, &reply->payload);
        }
    };
    callbacks.closed = [closed, locked](bool) {
        if (closed != nullptr) *closed = true;
        // The fixture models the coordinator's app-owned lock cleanup.
        if (locked != nullptr) *locked = false;
    };
    Require(session->StartConnected(peer.take(), Info(), hello, callbacks, 1000), "facade fixture handshake");
    return session;
}
A::SourcePreflightRequest SourceCheck() {
    A::SourcePreflightRequest input; input.definition = "deb https://fixture.invalid/ ./";
    input.previouslyAuthenticated = true; input.candidatePublicKey = "explicit-key";
    input.temporaryParent = "/fixture/tmp"; return input;
}
A::SourceResourceRequest SourceResource() {
    A::SourceResourceRequest input; input.uri = "https://fixture.invalid/Release";
    input.temporaryParent = "/fixture/tmp"; input.maximumBytes = 1024; return input;
}
void CompleteDispatch() {
    Peer peer(Mode::Complete); A::AcquireStatus ordinary, update;
    bool executed(false), closed(false); int statusFd(-1); A::AcquireStatus *status(nullptr);
    std::vector<std::pair<A::AcquireStatus *, int>> contexts;
    A::RemoteBackendOptions options; options.status = &ordinary;
    options.operationContext = [&](A::AcquireStatus *selected, int descriptor) {
        status = selected; statusFd = descriptor; contexts.push_back({selected, descriptor});
    };
    {
        auto session(Session(peer, &executed, &closed));
        A::AptBackend backend(std::move(session), options);
        backend.reset(); backend.createCacheViews(); Require(backend.loadSources() && backend.openCache(), "cache lifecycle");
        Require(backend.drainErrors().front().warning, "upstream structured diagnostics"); backend.discardErrors();
        Require(backend.cacheState().installs == 4, "cache summary");
        Require(backend.applyStatus() && backend.fixBroken() && backend.minimizeUpgrade() && backend.cleanArchives(), "status and maintenance methods");
        const A::PackageHandle package(7); const A::SourceHandle source(9);
        Require(backend.packageHandles().front().value == 7 && backend.lookupPackage("fixture:foreign", "foreign").handle.value == 7 &&
            backend.packageHandle("fixture:foreign", "foreign").value == 7, "package lookup methods");
        Require(backend.downgradeHandles(package).front().value == 8 && backend.versionHandles(package).front().value == 8, "version methods");
        Require(backend.packageSnapshot(package).architecture == "foreign" && backend.recordData(package).Field("Architecture") == "foreign" &&
            backend.packageState(package).installedVersion && backend.relations(package).front().clauses.front().providers.front().value == 8, "package value methods");
        Require(backend.resolveDependencies() && backend.prepareDistUpgrade() && backend.clearPackage(package) &&
            backend.installPackage(package) && backend.reinstallPackage(package) && backend.removePackage(package, true), "selection methods");
        backend.clearSelections();
        P::ReviewedTransaction review;
        Require(!backend.providerReview(&review), "no review invented before transactionData");
        Require(backend.transactionData().installs.front() == "fixture:foreign" && backend.providerReview(&review), "full accepted review retained");
        Require(backend.installPackage(package) && !backend.providerReview(&review), "selection changes invalidate exposed review");
        backend.transactionData(); Require(backend.lockForTransaction() && backend.prepareArchives(), "reviewed archive preparation");
        Require(backend.sourceList().success && backend.autoInstalledDeltas().front().architecture == "foreign", "source list and automatic state");
        const auto fetch(backend.runFetcher(13));
        Require(fetch.completed && fetch.warnings.front().kind == A::FetchDiagnosticKind::UnsignedRepository, "typed acquisition diagnostics");
        A::FetchResultData archives; bool started(false);
        Require(backend.runPackageManager(42, &archives, &started) == A::PackageManagerResult::Completed && started && executed && archives.completed,
            "package manager return and execution status");
        Require(!backend.providerReview(&review), "execution invalidates exposed review");
        backend.unlockForTransaction();
        Require(backend.updateLists(update, 17).metadataComplete, "update result");
        Require(status == nullptr && statusFd == -1, "operation context cleared after completion");
        Require(std::find(contexts.begin(), contexts.end(), std::make_pair(&ordinary, 42)) != contexts.end() &&
            std::find(contexts.begin(), contexts.end(), std::make_pair(&update, -1)) != contexts.end(),
            "coordinator receives the active status object and app-local execution descriptor");
        Require(backend.sourceHandles().front().value == 9 && backend.sourceSnapshot(source).label == "Fixture" &&
            backend.sourceField(source, "Origin") == "fixture-origin" && backend.sourceFileIDs(source).front() == 23, "source methods");
        const auto checked(backend.sourcePreflight(SourceCheck()));
        Require(checked.status == A::SourceCheckStatus::Complete && checked.allowed &&
            checked.architecture == A::SourceArchitectureAvailability::Supported &&
            checked.warnings.front().kind == A::FetchDiagnosticKind::UnsignedRepository, "preflight preserves typed policy results");
        const auto resource(backend.sourceResource(SourceResource()));
        Require(resource.status == A::SourceCheckStatus::Complete && resource.bytes == "fixture metadata", "resource bytes from the same provider");
        Require(backend.providerFailure().code.empty(), "no transport failures for complete facade dispatch");
    }
    Require(closed, "facade owns and closes the injected session");
    peer.thread.join();
    for (unsigned operation(static_cast<unsigned>(P::Operation::Reset)); operation <= static_cast<unsigned>(P::Operation::SourceResource); ++operation)
        Require(peer.seen.count(static_cast<P::Operation>(operation)) == 1, "every facade operation reaches the same provider");
}
void SourceBoundaries() {
    {
        Peer peer(Mode::SourceStatuses); A::AptBackend backend(Session(peer));
        Require(backend.sourcePreflight(SourceCheck()).status == A::SourceCheckStatus::TimedOut &&
            backend.sourceResource(SourceResource()).status == A::SourceCheckStatus::SizeLimit,
            "worker source statuses are retained independently of the response envelope");
    }
    {
        Peer peer(Mode::SourceBudget); A::RemoteBackendOptions options; options.requestTimeoutMilliseconds = 1;
        A::AptBackend backend(Session(peer), options);
        Require(backend.sourceResource(SourceResource()).status == A::SourceCheckStatus::Complete,
            "source-specific acquisition budget replaces the short ordinary request deadline");
    }
    {
        Peer peer(Mode::Complete); A::AptBackend backend(Session(peer));
        const auto cancelled(backend.sourcePreflight(SourceCheck(), []() { return true; }));
        Require(cancelled.status == A::SourceCheckStatus::Cancelled && cancelled.errors.size() == 1 &&
            cancelled.errors.front().message.empty() && cancelled.errors.front().cydiaCode == "provider_cancelled",
            "explicit source cancellation is forwarded before sending");
        Require(backend.sourceResource(SourceResource()).status == A::SourceCheckStatus::Complete,
            "pre-send cancellation keeps the same provider usable");
    }
    {
        Peer peer(Mode::CancelSource); A::AptBackend backend(Session(peer)); const auto started(Clock::now());
        Require(backend.sourceResource(SourceResource(), [&]() {
            return Clock::now() - started >= std::chrono::milliseconds(20);
        }).status == A::SourceCheckStatus::Cancelled && !backend.providerFailure().indeterminate,
            "in-flight source cancellation settles and retains its typed status");
    }
    {
        Peer peer(Mode::Complete); A::RemoteBackendOptions options; options.cancelled = []() { return true; };
        A::AptBackend backend(Session(peer), options);
        Require(backend.sourceResource(SourceResource()).status == A::SourceCheckStatus::Cancelled,
            "coordinator cancellation also applies to source operations");
    }
}
void CancellationAndExecutionState() {
    {
        Peer peer(Mode::DeniedRelease); bool locked(false), closed(false);
        A::AptBackend backend(Session(peer, nullptr, &closed, &locked));
        backend.reset(); backend.transactionData(); Require(backend.lockForTransaction() && locked, "denied release fixture lock");
        backend.unlockForTransaction();
        Require(closed && !locked && backend.providerFailure().code == "fixture_unlock_denied" && !backend.loadSources(),
            "failed void unlock closes the session for parent-owned lock reconciliation");
    }
    {
        Peer peer(Mode::CancelFetch); bool locked(false), cancelling(false); unsigned checks(0);
        A::RemoteBackendOptions options;
        options.cancelled = [&]() { return cancelling && ++checks >= 3; };
        A::AptBackend backend(Session(peer, nullptr, nullptr, &locked), options);
        backend.reset(); backend.transactionData(); Require(backend.lockForTransaction() && locked, "cancelled fetch fixture lock");
        cancelling = true;
        Require(!backend.runFetcher(13).completed && backend.providerFailure().code == "provider_cancelled", "fetch cancellation settles");
        Require(backend.drainErrors().front().message == "upstream diagnostic", "diagnostics drain while cancellation stays set");
        backend.unlockForTransaction(); Require(!locked, "parent lock releases while cancellation stays set");
        backend.discardErrors(); Require(backend.providerFailure().code.empty(), "bounded error cleanup also ignores stale cancellation");
    }
    {
        Peer peer(Mode::CancelManager); bool executed(false), locked(false); unsigned afterExecutionChecks(0);
        A::RemoteBackendOptions options;
        // First allow the executor's reply to reach the worker. Cancellation
        // then races only with the terminal package-manager response.
        options.cancelled = [&]() { return executed && ++afterExecutionChecks >= 3; };
        A::AptBackend backend(Session(peer, &executed, nullptr, &locked), options);
        backend.reset(); backend.transactionData(); Require(backend.lockForTransaction(), "settled cancellation fixture lock");
        bool started(false);
        Require(backend.runPackageManager(-1, nullptr, &started) == A::PackageManagerResult::Failed && started &&
            !backend.providerFailure().indeterminate && backend.providerFailure().code == "provider_cancelled",
            "settled cancellation retains this call's observed start without inventing uncertainty");
        backend.unlockForTransaction(); Require(!locked, "settled cancellation still permits lock cleanup");
    }
    {
        Peer peer(Mode::Complete); bool executing(false);
        A::RemoteBackendOptions options;
        options.operationContext = [&](A::AcquireStatus *status, int descriptor) {
            if (descriptor == 42) executing = true;
            else if (status == nullptr && executing) throw 1;
        };
        A::AptBackend backend(Session(peer), options);
        backend.reset(); backend.transactionData(); Require(backend.lockForTransaction(), "context failure fixture lock");
        bool started(false);
        Require(backend.runPackageManager(42, nullptr, &started) == A::PackageManagerResult::Failed && started &&
            !backend.providerFailure().indeterminate && backend.providerFailure().code == "provider_operation_callback_failed",
            "context cleanup failure cannot erase an acknowledged executor start");
    }
    {
        Peer peer(Mode::Complete); bool cancelling(false); A::RemoteBackendOptions options;
        options.cancelled = [&]() { return cancelling; };
        A::AptBackend backend(Session(peer), options);
        backend.reset(); backend.transactionData(); Require(backend.lockForTransaction(), "historical start fixture lock");
        bool started(false);
        Require(backend.runPackageManager(-1, nullptr, &started) == A::PackageManagerResult::Completed && started,
            "first transaction actually starts");
        backend.transactionData(); cancelling = true;
        Require(backend.runPackageManager(-1, nullptr, &started) == A::PackageManagerResult::Failed && !started,
            "historical mutation does not imply that a subsequently cancelled call started");
        backend.unlockForTransaction();
    }
}
void DiagnosticPrivacy() {
    Peer peer(Mode::SensitiveDiagnostics); A::AptBackend backend(Session(peer)); backend.reset();
    Require(backend.cacheState().installs == 0 && backend.providerFailure().code == "provider_request_failed",
        "untrusted URL/text error codes normalize before logging");
    const auto safe = [](const std::string &message) {
        return message.find("password") == std::string::npos && message.find("private-token") == std::string::npos &&
            message.find("secret=value") == std::string::npos && message.find("user:") == std::string::npos;
    };
    const auto errors(backend.drainErrors());
    Require(!errors.empty() && errors.front().message.find("fixture.invalid") != std::string::npos,
        "upstream diagnostic retains the safe origin");
    Require(errors.size() == 2 && errors.front().cydiaCode.empty() && errors.back().message.empty() &&
        errors.back().cydiaCode == "provider_request_failed", "worker cannot label upstream text as Cydia UI or erase a local failure");
    for (const auto &error : errors) Require(safe(error.message), "drained and queued errors contain no URL credentials");
    const auto checked(backend.sourcePreflight(SourceCheck()));
    Require(safe(checked.errors.front().message) && checked.errors.front().cydiaCode.empty() &&
        safe(checked.warnings.front().error) && safe(checked.warnings.front().uri),
        "preflight diagnostic messages and URIs are redacted before leaving the facade");
    const auto resource(backend.sourceResource(SourceResource()));
    Require(safe(resource.errors.front().message) && resource.errors.front().cydiaCode.empty() && resource.bytes == "fixture metadata",
        "resource diagnostics are redacted without modifying transport bytes");
}
void FailureBoundaries() {
    for (Mode mode : {Mode::FailedReply, Mode::MalformedValue, Mode::MalformedVoid, Mode::WrongHandle, Mode::Disconnect}) {
        Peer peer(mode); A::AptBackend backend(Session(peer)); backend.reset();
        if (mode == Mode::MalformedVoid) backend.createCacheViews();
        else if (mode == Mode::WrongHandle) Require(!backend.packageSnapshot(A::PackageHandle(7)).handle.valid(), "mismatched handle rejected");
        else Require(backend.cacheState().installs == 0, "failed or malformed values never leak through");
        const auto failure(backend.providerFailure());
        Require(!failure.code.empty() && !failure.indeterminate, "typed failure retained without invented effects");
        const auto errors(backend.drainErrors()); Require(!errors.empty(), "facade failure remains diagnosable");
        bool hasLocalDiagnostic(false);
        for (const auto &error : errors) {
            Require(error.message != failure.code, "facade machine code leaked into upstream diagnostic text");
            if (error.cydiaCode == failure.code && error.message.empty()) hasLocalDiagnostic = true;
        }
        Require(hasLocalDiagnostic, "facade failure lost its Cydia diagnostic identity");
        if (mode == Mode::FailedReply) {
            Require(errors.front().message == "upstream diagnostic" && errors.front().warning, "failed operation preserves upstream diagnostic queue");
            Require(backend.loadSources(), "ordinary provider errors do not change backends");
        } else {
            Require(!backend.loadSources() && backend.packageHandles().empty(), "lost/invalid session never falls back to embedded APT");
        }
    }
    {
        Peer peer(Mode::LostExecution); A::AptBackend backend(Session(peer)); backend.reset(); backend.transactionData();
        Require(backend.lockForTransaction(), "lost execution fixture lock"); bool started(false);
        Require(backend.runPackageManager(-1, nullptr, &started) == A::PackageManagerResult::Failed && started &&
            backend.providerFailure().indeterminate && !backend.loadSources(), "indeterminate execution cannot become an embedded retry");
    }
    {
        A::AptBackend backend{std::unique_ptr<P::Session>()};
        Require(!backend.openCache() && backend.providerFailure().code == "provider_session_unavailable", "null injection has no embedded fallback");
    }
    {
        Peer peer(Mode::Complete); A::AptBackend backend(Session(peer)); backend.reset();
        Require(backend.openCache() && !backend.packageHandles().empty(), "retirement fixture opened current provider");
        backend.retireProvider();
        Require(!backend.openCache() && backend.packageHandles().empty() && !backend.providerFailure().indeterminate,
            "settled provider retirement invalidates handles and cannot reuse or switch engines");
    }
}
void CandidatePreparation() {
    // Exercise the actual public facade and framed Session operation replies.
    // A source/cache refusal is distinct from protocol/process loss; candidate
    // preparation never mutates or retires an independently adopted backend.
    for (Mode mode : {Mode::SourceFalse, Mode::SourceRejected, Mode::SourceError, Mode::CacheFalse,
        Mode::CacheError, Mode::SourceMalformed, Mode::SourceDisconnect, Mode::Complete}) {
        Peer adoptedPeer(Mode::Complete), candidatePeer(mode);
        A::AptBackend adopted(Session(adoptedPeer)), candidate(Session(candidatePeer));
        Require(adopted.openCache(), "independent adopted backend has working cache");
        Require(adopted.installPackage(A::PackageHandle(7)), "adopted backend has a real queued selection");
        adopted.transactionData(); P::ReviewedTransaction originalReview;
        Require(adopted.providerReview(&originalReview), "adopted queue has an owned protocol review");
        std::string originalReviewBytes; Require(P::Encode(originalReview, &originalReviewBytes), "serialize original queued review");
        P::Binding original; Require(adopted.providerBinding(&original), "adopted provider binding retained");
        unsigned authorityReads = 0;
        const auto result(A::PrepareRuntimeProvider(candidate, [&] { ++authorityReads; return true; }));
        const auto expected = mode == Mode::Complete ? A::RuntimeAdmissionKind::Ready :
            mode == Mode::SourceMalformed || mode == Mode::SourceDisconnect ? A::RuntimeAdmissionKind::ProviderUnavailable :
            A::RuntimeAdmissionKind::PreparationFailed;
        Require(result.kind == expected, "validated operation refusal does not become broken-provider fallback");
        Require(authorityReads == (mode == Mode::Complete ? 1u : 0u), "no admission authority claim before successful preparation");
        P::Binding unchanged;
        Require(adopted.providerBinding(&unchanged) && P::SameBinding(original, unchanged) && adopted.cacheState().installs == 4,
            "failed candidate preparation preserves prior provider binding and usable cache");
        P::ReviewedTransaction preservedReview; std::string preservedReviewBytes;
        Require(adopted.providerReview(&preservedReview) && P::Encode(preservedReview, &preservedReviewBytes) &&
            preservedReviewBytes == originalReviewBytes,
            "candidate preparation preserves exact prior queued operations, revisions and review identity");
        P::Binding candidateBinding;
        Require(candidate.providerBinding(&candidateBinding) == (expected != A::RuntimeAdmissionKind::ProviderUnavailable),
            "actual Session liveness distinguishes operation errors from protocol/process failure");
        if (mode == Mode::SourceError || mode == Mode::CacheError)
            Require(std::any_of(result.errors.begin(), result.errors.end(), [](const A::ErrorData &error) {
                return !error.warning && error.message == "upstream diagnostic" && error.cydiaCode.empty();
            }), "upstream preparation diagnostics retained for original gettext display");
    }
    Peer peer(Mode::Complete); A::AptBackend candidate(Session(peer)); unsigned authorityReads = 0;
    const auto changed(A::PrepareRuntimeProvider(candidate, [&] { ++authorityReads; return false; }));
    P::Binding binding;
    Require(changed.kind == A::RuntimeAdmissionKind::AuthorityChanged && authorityReads == 1 && candidate.providerBinding(&binding),
        "fresh authority failure stops adoption without labelling a live provider broken");
    A::AptBackend unavailable{std::unique_ptr<P::Session>()};
    Require(A::PrepareRuntimeProvider(unavailable, [] { return true; }).kind == A::RuntimeAdmissionKind::ProviderUnavailable,
        "cold missing session cannot establish preparation or an active runtime");
}
} // namespace
int main() {
    CompleteDispatch(); FailureBoundaries(); SourceBoundaries(); CancellationAndExecutionState(); DiagnosticPrivacy(); CandidatePreparation();
    std::puts("[apt-backend-facade] complete remote dispatch, review lifetime and failure boundaries passed");
}
