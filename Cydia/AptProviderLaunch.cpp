/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include "Cydia/AptProviderLaunch.hpp"
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdlib>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

#if defined(__GLIBC__) && defined(__GLIBC_PREREQ)
#if __GLIBC_PREREQ(2, 34)
#define CYDIA_PROVIDER_SPAWN_CLOSEFROM 1
#endif
#endif

extern char **environ;
namespace CydiaAPT { namespace Provider {
namespace {
struct FD {
    int value;
    explicit FD(int fd = -1) : value(fd) {}
    ~FD() { if (value >= 0) close(value); }
    FD(const FD &) = delete;
    FD &operator=(const FD &) = delete;
    int release() { const int fd = value; value = -1; return fd; }
};
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Cancelled(const std::function<bool()> &cancelled) {
    try { return cancelled && cancelled(); } catch (...) { return true; }
}
bool Random(unsigned char *bytes, std::size_t size) {
#ifdef __APPLE__
    arc4random_buf(bytes, size); return true;
#else
    FD random(open("/dev/urandom", O_RDONLY | O_CLOEXEC));
    if (random.value < 0) return false;
    for (std::size_t offset = 0; offset < size;) {
        const auto count = read(random.value, bytes + offset, size - offset);
        if (count > 0) offset += count;
        else if (count < 0 && errno == EINTR) continue;
        else return false;
    }
    return true;
#endif
}
bool SameFile(const struct stat &a, const struct stat &b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink &&
#ifdef __APPLE__
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
        a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
int Duplicate(int fd) {
#ifdef F_DUPFD_CLOEXEC
    return fcntl(fd, F_DUPFD_CLOEXEC, 4);
#else
    const int copy = fcntl(fd, F_DUPFD, 4);
    if (copy >= 0 && fcntl(copy, F_SETFD, FD_CLOEXEC)) { close(copy); return -1; }
    return copy;
#endif
}
bool PrivateDirectory(int fd) {
    struct stat info;
    return fd >= 0 && fstat(fd, &info) == 0 && S_ISDIR(info.st_mode) &&
        (info.st_uid == geteuid() || info.st_uid == 0) && (info.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}
bool SafePath(const std::string &path) {
    if (path.empty() || path.front() != '/' || path.find('\0') != std::string::npos) return false;
    std::size_t start = 1;
    while (start < path.size()) {
        const auto end = path.find('/', start), size = end == std::string::npos ? path.size() - start : end - start;
        const auto part = path.substr(start, size);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return true;
}
using Clock = std::chrono::steady_clock;
unsigned Remaining(Clock::time_point deadline) {
    const auto value = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
    return value <= 0 ? 0 : static_cast<unsigned>(std::min<decltype(value)>(value, UINT_MAX));
}
void Reap(pid_t child) {
    int status; while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}
}

class RecoveryLaunchCapsule::Implementation {
public:
    FD descriptor;
    struct stat identity;
    const std::string bytes;
    Implementation(int fd, const struct stat &info, const std::string &snapshot) : descriptor(fd), identity(info), bytes(snapshot) {}
};
RecoveryLaunchCapsule::RecoveryLaunchCapsule(std::unique_ptr<Implementation> implementation) : implementation_(std::move(implementation)) {}
RecoveryLaunchCapsule::~RecoveryLaunchCapsule() = default;
std::shared_ptr<const RecoveryLaunchCapsule> RecoveryLaunchCapsule::Create(const std::string &snapshot,
        const std::string &temporaryDirectory, std::string *error, const std::function<bool()> &cancelled) {
    const auto fail = [&](const char *code) -> std::shared_ptr<const RecoveryLaunchCapsule> { Fail(error, code); return {}; };
    if (error) error->clear();
    if (snapshot.empty() || snapshot.size() > MaximumRecoveryCapsuleBytes || !SafePath(temporaryDirectory))
        return fail("provider_capsule_invalid");
    if (Cancelled(cancelled)) return fail("provider_cancelled");
    FD directory(open(temporaryDirectory.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (!PrivateDirectory(directory.value)) return fail("provider_capsule_directory_unsafe");
    unsigned char random[16];
    if (!Random(random, sizeof(random))) return fail("provider_capsule_create_failed");
    std::string name = ".cydia-provider-";
    const char *hex = "0123456789abcdef";
    for (const auto value : random) { name += hex[value >> 4]; name += hex[value & 15]; }
    FD writable(openat(directory.value, name.c_str(), O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (writable.value < 0) return fail("provider_capsule_create_failed");
    struct Unlink {
        int directory; const std::string &name; bool linked = true;
        Unlink(int directory, const std::string &name) : directory(directory), name(name) {}
        ~Unlink() { if (linked) unlinkat(directory, name.c_str(), 0); }
    } cleanup{directory.value, name};
    for (std::size_t offset = 0; offset < snapshot.size();) {
        if (Cancelled(cancelled)) return fail("provider_cancelled");
        const auto count = write(writable.value, snapshot.data() + offset, std::min<std::size_t>(65536, snapshot.size() - offset));
        if (count > 0) offset += count;
        else if (count < 0 && errno == EINTR) continue;
        else return fail("provider_capsule_write_failed");
    }
    if (fchmod(writable.value, 0400)) return fail("provider_capsule_write_failed");
    FD readonly(openat(directory.value, name.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    struct stat written, reopened;
    if (readonly.value < 0 || fstat(writable.value, &written) || fstat(readonly.value, &reopened) ||
        !S_ISREG(written.st_mode) || written.st_size != static_cast<off_t>(snapshot.size()) ||
        written.st_nlink != 1 || written.st_uid != geteuid() || (written.st_mode & 0777) != 0400 || !SameFile(written, reopened))
        return fail("provider_capsule_changed");
    if (unlinkat(directory.value, name.c_str(), 0)) return fail("provider_capsule_unlink_failed");
    cleanup.linked = false;
    close(writable.release());
    FD retained(Duplicate(readonly.value));
    if (retained.value < 0 || fstat(retained.value, &reopened) || reopened.st_nlink != 0 ||
        !S_ISREG(reopened.st_mode) || reopened.st_size != static_cast<off_t>(snapshot.size()) ||
        reopened.st_uid != geteuid() || (reopened.st_mode & 0777) != 0400)
        return fail("provider_capsule_changed");
    // Verify the completed read-only inode while it is still private. A
    // same-user path replacement must never substitute a different snapshot.
    for (std::size_t offset = 0; offset < snapshot.size();) {
        if (Cancelled(cancelled)) return fail("provider_cancelled");
        char buffer[65536]; const auto count = pread(retained.value, buffer, std::min(sizeof(buffer), snapshot.size() - offset), offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || snapshot.compare(offset, count, buffer, count) != 0) return fail("provider_capsule_changed");
        offset += count;
    }
    struct stat after;
    if (fstat(retained.value, &after) || !SameFile(reopened, after)) return fail("provider_capsule_changed");
    auto implementation = std::unique_ptr<Implementation>(new Implementation(retained.release(), after, snapshot));
    return std::shared_ptr<const RecoveryLaunchCapsule>(new RecoveryLaunchCapsule(std::move(implementation)));
}
bool RecoveryLaunchCapsule::unchanged() const {
    struct stat current;
    if (!implementation_ || fstat(implementation_->descriptor.value, &current) ||
        !SameFile(implementation_->identity, current) || (fcntl(implementation_->descriptor.value, F_GETFL) & O_ACCMODE) != O_RDONLY) return false;
    for (std::size_t offset = 0; offset < implementation_->bytes.size();) {
        char buffer[65536];
        const auto count = pread(implementation_->descriptor.value, buffer, std::min(sizeof(buffer), implementation_->bytes.size() - offset), offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || implementation_->bytes.compare(offset, count, buffer, count) != 0) return false;
        offset += count;
    }
    return fstat(implementation_->descriptor.value, &current) == 0 && SameFile(implementation_->identity, current);
}
int RecoveryLaunchCapsule::duplicateDescriptor() const {
    return unchanged() ? Duplicate(implementation_->descriptor.value) : -1;
}

namespace Launch {
bool Start(const std::string &executable, const std::vector<std::string> &arguments,
        const std::shared_ptr<const RecoveryLaunchCapsule> &capsule, Child *child, std::string *error) {
    if (!child || child->channel != -1 || child->pid != -1 || !SafePath(executable)) return Fail(error, "provider_spawn_failed");
    for (const auto &argument : arguments) if (argument.find('\0') != std::string::npos) return Fail(error, "provider_spawn_failed");
    FD capsuleFD(capsule ? capsule->duplicateDescriptor() : -1);
    if (capsule && capsuleFD.value < 0) return Fail(error, "provider_capsule_changed");
    int sockets[2];
    int socketType = SOCK_STREAM;
#ifdef SOCK_CLOEXEC
    socketType |= SOCK_CLOEXEC;
#endif
    if (socketpair(AF_UNIX, socketType, 0, sockets)) return Fail(error, "provider_channel_failed");
    FD originalParent(sockets[0]), originalChild(sockets[1]);
    // All action sources live above fd3 before any stdio/capsule remapping.
    FD parent(Duplicate(originalParent.value)), worker(Duplicate(originalChild.value));
    if (parent.value < 0 || worker.value < 0) return Fail(error, "provider_channel_failed");
#ifdef SO_NOSIGPIPE
    const int one = 1;
    if (setsockopt(parent.value, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) return Fail(error, "provider_channel_failed");
#endif
    const int flags = fcntl(parent.value, F_GETFL);
    if (flags < 0 || fcntl(parent.value, F_SETFL, flags | O_NONBLOCK)) return Fail(error, "provider_channel_failed");
    posix_spawn_file_actions_t actions;
    int status = posix_spawn_file_actions_init(&actions);
    if (status) return Fail(error, "provider_spawn_failed");
    status = posix_spawn_file_actions_adddup2(&actions, worker.value, STDIN_FILENO);
    if (!status) status = posix_spawn_file_actions_adddup2(&actions, worker.value, STDOUT_FILENO);
    if (!status) status = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    if (!status && capsule) status = posix_spawn_file_actions_adddup2(&actions, capsuleFD.value, 3);
#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#if defined(CYDIA_PROVIDER_SPAWN_CLOSEFROM)
    // Applied after dup actions, closes descriptors opened concurrently too.
    if (!status) status = posix_spawn_file_actions_addclosefrom_np(&actions, capsule ? 4 : 3);
#else
    // A pre-spawn descriptor snapshot races other app threads. Platforms
    // without an atomic exec close policy must not silently leak descriptors.
    if (!status) status = ENOTSUP;
#endif
#endif
    posix_spawnattr_t attributes;
    bool attributesReady = false;
    if (!status) { status = posix_spawnattr_init(&attributes); attributesReady = !status; }
    if (!status) status = posix_spawnattr_setpgroup(&attributes, 0);
    short spawnFlags = POSIX_SPAWN_SETPGROUP;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    spawnFlags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if (!status) status = posix_spawnattr_setflags(&attributes, spawnFlags);
    std::vector<std::string> environment;
    for (char **entry = environ; entry && *entry; ++entry) {
        const std::string value(*entry);
        if (value.compare(0, 5, "DYLD_") && value.compare(0, 11, "LD_PRELOAD=") && value.compare(0, 16, "LD_LIBRARY_PATH="))
            environment.push_back(value);
    }
    std::vector<char *> env, argv;
    for (auto &value : environment) env.push_back(const_cast<char *>(value.c_str()));
    env.push_back(nullptr); argv.push_back(const_cast<char *>(executable.c_str()));
    for (const auto &value : arguments) argv.push_back(const_cast<char *>(value.c_str()));
    argv.push_back(nullptr);
    pid_t pid = -1;
    if (!status) status = posix_spawn(&pid, executable.c_str(), &actions, &attributes, argv.data(), env.data());
    if (attributesReady) posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (status) return Fail(error, "provider_spawn_failed");
    child->pid = pid; child->channel = parent.release(); return true;
}
void Terminate(pid_t child) {
    if (child <= 0) return;
    (void)kill(-child, SIGKILL); (void)kill(child, SIGKILL);
    const auto deadline = Clock::now() + std::chrono::milliseconds(100);
    for (;;) {
        int status; const auto waited = waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && errno == ECHILD)) return;
        if (!Remaining(deadline)) { std::thread(Reap, child).detach(); return; }
        poll(nullptr, 0, 5);
    }
}
ProbeRunResult RunProbe(const std::string &executable, const std::vector<std::string> &arguments,
        const std::shared_ptr<const RecoveryLaunchCapsule> &capsule, const std::string &input,
        std::string *output, std::size_t maximumOutputBytes, unsigned timeoutMilliseconds,
        const std::function<bool()> &cancelled) {
    ProbeRunResult result;
    if (output) output->clear();
    if (!output || input.size() > 256 * 1024 || !maximumOutputBytes || maximumOutputBytes > 256 * 1024 ||
        !timeoutMilliseconds || timeoutMilliseconds > MaximumRecoveryStartupMilliseconds) { result.error = EINVAL; return result; }
    if (Cancelled(cancelled)) { result.kind = ProbeExit::Cancelled; return result; }
    const auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMilliseconds);
    Child child; std::string error;
    if (!Start(executable, arguments, capsule, &child, &error)) return result;
    FD channel(child.channel);
    struct Owner {
        pid_t pid; bool reaped = false;
        explicit Owner(pid_t pid) : pid(pid) {}
        ~Owner() { if (reaped) (void)kill(-pid, SIGKILL); else Terminate(pid); }
    } owner{child.pid};
    std::size_t offset = 0; bool sentEOF = false, eof = false, exited = false; int status = 0;
    for (;;) {
        if (Cancelled(cancelled)) { result.kind = ProbeExit::Cancelled; output->clear(); return result; }
        if (!Remaining(deadline)) { result.kind = ProbeExit::TimedOut; output->clear(); return result; }
        if (offset != input.size()) {
            int sendFlags = 0;
#ifdef MSG_NOSIGNAL
            sendFlags = MSG_NOSIGNAL;
#endif
            const auto count = send(channel.value, input.data() + offset, input.size() - offset, sendFlags);
            if (count > 0) offset += count;
            else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                result.kind = ProbeExit::Failed; result.error = errno; output->clear(); return result;
            }
        }
        if (offset == input.size() && !sentEOF) { shutdown(channel.value, SHUT_WR); sentEOF = true; }
        if (!eof) {
            char bytes[8192]; const auto count = recv(channel.value, bytes, sizeof(bytes), 0);
            if (count > 0) {
                if (static_cast<std::size_t>(count) > maximumOutputBytes - output->size()) {
                    result.kind = ProbeExit::OutputLimit; output->clear(); return result;
                }
                output->append(bytes, count);
            } else if (!count) eof = true;
            else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                result.kind = ProbeExit::Failed; result.error = errno; output->clear(); return result;
            }
        }
        if (!exited) {
            const auto waited = waitpid(child.pid, &status, WNOHANG);
            if (waited == child.pid) { exited = true; owner.reaped = true; }
            else if (waited < 0 && errno != EINTR) { result.kind = ProbeExit::Failed; result.error = errno; output->clear(); return result; }
        }
        if (exited && eof) {
            if (WIFEXITED(status)) { result.kind = ProbeExit::Exited; result.code = WEXITSTATUS(status); }
            else { result.kind = ProbeExit::Signaled; result.code = WIFSIGNALED(status) ? WTERMSIG(status) : 0; }
            return result;
        }
        pollfd poller{channel.value, static_cast<short>((eof ? 0 : POLLIN) | (sentEOF ? 0 : POLLOUT)), 0};
        const int waited = poll(eof ? nullptr : &poller, eof ? 0 : 1, std::min<unsigned>(Remaining(deadline), 10));
        if (waited < 0 && errno != EINTR) { result.kind = ProbeExit::Failed; result.error = errno; output->clear(); return result; }
    }
}
} // namespace Launch
}} // namespace CydiaAPT::Provider
