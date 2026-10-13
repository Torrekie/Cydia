/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryWorker.hpp"
#include "Cydia/AptRecoveryTrust.hpp"
#include "Cydia/AptRecoveryInitialization.hpp"
#include "Cydia/AptNativeBackend.hpp"
#include "Cydia/AptProviderArchiveAuthorization.hpp"
#include "Cydia/AptProviderServerTransport.hpp"
#include "Cydia/AptWorkerAcquireStatus.hpp"
#include "Cydia/AptMessages.h"
#include <apt-pkg/hashes.h>
#include <apt-pkg/configuration.h>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <climits>
#include <clocale>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <poll.h>
#include <set>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

namespace CydiaAPT { namespace Recovery {
namespace {
namespace P = Provider;
using Clock = std::chrono::steady_clock;
volatile sig_atomic_t stopped = 0;
void Stop(int) { stopped = 1; }
struct Descriptor {
    int value;
    explicit Descriptor(int fd = -1) : value(fd) {}
    ~Descriptor() { if (value >= 0) close(value); }
};
bool SameFile(const struct stat &a, const struct stat &b) {
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_size != b.st_size ||
        a.st_uid != b.st_uid || a.st_gid != b.st_gid || a.st_mode != b.st_mode || a.st_nlink != b.st_nlink) return false;
#if defined(__APPLE__)
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
bool ReadCapsule(Snapshot *snapshot) {
    Descriptor capsule(3);
    struct stat before, after;
    const int flags(fcntl(capsule.value, F_GETFL));
    if (!snapshot || flags < 0 || (flags & O_ACCMODE) != O_RDONLY ||
        fcntl(capsule.value, F_SETFD, FD_CLOEXEC) < 0 || fstat(capsule.value, &before) ||
        !S_ISREG(before.st_mode) || before.st_nlink != 0 || (before.st_mode & 0077) ||
        (before.st_uid != 0 && before.st_uid != geteuid()) || before.st_size <= 0 ||
        static_cast<std::uint64_t>(before.st_size) > MaximumSnapshotBytes) return false;
    std::string bytes(static_cast<std::size_t>(before.st_size), '\0');
    std::size_t offset = 0;
    while (offset != bytes.size()) {
        if (stopped) return false;
        const auto size(pread(capsule.value, &bytes[offset], bytes.size() - offset, offset));
        if (size < 0 && errno == EINTR) continue;
        if (size <= 0) return false;
        offset += size;
    }
    return fstat(capsule.value, &after) == 0 && SameFile(before, after) && ParseSnapshot(bytes, snapshot);
}
std::string ExecutablePath() {
    char path[PATH_MAX + 1];
#if defined(__APPLE__)
    std::uint32_t size(sizeof(path));
    if (_NSGetExecutablePath(path, &size) != 0) return {};
#else
    const auto size(readlink("/proc/self/exe", path, sizeof(path) - 1));
    if (size <= 0 || static_cast<std::size_t>(size) >= sizeof(path) - 1) return {};
    path[size] = '\0';
#endif
    char resolved[PATH_MAX + 1];
    return realpath(path, resolved) ? resolved : std::string();
}
bool ComponentsUnchanged(const Snapshot &snapshot, Clock::time_point deadline) {
    char executable[PATH_MAX + 1];
    if (!realpath(snapshot.executable.c_str(), executable) || ExecutablePath() != executable) return false;
    std::size_t total = 0;
    for (const auto &component : snapshot.components) {
        CydiaRuntime::Privileged::Error error;
        if (stopped || Clock::now() >= deadline || !CydiaRuntime::Privileged::ValidateRootOwnedPath(
                component.path, false, component.executable, &error)) return false;
        Descriptor fd(open(component.path.c_str(), O_RDONLY | O_CLOEXEC));
        struct stat before, after, current;
        if (fd.value < 0 || fstat(fd.value, &before) || !S_ISREG(before.st_mode) || before.st_uid ||
            (before.st_mode & 0022) || before.st_size < 0 || before.st_size > 128 * 1024 * 1024) return false;
        Hashes hash(Hashes::SHA256SUM); char bytes[32768]; std::size_t offset = 0;
        for (;;) {
            if (stopped || Clock::now() >= deadline) return false;
            const auto size(read(fd.value, bytes, sizeof(bytes)));
            if (size < 0 && errno == EINTR) continue;
            if (size < 0) return false;
            if (size == 0) break;
            offset += size; total += size;
            if (offset > 128 * 1024 * 1024 || total > 512 * 1024 * 1024 || !hash.Add(bytes, size)) return false;
        }
        if (offset != static_cast<std::size_t>(before.st_size) || fstat(fd.value, &after) ||
            stat(component.path.c_str(), &current) || !SameFile(before, after) || !SameFile(before, current) ||
            hash.GetHashString(Hashes::SHA256SUM).HashValue() != component.sha256) return false;
    }
    return true;
}
bool Wait(int fd, short events, Clock::time_point deadline) {
    while (!stopped) {
        const auto left(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count());
        if (left <= 0) return false;
        struct pollfd item = {fd, events, 0};
        const int count(poll(&item, 1, static_cast<int>(std::min<decltype(left)>(left, 100))));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return false;
        if (count && (item.revents & events)) return true;
        if (count && (item.revents & (POLLERR | POLLHUP | POLLNVAL))) return false;
    }
    return false;
}
bool ProbeFrame(const P::Info &info, Clock::time_point deadline) {
    for (int fd : {STDIN_FILENO, STDOUT_FILENO}) {
        const int flags(fcntl(fd, F_GETFL));
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return false;
    }
    P::ServerFrameReader reader; std::string frame; bool complete = false; std::size_t total = 0;
    while (!complete) {
        if (!Wait(STDIN_FILENO, POLLIN, deadline)) return false;
        char bytes[4096]; const auto size(read(STDIN_FILENO, bytes, sizeof(bytes)));
        if (size < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (size <= 0) return false;
        total += size; if (total > 256 * 1024) return false;
        std::size_t consumed = 0;
        if (!reader.Push(bytes, size, &consumed, &frame, &complete) || consumed != static_cast<std::size_t>(size) ||
            frame.size() > 256 * 1024) return false;
    }
    P::Message request; P::Environment expected;
    if (!P::DecodeFrame(frame, &request) || request.kind != P::MessageKind::Request ||
        request.sequence != 1 || request.operation != P::Operation::Hello || request.succeeded ||
        !request.errorCode.empty() || !P::SameBinding(request.binding, P::Binding()) ||
        !P::Decode(request.payload, &expected) || !P::SameEnvironment(expected, info.environment)) return false;
    P::Message reply; reply.kind = P::MessageKind::Response; reply.sequence = 1;
    reply.operation = P::Operation::Hello; reply.succeeded = true;
    if (!P::Encode(info, &reply.payload) || !P::EncodeFrame(reply, &frame)) return false;
    std::size_t offset = 0;
    while (offset != frame.size()) {
        if (!Wait(STDOUT_FILENO, POLLOUT, deadline)) return false;
        const auto size(write(STDOUT_FILENO, frame.data() + offset, frame.size() - offset));
        if (size < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (size <= 0) return false;
        offset += size;
    }
    return true;
}
int SessionSocket() {
    struct stat input, output; int type = 0; socklen_t size = sizeof(type);
    struct sockaddr_un peer; socklen_t peerSize = sizeof(peer);
    if (fstat(STDIN_FILENO, &input) || fstat(STDOUT_FILENO, &output) || !S_ISSOCK(input.st_mode) ||
        input.st_dev != output.st_dev || input.st_ino != output.st_ino ||
        getsockopt(STDIN_FILENO, SOL_SOCKET, SO_TYPE, &type, &size) || type != SOCK_STREAM ||
        getpeername(STDIN_FILENO, reinterpret_cast<sockaddr *>(&peer), &peerSize) || peer.sun_family != AF_UNIX) return -1;
    const int fd(fcntl(STDIN_FILENO, F_DUPFD, 4));
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { close(fd); return -1; }
    Descriptor sink(open("/dev/null", O_RDWR | O_CLOEXEC));
    if (sink.value < 0 || dup2(sink.value, STDIN_FILENO) < 0 || dup2(sink.value, STDOUT_FILENO) < 0) {
        close(fd); return -1;
    }
    return fd;
}
bool Cancelled(const P::ServerRequestContext &context) {
    return stopped || (context.control.cancelled && context.control.cancelled()) ||
        (context.control.remainingMilliseconds && !context.control.remainingMilliseconds());
}
// Bound argv including terminators and pointer slots below Darwin's exec limit.
// Preserve contiguous libapt operations; combining nonadjacent operations would
// move effects across Pre-Depends/configuration barriers. The parent validates
// the exact action IDs and operands again before each batch.
constexpr std::size_t MaximumBatchBytes = 32 * 1024;
constexpr std::size_t MaximumBatchActions = 1024;
bool ArgumentBytes(const std::string &argument, std::size_t *bytes) {
    if (argument.empty() || argument.find('\0') != std::string::npos || argument.size() > MaximumBatchBytes) return false;
    const auto size(argument.size() + 1 + sizeof(char *));
    if (size > MaximumBatchBytes || *bytes > MaximumBatchBytes - size) return false;
    *bytes += size; return true;
}
bool PlanBatches(const RuntimeDescriptor &runtime, const P::ReviewedTransaction &review,
    const P::ServerRequestContext &context, const std::set<std::string> &preDependsArchives,
    std::vector<P::ParentExecutionRequest> *batches) {
    if (review.execution.actions.size() > P::MaximumCollectionItems ||
        review.execution.archives.size() > P::MaximumCollectionItems ||
        preDependsArchives.size() > P::MaximumCollectionItems ||
        runtime.dpkgOptions.size() > MaximumBatchActions) return false;
    std::set<std::uint64_t> identifiers;
    std::map<std::string, const P::ArchiveManifest *> archives;
    for (const auto &archive : review.execution.archives) {
        if (Cancelled(context) || !P::ValidIdentityToken(archive.identifier) ||
            !archives.emplace(archive.identifier, &archive).second) return false;
    }
    for (const auto &identifier : preDependsArchives)
        if (Cancelled(context) || !archives.count(identifier)) return false;
    bool triggersSeen = false;
    for (std::size_t next = 0; next < review.execution.actions.size();) {
        if (Cancelled(context)) return false;
        const auto kind(review.execution.actions[next].action);
        const char *verb = nullptr;
        switch (kind) {
            case P::ExecutionAction::Unpack: verb = "--unpack"; break;
            case P::ExecutionAction::Configure: verb = "--configure"; break;
            case P::ExecutionAction::Remove: verb = "--remove"; break;
            case P::ExecutionAction::Purge: verb = "--purge"; break;
            case P::ExecutionAction::Triggers: verb = "--triggers-only"; break;
            default: return false;
        }
        // The state verifier requires every fresh pending recipient in one
        // explicit trigger call. Splitting or moving trigger runs is unsafe.
        if (kind == P::ExecutionAction::Triggers) {
            if (triggersSeen) return false;
            triggersSeen = true;
        }
        P::ParentExecutionRequest request; request.binding = review.binding;
        request.batch = batches->size() + 1; request.action = kind;
        request.arguments = runtime.dpkgOptions;
        request.arguments.insert(request.arguments.end(), {"--status-fd=3", "--no-triggers"});
        if (kind == P::ExecutionAction::Remove || kind == P::ExecutionAction::Purge)
            request.arguments.insert(request.arguments.end(), {"--force-depends", "--abort-after=1"});
        request.arguments.insert(request.arguments.end(), {verb, "--"});
        std::size_t bytes = 256; // executable name and terminating argv pointer
        for (const auto &argument : request.arguments) if (!ArgumentBytes(argument, &bytes)) return false;
        while (next < review.execution.actions.size() && review.execution.actions[next].action == kind) {
            const auto &action(review.execution.actions[next]);
            std::string operand(action.package.package + ':' + action.package.architecture);
            if (kind == P::ExecutionAction::Unpack) {
                const auto archive(archives.find(action.archive));
                if (archive == archives.end()) return false;
                // An earlier unpack in this child can change the state that
                // a later Pre-Depends check observes. Retain that boundary
                // even when libapt recorded contiguous unpack operations.
                if (!request.actions.empty() && preDependsArchives.count(action.archive)) break;
                operand = archive->second->path;
            }
            std::size_t expanded = bytes;
            if (request.actions.size() == MaximumBatchActions || !ArgumentBytes(operand, &expanded)) {
                if (request.actions.empty() || kind == P::ExecutionAction::Triggers) return false;
                break;
            }
            if (!action.identifier || !identifiers.insert(action.identifier).second) return false;
            request.actions.push_back(action.identifier); request.arguments.push_back(std::move(operand));
            bytes = expanded; ++next;
        }
        batches->push_back(std::move(request));
    }
    return true;
}
} // namespace

Provider::PackageManagerReply ExecuteReviewedActions(const RuntimeDescriptor &runtime,
    const P::ReviewedTransaction &review, const std::vector<AutoInstalledDelta> &changes,
    const P::ServerRequestContext &context, const std::set<std::string> &preDependsArchives) {
    P::PackageManagerReply result;
    if (context.operation != P::Operation::RunPackageManager || !context.parentRequest ||
        !runtime.mutationEnvironmentValid || review.binding.review.empty()) return result;
    // Validate the complete plan before the first effect, including shapes
    // that cannot be split safely to fit the bounded parent execution channel.
    std::vector<P::ParentExecutionRequest> batches;
    if (!PlanBatches(runtime, review, context, preDependsArchives, &batches)) return result;
    for (const auto &request : batches) {
        if (Cancelled(context)) return result;
        std::string payload; P::Message reply; P::ParentExecutionReply execution;
        if (!P::Encode(request, &payload) || !context.parentRequest(P::Operation::ExecuteDpkg, payload, &reply) ||
            !reply.succeeded || !P::Decode(reply.payload, &execution)) return result;
        result.started = result.started || execution.started;
        if (!execution.started || execution.exitCode != 0 || execution.signal || execution.launchError) return result;
    }
    if (Cancelled(context)) return result;
    P::ExtendedStateRequest state; state.binding = review.binding; state.changes = changes;
    std::string payload; P::Message reply;
    if (!P::Encode(state, &payload) || !context.parentRequest(P::Operation::CommitExtendedState, payload, &reply) ||
        !reply.succeeded || !reply.payload.empty()) return result;
    result.result = PackageManagerResult::Completed;
    return result;
}

int RunWorker(int argc, char *argv[]) {
    if (argc != 2 || !argv || !argv[1] || geteuid() == 0 || getuid() != geteuid() || getgid() != getegid()) return 64;
    const bool probe(std::strcmp(argv[1], "--cydia-provider-info") == 0);
    if (!probe && std::strcmp(argv[1], "--cydia-provider-session") != 0) return 64;
    // The parent already converted its UI language to Unix locale variables.
    // A new process starts in C even when those variables are inherited.
    std::setlocale(LC_ALL, "");
    stopped = 0;
    struct sigaction action = {}; action.sa_handler = Stop; sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, nullptr) || sigaction(SIGINT, &action, nullptr)) return 70;
    signal(SIGPIPE, SIG_IGN);
    const auto deadline(Clock::now() + std::chrono::seconds(10));
    Snapshot snapshot; std::string error;
    if (!ReadCapsule(&snapshot) || !ComponentsUnchanged(snapshot, deadline)) return 78;
    CydiaConfigureAPTMessages("", "", CydiaRuntime::PackageDatabasePaths::Current().CydiaApplicationDirectory().c_str());
    if (!InitializeRecoverySnapshot(snapshot, &error) || stopped || Clock::now() >= deadline) return 78;
    P::Info info; info.availability = P::Availability::Ready;
    info.identifier = ProviderIdentifier(); info.implementationVersion = "cydia-apt-2.7.9";
    info.libraryIdentity = snapshot.identity.libraries; info.frontendIdentity = snapshot.identity.frontend;
    info.environment = SnapshotEnvironment(snapshot);
    info.capabilities = P::RequiredCapabilities | P::ExplicitSecurityOverrides | P::AuthorizedArchiveGrants | P::FiniteTriggerEffects;
    if (probe) return ProbeFrame(info, deadline) ? 0 : 76;
    P::ServerTransport transport(SessionSocket());
    if (!transport.valid()) return 76;
    P::WorkerAcquireStatus status;
    auto backend(Internal::CreateNativeBackend(status));
    P::ServerHooks hooks;
    RecoveryCaptureResult retained;
    const P::ServerRequestContext *active = nullptr;
    std::unique_ptr<P::ScopedWorkerArchiveAuthorization> authorization;
    WorkerTrustProof trust;
    bool finiteEffects = false;
    hooks.admit = [&](const P::Hello &hello, P::Info *accepted, std::string *code) {
        std::string a, b;
        if (!hello.registrationPath.empty() || !P::SameEnvironment(hello.expected, info.environment) ||
            !P::Encode(hello.options, &a) || !P::Encode(snapshot.startup, &b) || a != b) {
            *code = "recovery_environment_mismatch"; return false;
        }
        finiteEffects = hello.finiteTriggerEffects;
        *accepted = info; accepted->finiteTriggerEffects = finiteEffects; return true;
    };
    hooks.operationContext = [&](const P::ServerRequestContext *context) {
        authorization.reset(); active = context;
        if (context && (context->operation == P::Operation::Reset || context->operation == P::Operation::OpenCache))
            retained = RecoveryCaptureResult();
        status.SetCallbacks(context ? context->progress : std::function<bool(const P::ProgressEvent &)>(),
            context ? context->control.cancelled : std::function<bool()>());
        if (context && (context->operation == P::Operation::Reset || context->operation == P::Operation::OpenCache ||
            context->operation == P::Operation::PrepareArchives || context->operation == P::Operation::RunFetcher))
            SetCachedRepositoryTrustValid(trust.Matches(snapshot, context->control.cancelled));
        if (context && context->operation == P::Operation::RunFetcher && !retained.review.binding.review.empty())
            authorization.reset(new P::ScopedWorkerArchiveAuthorization(retained.review, *context, info.capabilities));
    };
    hooks.buildReview = [&](const TransactionData &transaction, const P::Binding &binding, P::ExecutionManifest *manifest, std::string *code) {
        retained = RecoveryCaptureResult();
        CydiaPackages::ArchiveLayout layout; layout.prefix = snapshot.runtime.packageInstallPrefix;
        if (layout.prefix == "/") layout.foreignPrefixes = {"/var/jb"};
        auto captured(backend->captureRecoveryReview(snapshot.runtime, binding, layout,
            active ? active->control.cancelled : std::function<bool()>(), finiteEffects));
        if (captured.status != RecoveryCaptureStatus::Recorded) { *code = captured.errorCode; return false; }
        std::string expected, actual;
        if (!P::Encode(transaction, &expected) || !P::Encode(captured.review.transaction, &actual) || expected != actual) {
            *code = "recovery_transaction_changed"; return false;
        }
        retained = std::move(captured); *manifest = retained.review.execution; return true;
    };
    hooks.updateLists = [&](int interval, const P::ServerRequestContext &context) {
        SetCachedRepositoryTrustValid(false);
        const auto before(trust.BeginRefresh(snapshot, context.control.cancelled));
        const auto result(backend->updateListsNative(interval));
        SetCachedRepositoryTrustValid(trust.CompleteRefresh(snapshot, before,
            result.success && result.metadataComplete && !Cancelled(context), context.control.cancelled));
        return result;
    };
    hooks.runPackageManager = [&](const P::ReviewedTransaction &review, const std::vector<AutoInstalledDelta> &changes,
            const P::ServerRequestContext &context) {
        std::string expected, actual;
        if (retained.status != RecoveryCaptureStatus::Recorded || !P::Encode(retained.review, &expected) ||
            !P::Encode(review, &actual) || expected != actual) return P::PackageManagerReply();
        return ExecuteReviewedActions(snapshot.runtime, review, changes, context, retained.preDependsArchives);
    };
    // Reconfiguration always requires a new independently captured capsule.
    // A supported request ends this process session; no stale policy is used.
    hooks.setSecurityMode = [](RepositorySecurityMode, const P::ServerRequestContext &) { return true; };
    hooks.refreshArchitectures = [](const P::ServerRequestContext &) { return true; };
    if (!transport.Attach(&hooks)) return 76;
    P::Server server(*backend, hooks);
    const auto result(transport.Serve(server, 3 * 60 * 60 * 1000, []() { return stopped != 0; }));
    return result == P::ServerTransportResult::EndOfStream || result == P::ServerTransportResult::Stopped ? 0 : 76;
}
}} // namespace CydiaAPT::Recovery

#if defined(CYDIA_RECOVERY_WORKER_MAIN)
int main_copy();
int main_file();
int main_gpgv();
int main_rred(int, const char *[]);
int main_store(int, char *[]);
int main_http(int, const char *[]);
int main(int argc, char *argv[]) {
    if (argc < 1 || !argv || !argv[0]) return 64;
    const char *name(std::strrchr(argv[0], '/')); name = name ? name + 1 : argv[0];
    const bool method(!std::strcmp(name, "copy") || !std::strcmp(name, "file") || !std::strcmp(name, "gpgv") ||
        !std::strcmp(name, "rred") || !std::strcmp(name, "store") || !std::strcmp(name, "http") || !std::strcmp(name, "https"));
    if (method) {
        // The owning worker sends its captured options through APT's method
        // protocol. Avoid merging another apt.conf into the child's defaults.
        if (!CydiaAPT::InitializeRecoveryMethodConfiguration()) return 78;
        std::setlocale(LC_ALL, "");
        CydiaConfigureAPTMessages("", "", CydiaRuntime::PackageDatabasePaths::Current().CydiaApplicationDirectory().c_str());
    }
    if (!std::strcmp(name, "copy")) return main_copy();
    if (!std::strcmp(name, "file")) return main_file();
    if (!std::strcmp(name, "gpgv")) return main_gpgv();
    if (!std::strcmp(name, "rred")) return main_rred(argc, const_cast<const char **>(argv));
    if (!std::strcmp(name, "store")) return main_store(argc, argv);
    if (!std::strcmp(name, "http") || !std::strcmp(name, "https")) return main_http(argc, const_cast<const char **>(argv));
    return CydiaAPT::Recovery::RunWorker(argc, argv);
}
#endif
