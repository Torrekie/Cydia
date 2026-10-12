/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderSession.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sstream>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

extern char **environ;

namespace CydiaAPT { namespace Provider {
namespace {
using Clock = std::chrono::steady_clock;
using Deadline = Clock::time_point;
constexpr unsigned CancellationGraceMilliseconds = 2000;
constexpr unsigned MaximumRequestMilliseconds = 3 * 60 * 60 * 1000;

unsigned Remaining(Deadline deadline) {
    const auto remaining(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count());
    return remaining <= 0 ? 0 : static_cast<unsigned>(std::min<decltype(remaining)>(remaining, UINT_MAX));
}

std::string Identity(const struct stat &value) {
    std::ostringstream result;
    result << value.st_dev << ':' << value.st_ino << ':' << value.st_size << ':' << value.st_mode;
#if defined(__APPLE__)
    result << ':' << value.st_mtimespec.tv_sec << ':' << value.st_mtimespec.tv_nsec
           << ':' << value.st_ctimespec.tv_sec << ':' << value.st_ctimespec.tv_nsec;
#else
    result << ':' << value.st_mtim.tv_sec << ':' << value.st_mtim.tv_nsec
           << ':' << value.st_ctim.tv_sec << ':' << value.st_ctim.tv_nsec;
#endif
    return result.str();
}

bool Challenge(std::string *challenge) {
    unsigned char bytes[32];
#if defined(__APPLE__)
    arc4random_buf(bytes, sizeof(bytes));
#else
    const int random(open("/dev/urandom", O_RDONLY | O_CLOEXEC));
    if (random < 0) return false;
    size_t offset(0);
    while (offset != sizeof(bytes)) {
        const ssize_t count(read(random, bytes + offset, sizeof(bytes) - offset));
        if (count > 0) offset += count;
        else if (count < 0 && errno == EINTR) continue;
        else { close(random); return false; }
    }
    close(random);
#endif
    static const char hex[] = "0123456789abcdef";
    challenge->clear();
    for (unsigned char byte : bytes) {
        challenge->push_back(hex[byte >> 4]); challenge->push_back(hex[byte & 15]);
    }
    return true;
}

bool SameBaseBinding(const Binding &left, const Binding &right) {
    return left.providerIdentifier == right.providerIdentifier && left.session == right.session &&
        left.configurationIdentity == right.configurationIdentity && left.policyIdentity == right.policyIdentity &&
        left.packageStateIdentity == right.packageStateIdentity;
}

bool ChangesSelection(Operation operation) {
    switch (operation) {
        case Operation::ApplyStatus: case Operation::FixBroken: case Operation::MinimizeUpgrade:
        case Operation::ResolveDependencies: case Operation::ClearSelections: case Operation::PrepareDistUpgrade:
        case Operation::ClearPackage: case Operation::InstallPackage: case Operation::ReinstallPackage:
        case Operation::RemovePackage: return true;
        default: return false;
    }
}

bool ReviewedOperation(Operation operation) {
    return operation == Operation::PrepareArchives || operation == Operation::RunFetcher ||
        operation == Operation::RunPackageManager;
}

bool ParentOperationAllowed(Operation parent, Operation active, bool locked) {
    switch (parent) {
        case Operation::AcquireFrontendLock: return active == Operation::LockForTransaction && !locked;
        case Operation::ReleaseFrontendLock: return active == Operation::UnlockForTransaction && locked;
        case Operation::ExecuteDpkg: case Operation::CommitExtendedState:
            return active == Operation::RunPackageManager && locked;
        case Operation::CaptureStateSnapshot: return active != Operation::Hello;
        default: return false;
    }
}

// POSIX_SPAWN_CLOEXEC_DEFAULT prevents unrelated app descriptors reaching the
// adapter on Darwin. The non-Darwin test path explicitly closes its snapshot.
int CloseOtherDescriptors(posix_spawn_file_actions_t *actions, int channel) {
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    return posix_spawn_file_actions_addclose(actions, channel);
#else
    (void)channel; // The descriptor snapshot includes the channel on Linux.
    DIR *directory(opendir("/proc/self/fd"));
    if (directory == nullptr) return errno;
    const int enumeration(dirfd(directory));
    std::vector<int> descriptors;
    while (dirent *entry = readdir(directory)) {
        char *end(nullptr);
        const long value(strtol(entry->d_name, &end, 10));
        if (end != entry->d_name && *end == '\0' && value > STDERR_FILENO && value <= INT_MAX && value != enumeration)
            descriptors.push_back(static_cast<int>(value));
    }
    closedir(directory);
    for (int descriptor : descriptors) {
        const int error(posix_spawn_file_actions_addclose(actions, descriptor));
        if (error != 0) return error;
    }
    return 0;
#endif
}

void ReapAfterTermination(pid_t child) {
    int status;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
}
} // namespace

class Session::Implementation {
public:
    int channel = -1;
    pid_t child = -1;
    Binding current;
    Info provider;
    Environment approvedEnvironment;
    SessionCallbacks callbacks;
    std::string error, incoming;
    std::uint64_t nextSequence = 1, lastParentSequence = 0;
    bool ready = false, busy = false, uncertain = false, mutated = false, locked = false;
    // Historical mutation prohibits restarting this object. Only unsettled
    // effects make a later transport failure an indeterminate transaction.
    bool pendingEffects = false, executionStarted = false, unknownEffects = false;
    bool notifyClosed = false;

    void Stop() {
        uncertain = uncertain || pendingEffects;
        ready = false;
        if (channel >= 0) { close(channel); channel = -1; }
        if (child > 0) {
            // Only this unprivileged adapter's private group is terminated.
            // The app's cydo/dpkg children are not descendants of this group.
            (void) kill(-child, SIGKILL);
            (void) kill(child, SIGKILL);
            const pid_t terminated(child); child = -1;
            const Deadline deadline(Clock::now() + std::chrono::milliseconds(100));
            int status;
            for (;;) {
                const pid_t waited(waitpid(terminated, &status, WNOHANG));
                if (waited == terminated || (waited < 0 && errno == ECHILD)) break;
                if (Remaining(deadline) == 0) {
                    // Keep a stuck kernel wait out of the UI/transport deadline.
                    // This one-shot reaper owns only the unreaped child PID.
                    std::thread(ReapAfterTermination, terminated).detach();
                    break;
                }
                (void) poll(nullptr, 0, 5);
            }
        }
        incoming.clear();
        if (notifyClosed) {
            notifyClosed = false;
            if (callbacks.closed) { try { callbacks.closed(uncertain); } catch (...) {} }
        }
    }

    bool Fail(const char *code, bool disconnect = true) {
        error = code;
        if (disconnect) { uncertain = uncertain || pendingEffects; Stop(); }
        return false;
    }

    bool Launch(const std::string &path) {
        int sockets[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) return Fail("provider_channel_failed", false);
        // Do not allow dup2/stdin collisions when Cydia inherited closed stdio.
        for (unsigned i(0); i != 2; ++i) {
            if (sockets[i] <= STDERR_FILENO) {
                const int moved(fcntl(sockets[i], F_DUPFD, 3));
                close(sockets[i]); sockets[i] = moved;
            }
            if (sockets[i] < 0 || fcntl(sockets[i], F_SETFD, FD_CLOEXEC) != 0) {
                for (int descriptor : sockets) if (descriptor >= 0) close(descriptor);
                return Fail("provider_channel_failed", false);
            }
        }
#ifdef SO_NOSIGPIPE
        const int one(1);
        if (setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0) {
            close(sockets[0]); close(sockets[1]); return Fail("provider_channel_failed", false);
        }
#endif
        posix_spawn_file_actions_t actions;
        int result(posix_spawn_file_actions_init(&actions));
        if (result != 0) { close(sockets[0]); close(sockets[1]); return Fail("provider_spawn_failed", false); }
        result = posix_spawn_file_actions_adddup2(&actions, sockets[1], STDIN_FILENO);
        if (result == 0) result = posix_spawn_file_actions_adddup2(&actions, sockets[1], STDOUT_FILENO);
        if (result == 0) result = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        if (result == 0) result = CloseOtherDescriptors(&actions, sockets[1]);
        posix_spawnattr_t attributes;
        bool attributesReady(false);
        if (result == 0) { result = posix_spawnattr_init(&attributes); attributesReady = result == 0; }
        if (result == 0) result = posix_spawnattr_setpgroup(&attributes, 0);
        short flags(POSIX_SPAWN_SETPGROUP);
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
        if (result == 0) result = posix_spawnattr_setflags(&attributes, flags);
        std::vector<std::string> environment;
        for (char **entry(environ); entry != nullptr && *entry != nullptr; ++entry) {
            const std::string value(*entry);
            if (value.compare(0, 5, "DYLD_") != 0 && value.compare(0, 11, "LD_PRELOAD=") != 0 &&
                value.compare(0, 16, "LD_LIBRARY_PATH=") != 0) environment.push_back(value);
        }
        std::vector<char *> env;
        for (std::string &value : environment) env.push_back(&value[0]);
        env.push_back(nullptr);
        char *arguments[] = {const_cast<char *>(path.c_str()), const_cast<char *>("--cydia-provider-session"), nullptr};
        if (result == 0) result = posix_spawn(&child, path.c_str(), &actions, &attributes, arguments, env.data());
        if (attributesReady) posix_spawnattr_destroy(&attributes);
        posix_spawn_file_actions_destroy(&actions);
        close(sockets[1]);
        if (result != 0) { close(sockets[0]); child = -1; return Fail("provider_spawn_failed", false); }
        channel = sockets[0];
        const int original(fcntl(channel, F_GETFL));
        if (original < 0 || fcntl(channel, F_SETFL, original | O_NONBLOCK) != 0) return Fail("provider_channel_failed");
        return true;
    }

    bool Write(const Message &message, Deadline deadline,
               const std::function<bool()> &cancelled = std::function<bool()>()) {
        std::string bytes;
        if (!EncodeFrame(message, &bytes)) return Fail("provider_message_too_large");
        size_t offset(0);
        while (offset != bytes.size()) {
            if (Remaining(deadline) == 0) return Fail("provider_write_timeout");
            // A partially written frame cannot be followed by a Cancel frame.
            // Close the channel; pending parent effects remain indeterminate.
            if (cancelled && cancelled()) return Fail("provider_cancelled");
            int flags(0);
#ifdef MSG_NOSIGNAL
            flags |= MSG_NOSIGNAL;
#endif
            const ssize_t sent(send(channel, bytes.data() + offset, bytes.size() - offset, flags));
            if (sent > 0) { offset += static_cast<size_t>(sent); continue; }
            if (sent == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) return Fail("provider_disconnected");
            struct pollfd descriptor = {channel, POLLOUT, 0};
            if (poll(&descriptor, 1, std::min(Remaining(deadline), 25u)) < 0 && errno != EINTR)
                return Fail("provider_channel_failed");
        }
        return true;
    }

    // 1: message, 0: caller cancellation/deadline, -1: disconnected/invalid.
    int Read(Message *message, Deadline deadline, const std::function<bool()> &cancelled) {
        for (;;) {
            if (Remaining(deadline) == 0 || (cancelled && cancelled())) return 0;
            size_t target(8);
            if (incoming.size() >= 8) {
                if (incoming.compare(0, 4, "CYAP") != 0) { Fail("provider_invalid_frame"); return -1; }
                std::uint32_t length(0);
                for (unsigned i(4); i != 8; ++i) length = (length << 8) | static_cast<unsigned char>(incoming[i]);
                if (length == 0 || length > MaximumMessageBytes - 8) { Fail("provider_message_too_large"); return -1; }
                target += length;
            }
            if (incoming.size() == target && target > 8) {
                const bool decoded(DecodeFrame(incoming, message)); incoming.clear();
                if (!decoded) { Fail("provider_invalid_frame"); return -1; }
                return 1;
            }
            char buffer[8192];
            const ssize_t count(recv(channel, buffer, std::min(sizeof(buffer), target - incoming.size()), 0));
            if (count > 0) { incoming.append(buffer, static_cast<size_t>(count)); continue; }
            if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                Fail("provider_disconnected"); return -1;
            }
            struct pollfd descriptor = {channel, POLLIN, 0};
            if (poll(&descriptor, 1, std::min(Remaining(deadline), 25u)) < 0 && errno != EINTR) {
                Fail("provider_channel_failed"); return -1;
            }
        }
    }

    bool Reverse(const Message &request, Operation operation, const RequestControl &control,
                 bool cancelling, Deadline deadline) {
        if (!ValidRequestBinding(request) || !SameBinding(request.binding, current) ||
            request.sequence != lastParentSequence + 1 ||
            !ParentOperationAllowed(request.operation, operation, locked)) return Fail("provider_invalid_parent_request");
        ++lastParentSequence;
        const bool mutation(request.operation == Operation::ExecuteDpkg || request.operation == Operation::CommitExtendedState);
        if (mutation) {
            if (request.operation == Operation::ExecuteDpkg) {
                ParentExecutionRequest execution;
                if (!Decode(request.payload, &execution) || !SameBinding(execution.binding, current))
                    return Fail("provider_invalid_execution_request");
            } else {
                ExtendedStateRequest state;
                if (!Decode(request.payload, &state) || !SameBinding(state.binding, current))
                    return Fail("provider_invalid_state_request");
            }
        }
        Message response;
        if (cancelling && (mutation || request.operation == Operation::AcquireFrontendLock)) {
            response.errorCode = "provider_cancelled";
        } else if (!callbacks.parentRequest) {
            response.errorCode = "provider_parent_operation_unavailable";
        } else {
            const bool previouslyMutated(mutated), previouslyPending(pendingEffects);
            if (mutation) mutated = pendingEffects = true; // A failing callback can still have effects.
            try { callbacks.parentRequest(request, &response, control); }
            catch (...) { return Fail("provider_parent_operation_failed"); }
            if (request.operation == Operation::ExecuteDpkg && response.succeeded) {
                ParentExecutionReply execution;
                if (!Decode(response.payload, &execution)) return Fail("provider_invalid_parent_reply");
                mutated = previouslyMutated || execution.started;
                pendingEffects = previouslyPending || execution.started;
                executionStarted = executionStarted || execution.started;
            }
            if (mutation && !response.succeeded) unknownEffects = true;
            if (response.succeeded && request.operation == Operation::AcquireFrontendLock) locked = true;
            if (response.succeeded && request.operation == Operation::ReleaseFrontendLock) locked = false;
            if (response.succeeded && request.operation == Operation::CaptureStateSnapshot) {
                Environment snapshot;
                if (!Decode(response.payload, &snapshot) || !ValidEnvironment(snapshot))
                    return Fail("provider_invalid_parent_snapshot");
                Environment expected(approvedEnvironment);
                expected.packageStateIdentity = snapshot.packageStateIdentity;
                if (!SameEnvironment(expected, snapshot)) return Fail("provider_environment_changed");
                approvedEnvironment = std::move(snapshot);
            }
        }
        response.version = ProtocolVersion;
        response.kind = MessageKind::ParentResponse;
        response.sequence = request.sequence;
        response.operation = request.operation;
        response.binding = request.binding;
        // Once cancellation settlement begins, its writes use only the short
        // grace deadline. Re-observing cancellation would prevent settlement.
        return Write(response, deadline, cancelling ? std::function<bool()>() : control.cancelled);
    }

    bool Adopt(const Message &request, const Message &reply) {
        if (!reply.succeeded) {
            if (request.operation == Operation::RunPackageManager) {
                current.review.clear();
                if (pendingEffects) return Fail("provider_execution_outcome_unknown");
            }
            return true;
        }
        if (request.operation == Operation::Reset || request.operation == Operation::OpenCache) {
            CacheReply cache;
            if (!Decode(reply.payload, &cache)) return Fail("provider_invalid_cache_reply");
            if (request.operation == Operation::OpenCache && !cache.opened)
                return SameBinding(cache.binding, current) || Fail("provider_changed_failed_cache");
            Binding approved(current);
            approved.packageStateIdentity = approvedEnvironment.packageStateIdentity;
            if (locked || !SameBaseBinding(cache.binding, approved) || cache.binding.cacheEpoch <= current.cacheEpoch ||
                cache.binding.selectionRevision != 0 || !cache.binding.review.empty()) return Fail("provider_invalid_cache_binding");
            current = cache.binding;
        } else if (request.operation == Operation::TransactionData) {
            ReviewedTransaction reviewed;
            if (!Decode(reply.payload, &reviewed) || !SameBaseBinding(reviewed.binding, current) ||
                reviewed.binding.cacheEpoch != current.cacheEpoch ||
                reviewed.binding.selectionRevision != current.selectionRevision ||
                (!reviewed.binding.review.empty() && !ValidIdentityToken(reviewed.binding.review)))
                return Fail("provider_invalid_review_binding");
            current = reviewed.binding;
        } else if (ChangesSelection(request.operation)) {
            if (current.selectionRevision == UINT64_MAX) return Fail("provider_revision_exhausted");
            ++current.selectionRevision; current.review.clear();
        } else if (request.operation == Operation::LockForTransaction) {
            bool acquired(false);
            if (!Decode(reply.payload, &acquired) || acquired != locked) return Fail("provider_invalid_lock_reply");
        } else if (request.operation == Operation::UnlockForTransaction && locked) {
            return Fail("provider_lock_not_released");
        } else if (request.operation == Operation::RunPackageManager) {
            PackageManagerReply manager;
            if (!Decode(reply.payload, &manager) || manager.started != executionStarted)
                return Fail("provider_invalid_execution_reply");
            if (unknownEffects) return Fail("provider_execution_outcome_unknown");
            if (manager.result != PackageManagerResult::Incomplete) pendingEffects = false;
            // A new preview is required even for a partly completed transaction.
            current.review.clear();
        } else if (request.operation == Operation::SetSecurityMode || request.operation == Operation::RefreshArchitectures) {
            // Their new environment requires a fresh parent snapshot/probe.
            // Never keep a worker on a binding for its previous policy/arches.
            bool changed(false);
            if (!Decode(reply.payload, &changed)) return Fail("provider_invalid_environment_reply");
            if (changed) { current.review.clear(); error = "provider_reprobe_required"; Stop(); }
        }
        return true;
    }

    bool Exchange(const Message &request, Message *reply, Deadline deadline,
                  const std::function<bool()> &cancelled, bool handshake) {
        if (!Write(request, deadline, cancelled)) return false;
        bool cancelling(false), cancelAcknowledged(false), received(false);
        std::string cancellationReason;
        std::size_t receivedBytes(0);
        Message cancellation, result;
        const Deadline originalDeadline(deadline);
        RequestControl control;
        control.cancelled = [&]() { return cancelling || Remaining(originalDeadline) == 0 || (cancelled && cancelled()); };
        control.remainingMilliseconds = [&]() { return Remaining(originalDeadline); };
        for (unsigned count(0); count != 100000; ++count) {
            Message message;
            const int read(Read(&message, deadline, cancelling ? std::function<bool()>() : cancelled));
            if (read < 0) return false;
            if (read == 0) {
                if (cancelling) return Fail("provider_cancellation_unsettled");
                if (handshake) return Fail(Remaining(deadline) == 0 ? "provider_handshake_timeout" : "provider_cancelled");
                cancellationReason = Remaining(deadline) == 0 ? "provider_timeout" : "provider_cancelled";
                cancelling = true;
                deadline = Clock::now() + std::chrono::milliseconds(CancellationGraceMilliseconds);
                cancellation.sequence = nextSequence++;
                cancellation.operation = Operation::Cancel;
                cancellation.binding = current;
                if (!Encode(request.sequence, &cancellation.payload) || !Write(cancellation, deadline)) return false;
                continue;
            }
            receivedBytes += message.payload.size() + 4096;
            if (receivedBytes > 256u * 1024u * 1024u) return Fail("provider_message_limit");
            if (message.kind == MessageKind::Response) {
                if (cancelling && message.sequence == cancellation.sequence) {
                    if (cancelAcknowledged || !ValidateReply(cancellation, message) || !message.succeeded)
                        return Fail("provider_invalid_cancel_reply");
                    cancelAcknowledged = true;
                } else {
                    if (received || !ValidateReply(request, message)) return Fail("provider_invalid_reply");
                    result = std::move(message); received = true;
                }
                if (received && (!cancelling || cancelAcknowledged)) {
                    if (!handshake && !Adopt(request, result)) return false;
                    *reply = std::move(result);
                    if (cancelling) { error = cancellationReason; return false; }
                    if (ready || handshake)
                        error = reply->succeeded ? "" : (reply->errorCode.empty() ? "provider_request_failed" : reply->errorCode);
                    return true;
                }
            } else if (message.kind == MessageKind::Event) {
                ProgressEvent progress;
                if (handshake || message.sequence != request.sequence || message.operation != Operation::Progress ||
                    !SameBinding(message.binding, current) || !Decode(message.payload, &progress))
                    return Fail("provider_invalid_progress");
                if (callbacks.progress) {
                    try { callbacks.progress(progress); }
                    catch (...) { return Fail("provider_progress_callback_failed"); }
                }
            } else if (message.kind == MessageKind::ParentRequest && !handshake) {
                if (!Reverse(message, request.operation, control, cancelling, deadline)) return false;
            } else return Fail("provider_unexpected_message");
        }
        return Fail("provider_message_limit");
    }
};

Session::Session() : implementation_(new Implementation) {}
Session::~Session() { implementation_->Stop(); }

bool Session::Start(const std::string &executable, const ProbeResult &probe, Hello hello,
                    const SessionCallbacks &callbacks, unsigned timeoutMilliseconds,
                    const std::function<bool()> &cancelled) {
    Implementation &state(*implementation_);
    if (state.busy || state.child > 0 || state.ready || state.mutated || state.locked) return state.Fail("provider_session_already_started", false);
    if (cancelled && cancelled()) return state.Fail("provider_cancelled", false);
    if (timeoutMilliseconds == 0 || timeoutMilliseconds > 10000 || !probe.compatible() ||
        !Compatible(probe.info, hello.expected, nullptr) || !Challenge(&hello.challenge) || !ValidHello(hello))
        return state.Fail("provider_invalid_session", false);
    CydiaRuntime::Privileged::Error pathError;
    struct stat identity;
    if (!CydiaRuntime::Privileged::ValidateRootOwnedPath(executable, false, true, &pathError) ||
        stat(executable.c_str(), &identity) != 0 || Identity(identity) != probe.executableIdentity)
        return state.Fail("provider_changed_since_probe", false);
    state.callbacks = callbacks;
    state.notifyClosed = true;
    state.current = Binding();
    state.current.providerIdentifier = probe.info.identifier;
    state.current.session = hello.challenge;
    state.current.configurationIdentity = hello.expected.configurationIdentity;
    state.current.policyIdentity = hello.expected.policyIdentity;
    state.current.packageStateIdentity = hello.expected.packageStateIdentity;
    state.approvedEnvironment = hello.expected;
    state.nextSequence = 2; state.lastParentSequence = 0; state.locked = false;
    if (!state.Launch(executable)) { state.Stop(); return false; }
    if (stat(executable.c_str(), &identity) != 0 || Identity(identity) != probe.executableIdentity)
        return state.Fail("provider_changed_during_launch");
    Message request, reply;
    request.sequence = 1; request.operation = Operation::Hello; request.binding = state.current;
    if (!Encode(hello, &request.payload)) return state.Fail("provider_invalid_session");
    state.busy = true;
    const bool exchanged(state.Exchange(request, &reply, Clock::now() + std::chrono::milliseconds(timeoutMilliseconds), cancelled, true));
    state.busy = false;
    Info info;
    if (!exchanged) return false;
    if (!ValidateHelloReply(hello, reply, &info) || reply.binding.cacheEpoch != 0 ||
        info.identifier != probe.info.identifier || info.implementationVersion != probe.info.implementationVersion ||
        info.libraryIdentity != probe.info.libraryIdentity || info.frontendIdentity != probe.info.frontendIdentity ||
        info.capabilities != probe.info.capabilities) return state.Fail("provider_changed_since_probe");
    state.provider = std::move(info);
    state.ready = true;
    return true;
}

bool Session::Call(Operation operation, const std::string &payload, Message *reply,
                   unsigned timeoutMilliseconds, const std::function<bool()> &cancelled) {
    Implementation &state(*implementation_);
    if (!state.ready || state.busy || reply == nullptr) return state.Fail("provider_session_unavailable", false);
    state.executionStarted = false;
    if (timeoutMilliseconds == 0 || timeoutMilliseconds > MaximumRequestMilliseconds ||
        state.nextSequence >= UINT64_MAX - 1 || operation == Operation::Hello || operation == Operation::Cancel ||
        operation >= Operation::AcquireFrontendLock) return state.Fail("provider_invalid_request", false);
    if (cancelled && cancelled()) return state.Fail("provider_cancelled", false);
    Message request;
    request.sequence = state.nextSequence;
    request.operation = operation; request.binding = state.current; request.payload = payload;
    if (!ValidRequestBinding(request) || (ReviewedOperation(operation) && !state.locked))
        return state.Fail("provider_review_or_lock_required", false);
    if (state.locked && (operation == Operation::Reset || operation == Operation::OpenCache))
        return state.Fail("provider_cache_change_while_locked", false);
    if (ReviewedOperation(operation) && state.current.packageStateIdentity != state.approvedEnvironment.packageStateIdentity)
        return state.Fail("provider_package_state_changed", false);
    if ((operation == Operation::SetSecurityMode && (state.provider.capabilities & ExplicitSecurityOverrides) == 0))
        return state.Fail("provider_security_override_unsupported", false);
    ++state.nextSequence;
    state.busy = true;
    const bool success(state.Exchange(request, reply, Clock::now() + std::chrono::milliseconds(timeoutMilliseconds), cancelled, false));
    state.busy = false;
    return success;
}

void Session::Close() { implementation_->Stop(); }
bool Session::active() const { return implementation_->ready; }
bool Session::indeterminate() const { return implementation_->uncertain; }
bool Session::mutationStarted() const { return implementation_->mutated; }
bool Session::lastCallExecutionStarted() const { return implementation_->executionStarted; }
bool Session::parentLockHeld() const { return implementation_->locked; }
const Binding &Session::binding() const { return implementation_->current; }
const Info &Session::info() const { return implementation_->provider; }
const std::string &Session::lastError() const { return implementation_->error; }

#if defined(CYDIA_PROVIDER_SESSION_TESTING) && CYDIA_PROVIDER_SESSION_TESTING
bool Session::StartConnected(int descriptor, const Info &expected, Hello hello,
                            const SessionCallbacks &callbacks, unsigned timeoutMilliseconds,
                            const std::function<bool()> &cancelled) {
    Implementation &state(*implementation_);
    if (state.ready || state.busy || state.channel >= 0 || state.mutated || descriptor < 0) {
        if (descriptor >= 0) close(descriptor);
        return state.Fail("provider_invalid_session", false);
    }
    state.channel = descriptor;
    state.callbacks = callbacks; state.notifyClosed = true;
    const int flags(fcntl(descriptor, F_GETFL));
    if (timeoutMilliseconds == 0 || timeoutMilliseconds > 10000 || flags < 0 ||
        fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0 ||
        !Compatible(expected, hello.expected, nullptr) || !Challenge(&hello.challenge) || !ValidHello(hello))
        return state.Fail("provider_invalid_session");
#ifdef SO_NOSIGPIPE
    const int one(1);
    if (setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0)
        return state.Fail("provider_channel_failed");
#endif
    state.current = Binding();
    state.current.providerIdentifier = expected.identifier;
    state.current.session = hello.challenge;
    state.current.configurationIdentity = hello.expected.configurationIdentity;
    state.current.policyIdentity = hello.expected.policyIdentity;
    state.current.packageStateIdentity = hello.expected.packageStateIdentity;
    state.approvedEnvironment = hello.expected;
    state.nextSequence = 2; state.lastParentSequence = 0;
    Message request, reply;
    request.sequence = 1; request.binding = state.current;
    if (!Encode(hello, &request.payload)) return state.Fail("provider_invalid_session");
    state.busy = true;
    const bool exchanged(state.Exchange(request, &reply, Clock::now() + std::chrono::milliseconds(timeoutMilliseconds), cancelled, true));
    state.busy = false;
    Info info;
    if (!exchanged) return false;
    if (!ValidateHelloReply(hello, reply, &info) || reply.binding.cacheEpoch != 0 ||
        info.identifier != expected.identifier || info.implementationVersion != expected.implementationVersion ||
        info.libraryIdentity != expected.libraryIdentity || info.frontendIdentity != expected.frontendIdentity ||
        info.capabilities != expected.capabilities) return state.Fail("provider_changed_since_probe");
    state.provider = std::move(info); state.ready = true;
    return true;
}
#endif

}} // namespace CydiaAPT::Provider
