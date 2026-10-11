/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PrivilegedClient.h"
#include "Cydia/AptRuntime.hpp"
#include <apt-pkg/fileutl.h>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

extern char **environ;

namespace CydiaRuntime {
namespace PrivilegedClient {
namespace {
void Close(int &fd) { if (fd >= 0) close(fd); fd = -1; }

bool PrepareDescriptor(int &fd) {
    if (fd <= STDERR_FILENO) {
        int replacement = fcntl(fd, F_DUPFD, STDERR_FILENO + 1);
        if (replacement < 0) return false;
        close(fd); fd = replacement;
    }
    return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0;
}

bool MakePair(int pair[2], bool socket) {
    pair[0] = pair[1] = -1;
    if ((socket ? socketpair(AF_UNIX, SOCK_STREAM, 0, pair) : pipe(pair)) != 0)
        return false;
    if (!PrepareDescriptor(pair[0]) || !PrepareDescriptor(pair[1])) {
        const int saved = errno;
        Close(pair[0]); Close(pair[1]); errno = saved; return false;
    }
    return true;
}

Result Failed(int error) {
    Result result = {error, -1, 0, false, std::string(), std::string()};
    return result;
}

void Append(Result &result, std::string &destination, const char *bytes,
            std::size_t count, std::size_t limit) {
    const std::size_t used = result.output.size() + result.error.size();
    const std::size_t copy = std::min(count, limit > used ? limit - used : 0);
    destination.append(bytes, copy);
    if (copy != count) result.outputLimitExceeded = true;
}

Result RunInternal(const std::string &helperPath,
                   const std::vector<std::string> &arguments,
                   const Privileged::Request &request, std::size_t captureLimit,
                   unsigned timeoutMilliseconds = 0, int inheritedFd = -1) {
    const std::string input = Privileged::SerializeRequest(request);
    if (helperPath.empty() || helperPath.find('\0') != std::string::npos || input.empty() ||
        input.size() > 8 * 1024 * 1024)
        return Failed(EINVAL);
    int in[2], out[2] = {-1, -1}, err[2] = {-1, -1};
    if (!MakePair(in, true)) return Failed(errno);
    if (!MakePair(out, false) || !MakePair(err, false)) {
        const int saved = errno;
        Close(in[0]); Close(in[1]); Close(out[0]); Close(out[1]);
        Close(err[0]); Close(err[1]); return Failed(saved);
    }
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    if (setsockopt(in[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
        const int saved = errno;
        Close(in[0]); Close(in[1]); Close(out[0]); Close(out[1]);
        Close(err[0]); Close(err[1]); return Failed(saved);
    }
#endif
    int actionError = 0;
    posix_spawn_file_actions_t actions;
    actionError = posix_spawn_file_actions_init(&actions);
    bool initialized = actionError == 0;
    int temporaryInherited = -1;
    if (actionError == 0 && inheritedFd >= 0) {
#ifdef __APPLE__
        actionError = posix_spawn_file_actions_addinherit_np(&actions, inheritedFd);
#else
        temporaryInherited = fcntl(inheritedFd, F_DUPFD, STDERR_FILENO + 1);
        if (temporaryInherited < 0) actionError = errno;
        else {
            actionError = posix_spawn_file_actions_adddup2(&actions, temporaryInherited, inheritedFd);
            if (actionError == 0)
                actionError = posix_spawn_file_actions_addclose(&actions, temporaryInherited);
        }
#endif
    }
    const int childDescriptors[] = {in[0], out[1], err[1]};
    for (int destination = 0; destination != 3 && actionError == 0; ++destination)
        actionError = posix_spawn_file_actions_adddup2(&actions, childDescriptors[destination], destination);
    const int allDescriptors[] = {in[0], in[1], out[0], out[1], err[0], err[1]};
    for (int descriptor : allDescriptors)
        if (actionError == 0)
            actionError = posix_spawn_file_actions_addclose(&actions, descriptor);
    std::vector<std::string> storage(1, helperPath);
    storage.insert(storage.end(), arguments.begin(), arguments.end());
    if (timeoutMilliseconds != 0)
        storage.push_back("--cydia-deadline-ms=" + std::to_string(timeoutMilliseconds));
    std::vector<char *> argv;
    for (const std::string &argument : storage) {
        if (argument.find('\0') != std::string::npos) actionError = EINVAL;
        argv.push_back(const_cast<char *>(argument.c_str()));
    }
    argv.push_back(NULL);
    pid_t child = -1;
    posix_spawnattr_t attributes;
    bool attributesInitialized = false;
    if (actionError == 0 && timeoutMilliseconds != 0) {
        actionError = posix_spawnattr_init(&attributes);
        attributesInitialized = actionError == 0;
        if (actionError == 0) actionError = posix_spawnattr_setpgroup(&attributes, 0);
        if (actionError == 0) actionError = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    }
    if (actionError == 0)
        actionError = posix_spawn(&child, helperPath.c_str(), &actions,
            attributesInitialized ? &attributes : NULL, argv.data(), environ);
    if (attributesInitialized) posix_spawnattr_destroy(&attributes);
    if (initialized) posix_spawn_file_actions_destroy(&actions);
    Close(temporaryInherited);
    Close(in[0]); Close(out[1]); Close(err[1]);
    if (actionError != 0) {
        Close(in[1]); Close(out[0]); Close(err[0]); return Failed(actionError);
    }

    Result result = {0, -1, 0, false, std::string(), std::string()};
    const auto deadline(std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeoutMilliseconds));
    auto remaining = [&]() -> int {
        if (timeoutMilliseconds == 0) return -1;
        const auto now(std::chrono::steady_clock::now());
        if (now >= deadline) return 0;
        const auto duration(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count());
        return static_cast<int>(std::min<long long>(duration + 1, 2147483647));
    };
    auto terminate = [&]() {
        result.launchError = ETIMEDOUT;
        /* Bounded helpers run in their own process group. The helper also
         * enforces this deadline after elevating privileges, when its mobile
         * parent may no longer have permission to send a signal. */
        kill(-child, SIGKILL);
    };
    int *parentDescriptors[] = {&in[1], &out[0], &err[0]};
    for (int *descriptor : parentDescriptors) {
        const int flags = fcntl(*descriptor, F_GETFL);
        if (flags < 0 || fcntl(*descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
            result.launchError = errno;
            Close(in[1]); Close(out[0]); Close(err[0]); break;
        }
    }
    std::size_t offset = 0;
    /* Multiplex input and both output streams. A helper may write before
     * reading a large source-edit request; sequential pipe I/O would deadlock. */
    while (in[1] >= 0 || out[0] >= 0 || err[0] >= 0) {
        if (in[1] >= 0 && offset == input.size()) Close(in[1]);
        if (in[1] < 0 && out[0] < 0 && err[0] < 0) break;
        struct pollfd ready[] = {
            {in[1], POLLOUT, 0}, {out[0], POLLIN, 0}, {err[0], POLLIN, 0}
        };
        int status;
        do { status = poll(ready, 3, remaining()); } while (status < 0 && errno == EINTR);
        if (status == 0) { terminate(); break; }
        if (status < 0) { result.launchError = errno; break; }
        if (in[1] >= 0 && ready[0].revents != 0) {
            int sendFlags = 0;
#ifdef MSG_NOSIGNAL
            sendFlags = MSG_NOSIGNAL;
#endif
            ssize_t count = send(in[1], input.data() + offset, input.size() - offset, sendFlags);
            if (count > 0) offset += static_cast<std::size_t>(count);
            else if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                if (result.launchError == 0) result.launchError = count == 0 ? EIO : errno;
                Close(in[1]);
            }
        }
        for (int index = 1; index != 3; ++index) {
            int &fd = index == 1 ? out[0] : err[0];
            if (fd < 0 || ready[index].revents == 0) continue;
            char bytes[16384];
            ssize_t count = read(fd, bytes, sizeof(bytes));
            if (count > 0)
                Append(result, index == 1 ? result.output : result.error, bytes,
                       static_cast<std::size_t>(count), captureLimit);
            else if (count == 0) Close(fd);
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                if (result.launchError == 0) result.launchError = errno;
                Close(fd);
            }
        }
    }
    Close(in[1]); Close(out[0]); Close(err[0]);
    int waitStatus = 0;
    pid_t waited;
    for (;;) {
        do { waited = waitpid(child, &waitStatus, timeoutMilliseconds == 0 ? 0 : WNOHANG); }
        while (waited < 0 && errno == EINTR);
        if (waited != 0) break;
        const int wait(remaining());
        if (wait == 0) {
            terminate();
            do { waited = waitpid(child, &waitStatus, 0); } while (waited < 0 && errno == EINTR);
            break;
        }
        poll(NULL, 0, std::min(wait, 20));
    }
    if (waited < 0) result.launchError = errno;
    else if (WIFEXITED(waitStatus)) result.exitCode = WEXITSTATUS(waitStatus);
    else if (WIFSIGNALED(waitStatus)) result.termSignal = WTERMSIG(waitStatus);
    else result.launchError = ECHILD;
    return result;
}

struct LockContext {
    std::string helperPath;
    Privileged::Request request;
    unsigned timeoutMilliseconds = 0;
};
LockContext lockContext;

#ifdef APT_CYDIA_LOCK_FILE_OPENER
bool OpenAptLock(const std::string &path, int *descriptor, void *context) {
    LockContext &selected = *static_cast<LockContext *>(context);
    const std::string base = selected.request.expected.dpkgAdmin + '/';
    if (path != base + "lock" && path != base + "lock-frontend") return false;
    Privileged::Error error;
    *descriptor = OpenLock(selected.helperPath, selected.request, path.substr(base.size()), &error,
        selected.timeoutMilliseconds);
    return true;
}
#endif
} // namespace

bool Result::succeeded() const {
    return launchError == 0 && exitCode == 0 && termSignal == 0 && !outputLimitExceeded;
}

Privileged::ExpectedEnvironment CurrentExpectedEnvironment() {
    Privileged::ExpectedEnvironment expected;
    expected.aptConfigOverride = CydiaAPT::AptConfigOverride();
    expected.dpkgRoot = CydiaAPT::DpkgRootDirectory();
    expected.dpkgAdmin = CydiaAPT::DpkgAdminDirectory();
    expected.dpkg = CydiaAPT::DpkgExecutablePath();
    expected.dpkgQuery = CydiaAPT::DpkgQueryExecutablePath();
    expected.dpkgDeb = CydiaAPT::DpkgDebExecutablePath();
    expected.sourceList = CydiaAPT::SourceListPath();
    expected.sourceParts = CydiaAPT::SourcePartsDirectory();
    return expected;
}

Privileged::Request RuntimeRequest(const std::string &payload) {
    Privileged::Request request;
    request.expected = CurrentExpectedEnvironment(); request.payload = payload;
    return request;
}

Result Run(const std::string &helperPath, const std::string &command,
           const Privileged::Request &request, std::size_t captureLimit, unsigned timeoutMilliseconds) {
    if (command.compare(0, 8, "--cydia-") != 0 || command.find_first_of("\r\n") != std::string::npos)
        return Failed(EINVAL);
    return RunInternal(helperPath, {command}, request, captureLimit, timeoutMilliseconds);
}

Result RunNativeCommand(const std::string &command, const std::string &payload,
                       std::size_t captureLimit, unsigned timeoutMilliseconds) {
    return Run(CydiaAPT::PrivilegedHelperPath(), command, RuntimeRequest(payload), captureLimit,
        timeoutMilliseconds);
}

int OpenLock(const std::string &helperPath, const Privileged::Request &request,
             const std::string &purpose, Privileged::Error *error, unsigned timeoutMilliseconds) {
    if (purpose != "lock" && purpose != "lock-frontend") {
        errno = EINVAL; return -1;
    }
    int sockets[2];
    if (!MakePair(sockets, true)) return -1;
    Privileged::Request selected = request; selected.payload = purpose;
    Result result = RunInternal(helperPath, {"--cydia-open-lock", std::to_string(sockets[1])},
                                selected, 65536, timeoutMilliseconds, sockets[1]);
    Close(sockets[1]);
    char byte = 0;
    struct iovec data = {&byte, 1};
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int) * 8)]; } control;
    std::memset(&control, 0, sizeof(control));
    struct msghdr message;
    std::memset(&message, 0, sizeof(message));
    message.msg_iov = &data; message.msg_iovlen = 1;
    message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
    const ssize_t count = recvmsg(sockets[0], &message, MSG_DONTWAIT);
    Close(sockets[0]);
    std::vector<int> received;
    bool unexpected = false;
    if (count >= 0) {
        for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header != NULL;
             header = CMSG_NXTHDR(&message, header)) {
            if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
                header->cmsg_len < CMSG_LEN(0)) { unexpected = true; continue; }
            const std::size_t bytes = header->cmsg_len - CMSG_LEN(0);
            if (bytes % sizeof(int) != 0) unexpected = true;
            const int *descriptors = reinterpret_cast<const int *>(CMSG_DATA(header));
            received.insert(received.end(), descriptors, descriptors + bytes / sizeof(int));
        }
    }
    if (!result.succeeded() || count != 1 || byte != 'L' || unexpected ||
        (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) != 0 || received.size() != 1 ||
        fcntl(received.empty() ? -1 : received[0], F_SETFD, FD_CLOEXEC) != 0) {
        for (int fd : received) close(fd);
        if (error != NULL) {
            error->code = "lock_open_failed";
            error->message = result.error.empty() ? "Could not obtain a validated package-manager lock descriptor." : result.error;
        }
        errno = result.launchError != 0 ? result.launchError : EACCES;
        return -1;
    }
    return received[0];
}

void ConfigureLockBridge(const std::string &helperPath,
                         const Privileged::ExpectedEnvironment &expected) {
    lockContext.helperPath = helperPath; lockContext.request.expected = expected;
#ifdef APT_CYDIA_LOCK_FILE_OPENER
    SetLockFileOpener(OpenAptLock, &lockContext);
#endif
}

unsigned SetLockBridgeTimeoutMilliseconds(unsigned timeoutMilliseconds) {
    const unsigned previous(lockContext.timeoutMilliseconds);
    lockContext.timeoutMilliseconds = timeoutMilliseconds;
    return previous;
}

void ClearLockBridge() {
#ifdef APT_CYDIA_LOCK_FILE_OPENER
    SetLockFileOpener(NULL, NULL);
#endif
    lockContext = LockContext();
}
} // namespace PrivilegedClient
} // namespace CydiaRuntime
