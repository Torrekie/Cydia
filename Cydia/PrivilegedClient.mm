/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include "Cydia/PrivilegedClient.h"
#include "Cydia/DpkgConffile.hpp"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/AptProviderTransactionRequest.hpp"
#include "Cydia/AptProviderEffectReviewBundle.hpp"
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
#include <thread>
#include <limits>

#if defined(__GLIBC__) && defined(__GLIBC_PREREQ)
#if __GLIBC_PREREQ(2, 34)
#define CYDIA_TRANSACTION_SPAWN_CLOSEFROM 1
#endif
#endif

extern char **environ;

namespace CydiaRuntime {
namespace PrivilegedClient {
namespace {
struct ProviderAuthorityContext {
    bool active = false;
    std::string helper;
    CydiaAPT::Provider::RegistrationIdentity identity;
    bool recovery = false;
    CydiaAPT::Recovery::RequestAuthority recoveryIdentity;
    Privileged::ExpectedEnvironment expected;
} providerAuthority;
bool SelectedAuthorityPayload(const std::string &payload, std::string *bytes) {
    return providerAuthority.recovery ?
        CydiaAPT::Provider::BrokerRequestPayload(providerAuthority.recoveryIdentity, payload, bytes) :
        CydiaAPT::Provider::BrokerRequestPayload(providerAuthority.identity, payload, bytes);
}
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
    if (providerAuthority.active) return providerAuthority.expected;
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

Privileged::Request PrivateSettingsRequest(const std::string &payload) {
    Privileged::Request request;
    request.payload = payload;
    return request;
}

Result Run(const std::string &helperPath, const std::string &command,
           const Privileged::Request &request, std::size_t captureLimit, unsigned timeoutMilliseconds) {
    if (command.compare(0, 8, "--cydia-") != 0 || command.find_first_of("\r\n") != std::string::npos)
        return Failed(EINVAL);
    const bool privateSetup = command == "--cydia-set-executable" || command.compare(0, 21, "--cydia-admin-access-") == 0;
    if (providerAuthority.active && !privateSetup && command != "--cydia-recovery-snapshot" && command.compare(0, 17, "--cydia-provider-") != 0) {
        if (helperPath != providerAuthority.helper) return Failed(EINVAL);
        Privileged::Request wrapped = request;
        if (!SelectedAuthorityPayload(request.payload, &wrapped.payload)) return Failed(EINVAL);
        return RunInternal(helperPath, {"--cydia-provider-route", command}, wrapped, captureLimit, timeoutMilliseconds);
    }
    return RunInternal(helperPath, {command}, request, captureLimit, timeoutMilliseconds);
}

Result RunNativeCommand(const std::string &command, const std::string &payload,
                       std::size_t captureLimit, unsigned timeoutMilliseconds) {
    return Run(CydiaAPT::PrivilegedHelperPath(), command, RuntimeRequest(payload), captureLimit,
        timeoutMilliseconds);
}

Result RunPrivateSettingsCommand(const std::string &command, const std::string &payload,
                                std::size_t captureLimit, unsigned timeoutMilliseconds) {
    if (command != "--cydia-set-executable") return Failed(EINVAL);
    return Run(CydiaAPT::PrivilegedHelperPath(), command, PrivateSettingsRequest(payload),
               captureLimit, timeoutMilliseconds);
}

static int OpenLockRequest(const std::string &helperPath, const std::string &command,
                          const Privileged::Request &request, Privileged::Error *error, unsigned timeoutMilliseconds) {
    int sockets[2];
    if (!MakePair(sockets, true)) return -1;
    Result result = RunInternal(helperPath, {command, std::to_string(sockets[1])},
                                request, 65536, timeoutMilliseconds, sockets[1]);
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

int OpenProviderLock(const std::string &helperPath, const Privileged::Request &request,
                     Privileged::Error *error, unsigned timeoutMilliseconds) {
    return OpenLockRequest(helperPath, "--cydia-provider-lock", request, error, timeoutMilliseconds);
}
int OpenLock(const std::string &helperPath, const Privileged::Request &request,
             const std::string &purpose, Privileged::Error *error, unsigned timeoutMilliseconds) {
    if (purpose != "lock" && purpose != "lock-frontend") { errno = EINVAL; return -1; }
    Privileged::Request selected = request; selected.payload = purpose;
    if (providerAuthority.active) {
        if (helperPath != providerAuthority.helper ||
            !SelectedAuthorityPayload(purpose, &selected.payload)) { errno = EINVAL; return -1; }
        return OpenProviderLock(helperPath, selected, error, timeoutMilliseconds);
    }
    return OpenLockRequest(helperPath, "--cydia-open-lock", selected, error, timeoutMilliseconds);
}

void ConfigureProviderAuthority(const std::string &helperPath,
    const CydiaAPT::Provider::RegistrationIdentity &identity, const Privileged::ExpectedEnvironment &expected) {
    providerAuthority = ProviderAuthorityContext();
    providerAuthority.helper = helperPath; providerAuthority.identity = identity;
    providerAuthority.expected = expected; providerAuthority.active = true;
}
void ConfigureRecoveryAuthority(const std::string &helperPath,
    const CydiaAPT::Recovery::RequestAuthority &authority, const Privileged::ExpectedEnvironment &expected) {
    providerAuthority = ProviderAuthorityContext();
    providerAuthority.helper = helperPath; providerAuthority.recoveryIdentity = authority;
    providerAuthority.expected = expected; providerAuthority.recovery = true; providerAuthority.active = true;
}
void ClearProviderAuthority() { providerAuthority = ProviderAuthorityContext(); }
bool CaptureProviderDeconfigurationReview(const std::string &helperPath,
    const Privileged::Request &wrappedRequest, const CydiaAPT::Provider::ReviewedTransaction &expectedReview,
    const std::string &expectedMethodsIdentity, std::shared_ptr<const CydiaAPT::Provider::EffectReviewBundle> *bundle,
    Privileged::Error *error, unsigned timeoutMilliseconds, const std::function<bool()> &cancelled) {
    namespace Provider = CydiaAPT::Provider;
    if (error) { error->code.clear(); error->message.clear(); }
    const auto fail = [&](const char *code) { if (error) error->code = code; return false; };
    if (!bundle) return fail("provider_effect_review_invalid");
    bundle->reset();
    if (cancelled && cancelled()) return fail("provider_cancelled");
    std::vector<std::string> fields; Provider::EffectReviewCaptureRequest requested;
    std::string wanted, sent;
    if (!Provider::Decode(wrappedRequest.payload, &fields) || fields.size() != 3 ||
        (fields[0] != "CYDIA-BROKER-1" && fields[0] != "CYDIA-RECOVERY-BROKER-1") ||
        !Provider::DecodeEffectReviewCaptureRequest(fields[2], &requested) || requested.methodsIdentity != expectedMethodsIdentity ||
        !Provider::Encode(expectedReview, &wanted) || !Provider::Encode(requested.review, &sent) || wanted != sent)
        return fail("provider_effect_review_changed");
    const unsigned timeout = std::max(Provider::MinimumEffectReviewCaptureMilliseconds,
        std::min(timeoutMilliseconds ? timeoutMilliseconds : Provider::MaximumEffectReviewCaptureMilliseconds,
            Provider::MaximumEffectReviewCaptureMilliseconds));
    const auto result = Run(helperPath, "--cydia-provider-review-deconfiguration", wrappedRequest,
        Provider::MaximumEffectReviewBundleBytes, timeout);
    if (cancelled && cancelled()) return fail("provider_cancelled");
    auto captured = std::make_shared<Provider::EffectReviewBundle>();
    if (!result.succeeded() || !Provider::DecodeEffectReviewBundle(result.output, captured.get()) ||
        !Provider::EffectReviewBundleMatches(*captured, expectedReview, expectedMethodsIdentity))
        return fail("provider_effect_review_unavailable");
    *bundle = std::move(captured); return true;
}
bool ReadProviderSnapshot(const std::string &helperPath, const std::string &registrationPath,
    const CydiaAPT::Provider::RegistrationIdentity *expected,
    CydiaAPT::Provider::RegisteredProviderSnapshot *snapshot, Privileged::Error *error,
    unsigned timeoutMilliseconds, const std::function<bool()> &cancelled) {
    namespace Provider = CydiaAPT::Provider;
    const auto fail = [&](const char *code) {
        if (error) { error->code = code; error->message.clear(); }
        return false;
    };
    if (!snapshot || (cancelled && cancelled())) return fail("provider_cancelled");
    const std::string identity = expected ? Provider::SerializeRegistrationIdentity(*expected) : std::string();
    if (expected && identity.empty()) return fail("provider_authority_invalid");
    Privileged::Request request;
    request.payload = Privileged::SerializeFields({registrationPath, identity});
    const auto result = Run(helperPath, "--cydia-provider-snapshot", request,
        Provider::MaximumMessageBytes, timeoutMilliseconds ? timeoutMilliseconds : 4000);
    if (cancelled && cancelled()) return fail("provider_cancelled");
    std::vector<std::string> fields; Privileged::Error ignored;
    if (!result.succeeded() || !Privileged::ParseFields(result.output, 4, &fields, &ignored) ||
        fields[0] != "CYDIA-PROVIDER-SNAPSHOT-1") return fail("provider_snapshot_unavailable");
    if (!fields[1].empty()) {
        if (!Provider::ValidIdentityToken(fields[1]) || !fields[3].empty()) return fail("provider_snapshot_invalid");
        if (error) { error->code = fields[1]; error->message = fields[2]; }
        return false;
    }
    Provider::RegisteredProviderSnapshot parsed;
    if (!fields[2].empty() || !Provider::ParseRegisteredProviderSnapshot(fields[3], &parsed) ||
        parsed.identity.registrationPath != registrationPath ||
        (expected && !Provider::SameRegistrationIdentity(*expected, parsed.identity)))
        return fail("provider_snapshot_invalid");
    *snapshot = std::move(parsed); return true;
}
bool ReadRecoverySnapshot(const std::string &helperPath, const CydiaAPT::Recovery::Preferences &preferences,
    const CydiaAPT::Recovery::Identity *expected, CydiaAPT::Recovery::Snapshot *snapshot, Privileged::Error *error,
    unsigned timeoutMilliseconds, const std::function<bool()> &cancelled) {
    namespace Recovery = CydiaAPT::Recovery;
    const auto fail = [&](const char *code) { if (error) { error->code = code; error->message.clear(); } return false; };
    if (!snapshot || (cancelled && cancelled())) return fail("recovery_cancelled");
    const auto choices = Recovery::SerializePreferences(preferences);
    const auto identity = expected ? Recovery::SerializeIdentity(*expected) : std::string();
    if (choices.empty() || (expected && identity.empty())) return fail("recovery_authority_invalid");
    Privileged::Request request; request.payload = Privileged::SerializeFields({choices, identity});
    const auto result = Run(helperPath, "--cydia-recovery-snapshot", request,
        Recovery::MaximumSnapshotBytes + 65536, timeoutMilliseconds ? timeoutMilliseconds : 4000);
    if (cancelled && cancelled()) return fail("recovery_cancelled");
    std::vector<std::string> fields; Privileged::Error ignored;
    if (!result.succeeded() || !Privileged::ParseFields(result.output, 4, &fields, &ignored) ||
        fields[0] != "CYDIA-RECOVERY-SNAPSHOT-REPLY-1") return fail("recovery_snapshot_unavailable");
    if (!fields[1].empty()) {
        if (!CydiaAPT::Provider::ValidIdentityToken(fields[1]) || !fields[3].empty()) return fail("recovery_snapshot_invalid");
        if (error) { error->code = fields[1]; error->message = fields[2]; } return false;
    }
    Recovery::Snapshot parsed;
    if (!fields[2].empty() || !Recovery::ParseSnapshot(fields[3], &parsed) ||
        Recovery::SerializePreferences(Recovery::AuthorityRequest(parsed).preferences) != choices ||
        (expected && Recovery::SerializeIdentity(*expected) != Recovery::SerializeIdentity(parsed.identity))) return fail("recovery_snapshot_invalid");
    *snapshot = std::move(parsed); return true;
}


DpkgExecutionResult RunProviderDpkg(const std::string &helperPath, const std::string &command,
    const Privileged::Request &request, int statusFd, const std::string *input,
    const std::vector<std::string> &argvOptions) {
    DpkgExecutionResult result = {{Dpkg::ResultKind::LaunchFailed, -1, EINVAL}, false, false};
    const auto payload = Privileged::SerializeRequest(request);
    if ((command != "--cydia-provider-dpkg" && command != "--cydia-provider-direct") ||
        helperPath.empty() || payload.empty() || payload.size() > 8 * 1024 * 1024 || statusFd < -1 ||
        (statusFd >= 0 && (statusFd < 3 || fcntl(statusFd, F_GETFD) < 0))) return result;
    Dpkg::ConffileExecution conffiles(argvOptions, input == nullptr && statusFd >= 3);
    if (!conffiles.valid()) { result.result.error = EBUSY; return result; }
    int channel[2], in[2] = {-1, -1};
    if (!MakePair(channel, true)) { result.result.error = errno; return result; }
    if (input && !MakePair(in, true)) { result.result.error = errno; Close(channel[0]); Close(channel[1]); return result; }
#ifdef SO_NOSIGPIPE
    int enabled = 1; setsockopt(channel[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    if (input) setsockopt(in[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
#ifdef F_SETNOSIGPIPE
    if (input) fcntl(in[1], F_SETNOSIGPIPE, 1);
#endif
    posix_spawn_file_actions_t actions; int error = posix_spawn_file_actions_init(&actions);
    const bool initialized = error == 0; std::vector<int> duplicates;
    for (const int descriptor : {channel[1], statusFd}) if (descriptor >= 0 && error == 0) {
#ifdef __APPLE__
        error = posix_spawn_file_actions_addinherit_np(&actions, descriptor);
#else
        const int copy = fcntl(descriptor, F_DUPFD, 3);
        if (copy < 0) error = errno;
        else { duplicates.push_back(copy); error = posix_spawn_file_actions_adddup2(&actions, copy, descriptor);
            if (!error) error = posix_spawn_file_actions_addclose(&actions, copy); }
#endif
    }
    if (!error) error = posix_spawn_file_actions_addclose(&actions, channel[0]);
    if (input && !error) error = posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO);
    if (input && !error) error = posix_spawn_file_actions_addclose(&actions, in[0]);
    if (input && !error) error = posix_spawn_file_actions_addclose(&actions, in[1]);
    if (conffiles.enabled() && !error) error = posix_spawn_file_actions_adddup2(&actions, conffiles.inputDescriptor(), STDIN_FILENO);
    if (conffiles.enabled() && !error) error = posix_spawn_file_actions_addclose(&actions, conffiles.inputDescriptor());
    if (conffiles.enabled() && !error) error = posix_spawn_file_actions_adddup2(&actions, conffiles.statusDescriptor(), statusFd);
    if (conffiles.enabled() && !error) error = posix_spawn_file_actions_addclose(&actions, conffiles.statusDescriptor());
    std::vector<std::string> storage{helperPath, command, std::to_string(channel[1])};
    std::vector<char *> argv; for (auto &word : storage) argv.push_back(&word[0]); argv.push_back(nullptr);
    pid_t child = -1;
    if (!error) error = posix_spawn(&child, helperPath.c_str(), &actions, nullptr, argv.data(), environ);
    if (initialized) posix_spawn_file_actions_destroy(&actions);
    for (const int descriptor : duplicates) close(descriptor);
    Close(channel[1]); Close(in[0]);
    if (error) { Close(channel[0]); Close(in[1]); result.result.error = error; return result; }
    conffiles.ChildStarted();
    const auto writeAll = [](int fd, const std::string &bytes, bool socket) {
        std::size_t offset = 0;
        while (offset < bytes.size()) {
            ssize_t count;
#ifdef MSG_NOSIGNAL
            if (socket) count = send(fd, bytes.data() + offset, bytes.size() - offset, MSG_NOSIGNAL);
            else
#else
            (void) socket;
#endif
                count = write(fd, bytes.data() + offset, bytes.size() - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) return false;
            offset += count;
        }
        return true;
    };
    const bool sent = writeAll(channel[0], payload, true);
    shutdown(channel[0], SHUT_WR);
    if (input) { if (sent) writeAll(in[1], *input, true); Close(in[1]); }
    int status = 0; pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    conffiles.Finish();
    char marker[2] = {}; const ssize_t count = recv(channel[0], marker, sizeof(marker), MSG_DONTWAIT);
    Close(channel[0]); result.started = count == 1 && marker[0] == 'S';
    result.indeterminate = !result.started && !(count == 1 && marker[0] == 'N');
    if (waited != child) result.result = {Dpkg::ResultKind::LaunchFailed, -1, errno};
    else if (WIFSIGNALED(status)) result.result = {Dpkg::ResultKind::Signaled, WTERMSIG(status), 0};
    else if (WIFEXITED(status)) result.result = {Dpkg::ResultKind::Exited, WEXITSTATUS(status), 0};
    if ((!sent || result.indeterminate) && result.result.succeeded()) result.result = {Dpkg::ResultKind::LaunchFailed, -1, EIO};
    return result;
}

namespace {
namespace Transaction = CydiaAPT::Provider::TransactionChannel;
// No signals are sent: a lost channel may still have a real dpkg child. A
// settled/nonmutating helper can be reaped asynchronously after EOF without
// extending the bounded client operation. Active mutation waits synchronously.
void ReapTransaction(pid_t child, bool wait) {
    if (child <= 0) return;
    const auto reap = [child]() {
        int status; while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    };
    if (wait) reap();
    else {
        int status; pid_t result;
        do { result = waitpid(child, &status, WNOHANG); } while (result < 0 && errno == EINTR);
        if (result != 0) return;
        try { std::thread(reap).detach(); }
        catch (...) { reap(); } // Retain child ownership even under resource exhaustion.
    }
}
bool SpawnTransaction(const std::string &helper, int *channel, pid_t *child, std::string *failure) {
    const auto fail = [&]() { if (failure) *failure = "provider_transaction_launch_failed"; return false; };
    if (helper.empty() || helper[0] != '/' || helper.find('\0') != std::string::npos) return fail();
    int pair[2]; if (!MakePair(pair, true)) return fail();
    // Keep every action source above the fixed inherited channel fd3. This
    // also handles a caller whose stdio descriptors happen to be closed.
    const int source = fcntl(pair[1], F_DUPFD_CLOEXEC, 4);
    Close(pair[1]);
    if (source < 0) { Close(pair[0]); return fail(); }
    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions); const bool initialized = !error;
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, source, 3);
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    for (int fd = 0; fd < 3 && !error; ++fd)
        if (fcntl(fd, F_GETFD) >= 0) error = posix_spawn_file_actions_addinherit_np(&actions, fd);
#elif defined(CYDIA_TRANSACTION_SPAWN_CLOSEFROM)
    if (!error) error = posix_spawn_file_actions_addclosefrom_np(&actions, 4);
#else
    if (!error) error = ENOTSUP; // Never race a process-wide descriptor enumeration.
#endif
    posix_spawnattr_t attributes; bool attributesReady = false;
    if (!error) { error = posix_spawnattr_init(&attributes); attributesReady = !error; }
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    if (!error) error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
#endif
    std::string command("--cydia-provider-transaction"), descriptor("3");
    char *argv[] = {const_cast<char *>(helper.c_str()), &command[0], &descriptor[0], nullptr};
    if (!error) error = posix_spawn(child, helper.c_str(), &actions, &attributes, argv, environ);
    if (attributesReady) posix_spawnattr_destroy(&attributes);
    if (initialized) posix_spawn_file_actions_destroy(&actions);
    close(source);
    if (error) { Close(pair[0]); return fail(); }
    *channel = pair[0]; return true;
}
}

class ProviderTransaction::Implementation {
public:
    Transaction::Channel channel;
    pid_t child;
    std::string nonce, digest;
    std::uint64_t sequence = 0;
    std::uint64_t childOrdinal = 0, triggerPass = 0;
    bool scopedChildren = false, conffilePolicy = false;
    std::shared_ptr<const CydiaAPT::Provider::TriggerEffectEnvelope> reviewedEffects;
    bool ready = false, everStarted = false, uncertain = false;
    Implementation(int socket, pid_t pid, const std::string &review, bool scoped, bool policy) : channel(socket), child(pid), digest(review), scopedChildren(scoped), conffilePolicy(policy) {}
    ~Implementation() { End(false); }
    void End(bool mutationPending) {
        ready = false; channel.Close();
        const pid_t owned = child; child = -1; ReapTransaction(owned, mutationPending);
    }
    ProviderTransactionResult Exchange(Transaction::Operation operation, const std::string &payload,
        Dpkg::ConffileExecution *conffiles, const std::function<void()> &started,
        unsigned timeout, const std::function<bool()> &cancelled, const std::vector<std::string> &options = {}) {
        namespace Provider = CydiaAPT::Provider;
        ProviderTransactionResult result;
        const bool mutating = operation == Transaction::Operation::Execute || operation == Transaction::Operation::Commit;
        Transaction::Frame request; request.operation = operation; request.sequence = sequence;
        request.nonce = nonce; request.reviewDigest = digest; request.payload = payload;
        request.scopedChildren = scopedChildren; request.conffilePolicy = conffilePolicy;
        std::vector<int> descriptors;
        if (conffiles) descriptors = {conffiles->inputDescriptor(), conffiles->statusDescriptor()};
        bool sent = false, notified = false, observerFailed = false;
        bool primarySeen = false, stopped = false, childStarted = false, channelsGranted = false, policyAccepted = false;
        std::unique_ptr<Dpkg::ConffileExecution> scope;
        Transaction::Frame childFrame;
        const auto cancelledNow = [&] {
            if (stopped || observerFailed) return true;
            try { return cancelled && cancelled(); } catch (...) { return true; }
        };
        const auto notify = [&] {
            if (notified) return;
            notified = everStarted = true;
            if (started) { try { started(); } catch (...) { observerFailed = true; } }
        };
        const auto fail = [&](const std::string &code) {
            result.errorCode = code; result.started = notified;
            result.indeterminate = mutating && sent; uncertain |= result.indeterminate;
            // Finish may close conffile input only after the owned helper has
            // settled. It never supplies a forced answer to break this wait.
            End(result.indeterminate);
            if (conffiles) conffiles->Finish();
            if (scope) scope->Finish();
            return result;
        };
        if (!channel.Send(request, descriptors, timeout ? timeout : 4000, cancelled, &sent)) return fail(channel.error());
        // SCM_RIGHTS now owns the child-only ends, even before the actual spawn.
        if (conffiles) conffiles->ChildStarted();
        for (;;) {
            Transaction::Frame reply; std::vector<int> received;
            // A finite helper cannot start before it receives its first pair.
            // After channel transfer, a child may have started even before its
            // notification arrives, so mutation reads must await settlement.
            const bool waitingForChannels = scopedChildren && operation == Transaction::Operation::Execute && !channelsGranted;
            if (!channel.Receive(&reply, &received, mutating && !waitingForChannels ? 0 : (timeout ? timeout : 4000),
                    mutating && (!waitingForChannels || stopped) ? std::function<bool()>() : cancelled)) return fail(channel.error());
            for (const int fd : received) close(fd);
            if (!received.empty() || reply.operation != operation || reply.sequence != sequence || reply.scopedChildren != scopedChildren || reply.conffilePolicy != conffilePolicy ||
                reply.reviewDigest != digest || reply.event == Transaction::Event::Request ||
                (operation != Transaction::Operation::Begin && reply.nonce != nonce)) return fail("provider_transaction_binding_invalid");
            if (static_cast<unsigned>(reply.event) >= static_cast<unsigned>(Transaction::Event::ChildNeeded)) {
                if (!scopedChildren || operation != Transaction::Operation::Execute)
                    return fail("provider_transaction_child_invalid");
                if (reply.event == Transaction::Event::ChildNeeded) {
                    Transaction::ChildDescriptor descriptor; Provider::ParentExecutionRequest execution;
                    if (scope || stopped || childOrdinal == UINT64_MAX || reply.childOrdinal != childOrdinal + 1 ||
                        !Transaction::DecodeChildDescriptor(reply.childDescriptor, &descriptor) || !Provider::Decode(payload, &execution))
                        return fail("provider_transaction_child_invalid");
                    if (descriptor.purpose == Transaction::ChildPurpose::Primary) {
                        if (primarySeen || descriptor.primaryBatch != execution.batch || descriptor.primaryAction != static_cast<unsigned>(execution.action) ||
                            descriptor.primaryActions != execution.actions) return fail("provider_transaction_child_invalid");
                        primarySeen = true;
                    } else {
                        if (!reviewedEffects || descriptor.envelopeIdentity != reviewedEffects->identity || descriptor.pass <= triggerPass ||
                            descriptor.primaryCheckpoint > reviewedEffects->primaryReview.execution.actions.size())
                            return fail("provider_transaction_child_invalid");
                        for (const auto &target : descriptor.targets) {
                            const auto found = reviewedEffects->recipients.find(target.package + ':' + target.architecture + '@' + target.version);
                            if (found == reviewedEffects->recipients.end() || found->second.package != target.package ||
                                found->second.architecture != target.architecture || found->second.version != target.version)
                                return fail("provider_transaction_child_invalid");
                        }
                        triggerPass = descriptor.pass;
                    }
                    childOrdinal = reply.childOrdinal; childFrame = reply; childStarted = false; policyAccepted = false;
                    auto answer = reply;
                    if (!cancelledNow()) scope.reset(new Dpkg::ConffileExecution(options, true, conffilePolicy));
                    if (!scope || !scope->enabled() || !scope->valid()) {
                        if (scope) { scope->Finish(); scope.reset(); }
                        answer.event = Transaction::Event::ChildDenied; answer.errorCode = cancelledNow() ? "provider_cancelled" : "provider_transaction_channels_unavailable";
                        stopped = true;
                        if (!channel.Send(answer, {}, timeout ? timeout : 4000)) return fail(channel.error());
                    } else {
                        answer.event = Transaction::Event::ChildChannels; answer.success = true;
                        channelsGranted = true;
                        if (!channel.Send(answer, {scope->inputDescriptor(), scope->statusDescriptor()}, timeout ? timeout : 4000)) return fail(channel.error());
                        scope->ChildStarted();
                    }
                    continue;
                }
                if (!scope || reply.childOrdinal != childFrame.childOrdinal || reply.childDescriptor != childFrame.childDescriptor)
                    return fail("provider_transaction_child_invalid");
                if (reply.event == Transaction::Event::ChildPolicy) {
                    Provider::ConffilePolicyDecision policy;
                    if (!conffilePolicy || policyAccepted || childStarted ||
                        !Transaction::DecodeConffilePolicy(reply.payload, &policy) || !scope->ApplyPolicy(policy.input))
                        return fail("provider_conffile_policy_binding_invalid");
                    auto answer = reply; answer.event = Transaction::Event::ChildPolicyAccepted;
                    if (!channel.Send(answer, {}, timeout ? timeout : 4000)) return fail(channel.error());
                    policyAccepted = true; continue;
                }
                if (reply.event == Transaction::Event::ChildStarted) {
                    if (childStarted || (conffilePolicy && !policyAccepted)) return fail("provider_transaction_child_invalid");
                    childStarted = true; notify(); continue;
                }
                if (reply.event != Transaction::Event::ChildSettled) return fail("provider_transaction_child_invalid");
                Provider::ParentExecutionReply settled;
                if (!Provider::Decode(reply.payload, &settled) || settled.started != childStarted || reply.mutationStarted != childStarted)
                    return fail("provider_transaction_child_invalid");
                // The helper reports only after actual reap. Fully close the
                // question generation before acknowledging the next scope.
                scope->Finish(); scope.reset();
                auto answer = reply; answer.payload.clear();
                stopped = cancelledNow(); answer.event = stopped ? Transaction::Event::ChildCancelled : Transaction::Event::ChildReleased;
                answer.success = !stopped; answer.errorCode = stopped ? "provider_cancelled" : "";
                if (!channel.Send(answer, {}, timeout ? timeout : 4000)) return fail(channel.error());
                continue;
            }
            if (reply.event == Transaction::Event::Started) {
                if (!mutating || notified || (scopedChildren && operation == Transaction::Operation::Execute)) return fail("provider_transaction_binding_invalid");
                // An observer is not allowed to unwind a running mutation or
                // destroy its input/status channels before it settles.
                notify();
                continue;
            }
            if (scope || reply.mutationStarted != notified ||
                (operation == Transaction::Operation::Execute && reply.success && !notified))
                return fail("provider_transaction_binding_invalid");
            if (operation == Transaction::Operation::Begin && reply.success) { nonce = reply.nonce; ready = true; }
            result.transportValid = true; result.success = reply.success; result.started = notified;
            result.indeterminate = reply.indeterminate; result.payload = std::move(reply.payload); result.errorCode = reply.errorCode;
            uncertain |= result.indeterminate;
            if (observerFailed) { result.success = false; result.errorCode = "provider_transaction_observer_failed"; }
            if (conffiles) conffiles->Finish();
            if (observerFailed || !reply.success || reply.indeterminate || operation == Transaction::Operation::Close) End(false);
            return result;
        }
    }
};
ProviderTransaction::ProviderTransaction(std::unique_ptr<Implementation> implementation) : implementation_(std::move(implementation)) {}
ProviderTransaction::~ProviderTransaction() { if (valid()) Close(); }
std::unique_ptr<ProviderTransaction> ProviderTransaction::Start(const std::string &helper,
    const Privileged::Request &request, const std::string &digest, std::string *error,
    unsigned timeout, const std::function<bool()> &cancelled, bool scopedChildren, bool conffilePolicy) {
    const std::string payload = Privileged::SerializeRequest(request);
    if (conffilePolicy) scopedChildren = true;
    Transaction::Frame begin; begin.reviewDigest = digest; begin.payload = payload;
    begin.scopedChildren = scopedChildren; begin.conffilePolicy = conffilePolicy;
    CydiaAPT::Provider::TransactionBeginRequest approved;
    if (scopedChildren) {
        std::vector<std::string> fields;
        if (!CydiaAPT::Provider::Decode(request.payload, &fields) || fields.size() != 3 ||
            !CydiaAPT::Provider::DecodeTransactionBegin(fields[2], &approved) || (!conffilePolicy && !approved.reviewedEffects)) {
            if (error) *error = "provider_transaction_review_mismatch";
            return nullptr;
        }
    }
    std::string encoded;
    if (payload.empty() || !Transaction::Encode(begin, &encoded) || (cancelled && cancelled())) {
        if (error) *error = cancelled && cancelled() ? "provider_cancelled" : "provider_transaction_frame_invalid";
        return nullptr;
    }
    int channel = -1; pid_t child = -1;
    if (!SpawnTransaction(helper, &channel, &child, error)) return nullptr;
    std::unique_ptr<Implementation> implementation(new Implementation(channel, child, digest, scopedChildren, conffilePolicy));
    implementation->reviewedEffects = approved.reviewedEffects;
    const auto result = implementation->Exchange(Transaction::Operation::Begin, payload, nullptr, {}, timeout, cancelled);
    if (!result.transportValid || !result.success) { if (error) *error = result.errorCode; return nullptr; }
    if (error) error->clear();
    return std::unique_ptr<ProviderTransaction>(new ProviderTransaction(std::move(implementation)));
}
ProviderTransactionResult ProviderTransaction::Request(Transaction::Operation operation, const std::string &payload,
    int statusFd, const std::vector<std::string> &options, const std::function<void()> &started,
    unsigned timeout, const std::function<bool()> &cancelled) {
    ProviderTransactionResult failure; failure.errorCode = "provider_transaction_unavailable";
    if (!valid() || operation == Transaction::Operation::Begin ||
        implementation_->sequence == std::numeric_limits<std::uint64_t>::max()) return failure;
    if (cancelled && cancelled()) { failure.errorCode = "provider_cancelled"; return failure; }
    std::unique_ptr<Dpkg::ConffileExecution> conffiles;
    if (operation == Transaction::Operation::Execute) {
        if (statusFd < 3 || fcntl(statusFd, F_GETFD) < 0) return failure;
        if (!implementation_->scopedChildren) {
            conffiles.reset(new Dpkg::ConffileExecution(options));
            if (!conffiles->enabled() || !conffiles->valid()) return failure;
        }
    }
    ++implementation_->sequence;
    return implementation_->Exchange(operation, payload, conffiles.get(), started, timeout, cancelled, options);
}
bool ProviderTransaction::Close(std::string *error, unsigned timeout) {
    if (!valid()) { if (error) *error = "provider_transaction_unavailable"; return false; }
    const auto result = Request(Transaction::Operation::Close, "", -1, {}, {}, timeout);
    implementation_->End(false);
    if (error) *error = result.errorCode;
    return result.transportValid && result.success;
}
bool ProviderTransaction::valid() const { return implementation_ && implementation_->ready && implementation_->channel.valid(); }
bool ProviderTransaction::mutationStarted() const { return implementation_ && implementation_->everStarted; }
bool ProviderTransaction::indeterminate() const { return implementation_ && implementation_->uncertain; }

Dpkg::Result RunSelectedDpkg(const std::vector<std::string> &arguments, int statusFd, const std::string *input) {
    if (!providerAuthority.active) {
        Dpkg::Runner runner(CydiaAPT::PrivilegedHelperPath());
        if (input) return runner.RunWithInput(arguments, *input, statusFd);
        Dpkg::ConffileExecution conffiles(arguments, statusFd >= 3);
        Dpkg::ScopedConffileStandardInput standardInput(conffiles);
        if (!conffiles.valid() || !standardInput.valid()) return {Dpkg::ResultKind::LaunchFailed, -1, EIO};
        // This direct configure path runs exactly one child. APT's legacy
        // in-process transaction is scoped separately by Database.
        auto values = arguments;
        if (conffiles.enabled()) {
            for (std::size_t i = 0; i < values.size(); ++i) {
                if (values[i] == "--status-fd" && i + 1 < values.size()) values[++i] = std::to_string(conffiles.statusDescriptor());
                else if (values[i].compare(0, 12, "--status-fd=") == 0)
                    values[i] = "--status-fd=" + std::to_string(conffiles.statusDescriptor());
            }
        }
        const auto result = runner.Run(values, conffiles.enabled() ? conffiles.statusDescriptor() : statusFd);
        conffiles.Finish(); return result;
    }
    auto values = arguments;
    if (!values.empty() && values.front() == providerAuthority.expected.dpkg) values.erase(values.begin());
    if (statusFd >= 0) {
        bool found = false;
        for (const auto &argument : values)
            if (argument == "--status-fd" || argument.compare(0, 12, "--status-fd=") == 0) found = true;
        if (!found) values.insert(values.begin(), "--status-fd=" + std::to_string(statusFd));
    }
    std::string payload; Privileged::Request request; request.expected = providerAuthority.expected;
    if (!CydiaAPT::Provider::Encode(values, &payload) ||
        !SelectedAuthorityPayload(payload, &request.payload))
        return {Dpkg::ResultKind::LaunchFailed, -1, EINVAL};
    return RunProviderDpkg(providerAuthority.helper, "--cydia-provider-direct", request, statusFd, input, arguments).result;
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
