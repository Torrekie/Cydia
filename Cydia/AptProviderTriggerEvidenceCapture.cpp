/* Protected, bounded read-only capture; separate from pure trigger syntax.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEvidence.hpp"
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <dirent.h>
#include <fcntl.h>
#include <mutex>
#include <thread>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
using Clock = std::chrono::steady_clock;
// POSIX locks belong to the process, not individual descriptors. Serializing
// captures prevents one capture's close from dropping another capture's lock.
std::mutex captureMutex;
struct Descriptor {
    int value;
    explicit Descriptor(int fd = -1) : value(fd) {}
    ~Descriptor() { if (value >= 0) close(value); }
    Descriptor(const Descriptor &) = delete;
    Descriptor &operator=(const Descriptor &) = delete;
};
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Active(const Clock::time_point &deadline, const std::function<bool()> &cancelled, std::string *error) {
    if (cancelled && cancelled()) return Fail(error, "provider_trigger_capture_cancelled");
    return Clock::now() < deadline || Fail(error, "provider_trigger_capture_timeout");
}
bool Protected(const struct stat &identity, bool directory) {
    return identity.st_uid == 0 && (identity.st_mode & 0022) == 0 &&
        (directory ? S_ISDIR(identity.st_mode) : S_ISREG(identity.st_mode) && identity.st_nlink == 1);
}
bool Same(const struct stat &a, const struct stat &b) {
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_uid != b.st_uid || a.st_gid != b.st_gid ||
        a.st_mode != b.st_mode || a.st_nlink != b.st_nlink || a.st_size != b.st_size) return false;
#ifdef __APPLE__
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
bool Membership(int directory, P::Evidence *evidence, std::string *error,
                const Clock::time_point &deadline, const std::function<bool()> &cancelled) {
    if (fstat(directory, &evidence->identity) != 0 || !Protected(evidence->identity, true))
        return Fail(error, "provider_trigger_directory_unsafe");
    // An independently opened description avoids sharing readdir offsets with
    // the anchored descriptor or a previous capture.
    const int copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (copy < 0) return Fail(error, "provider_trigger_directory_unavailable");
    DIR *stream = fdopendir(copy);
    if (!stream) { close(copy); return Fail(error, "provider_trigger_directory_unavailable"); }
    bool valid = true;
    while (true) {
        if (!Active(deadline, cancelled, error)) { valid = false; break; }
        errno = 0; const struct dirent *entry = readdir(stream);
        if (!entry) { if (errno) valid = Fail(error, "provider_trigger_directory_unavailable"); break; }
        const std::string name(entry->d_name);
        if (name == "." || name == "..") continue;
        if (name.size() > 256 || evidence->entries.size() >= MaximumTriggerRegistryFiles) {
            valid = Fail(error, "provider_trigger_evidence_limit"); break;
        }
        evidence->entries.push_back(name);
    }
    closedir(stream);
    if (!valid) return false;
    std::sort(evidence->entries.begin(), evidence->entries.end());
    struct stat after;
    return (fstat(directory, &after) == 0 && Same(evidence->identity, after)) ||
        Fail(error, "provider_trigger_state_changed");
}
bool ReadLeaf(int directory, const std::string &name, const std::string &path,
              std::size_t *remaining, P::Evidence *evidence, std::string *error,
              const Clock::time_point &deadline, const std::function<bool()> &cancelled) {
    *evidence = P::Evidence(); evidence->path = path; evidence->adminAccess = true;
    struct stat named;
    if (fstatat(directory, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0 || !Protected(named, false))
        return Fail(error, "provider_trigger_file_unsafe");
    const std::size_t limit = std::min(*remaining,
        name == "Unincorp" ? MaximumDeferredTriggerBytes : MaximumTriggerEvidenceBytes);
    if (named.st_size < 0 || static_cast<uint64_t>(named.st_size) > limit)
        return Fail(error, "provider_trigger_evidence_limit");
    // O_NONBLOCK prevents a substituted FIFO from blocking before fstat.
    Descriptor file(openat(directory, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK));
    if (file.value < 0 || fstat(file.value, &evidence->identity) != 0 ||
        !Protected(evidence->identity, false) || !Same(named, evidence->identity))
        return Fail(error, "provider_trigger_file_unsafe");
    char buffer[16384];
    while (true) {
        if (!Active(deadline, cancelled, error)) return false;
        const ssize_t count = read(file.value, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return Fail(error, "provider_trigger_file_unavailable");
        if (count == 0) break;
        if (static_cast<std::size_t>(count) > limit - evidence->bytes.size())
            return Fail(error, "provider_trigger_evidence_limit");
        evidence->bytes.append(buffer, count);
    }
    struct stat opened, after;
    if (fstat(file.value, &opened) != 0 || fstatat(directory, name.c_str(), &after, AT_SYMLINK_NOFOLLOW) != 0 ||
        !Same(evidence->identity, opened) || !Same(opened, after) ||
        static_cast<uint64_t>(opened.st_size) != evidence->bytes.size())
        return Fail(error, "provider_trigger_state_changed");
    *remaining -= evidence->bytes.size(); return true;
}
bool ReadDirectory(int directory, int lock, const std::string &path,
                   ProtectedTriggerEvidence *result, std::string *error,
                   const Clock::time_point &deadline, const std::function<bool()> &cancelled) {
    P::Evidence folder = P::Evidence(); folder.path = path; folder.directory = true; folder.adminAccess = true;
    if (!Membership(directory, &folder, error, deadline, cancelled)) return false;
    if (lock >= 0 && !std::binary_search(folder.entries.begin(), folder.entries.end(), "Lock"))
        return Fail(error, "provider_trigger_state_changed");
    result->files.push_back(folder);
    std::size_t remaining = MaximumTriggerEvidenceBytes;
    for (const auto &name : folder.entries) {
        P::Evidence leaf;
        if (name == "Lock" && lock >= 0) {
            // Never reopen/close the locked inode in this process: that would
            // silently drop the retained POSIX lock.
            leaf = P::Evidence(); leaf.path = path + "/Lock"; leaf.adminAccess = true;
            struct stat named;
            if (fstat(lock, &leaf.identity) != 0 || !Protected(leaf.identity, false) || leaf.identity.st_size != 0 ||
                fstatat(directory, "Lock", &named, AT_SYMLINK_NOFOLLOW) != 0 || !Same(leaf.identity, named))
                return Fail(error, "provider_trigger_lock_invalid");
        } else if (!ReadLeaf(directory, name, path + '/' + name, &remaining, &leaf, error, deadline, cancelled)) return false;
        result->files.push_back(std::move(leaf));
    }
    for (const char *name : {"File", "Unincorp", "Lock"}) {
        if (std::binary_search(folder.entries.begin(), folder.entries.end(), name)) continue;
        P::Evidence absent = P::Evidence(); absent.path = path + '/' + name; absent.absent = true; absent.adminAccess = true;
        result->files.push_back(absent);
    }
    P::Evidence after = P::Evidence();
    if (!Membership(directory, &after, error, deadline, cancelled)) return false;
    if (!Same(folder.identity, after.identity) || folder.entries != after.entries)
        return Fail(error, "provider_trigger_state_changed");
    return true;
}
bool SameFiles(const std::vector<P::Evidence> &a, const std::vector<P::Evidence> &b) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) {
        if (a[i].path != b[i].path || a[i].directory != b[i].directory || a[i].absent != b[i].absent ||
            a[i].bytes != b[i].bytes || a[i].entries != b[i].entries ||
            (!a[i].absent && !Same(a[i].identity, b[i].identity))) return false;
    }
    return true;
}
}
bool CaptureProtectedTriggerFiles(const P::Environment &environment,
    std::vector<P::Evidence> *files, bool *synchronized, std::string *error, const std::function<bool()> &cancelled,
    unsigned timeoutMilliseconds) {
    if (!files || !synchronized) return Fail(error, "provider_trigger_input_invalid");
    files->clear(); *synchronized = false; if (error) error->clear();
    if (timeoutMilliseconds == 0 || timeoutMilliseconds > 10000 || environment.dpkgAdmin.empty())
        return Fail(error, "provider_trigger_input_invalid");
    const auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMilliseconds);
    std::unique_lock<std::mutex> serialized(captureMutex, std::defer_lock);
    while (!serialized.try_lock()) {
        if (!Active(deadline, cancelled, error)) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (!Active(deadline, cancelled, error)) return false;
    const std::string path(environment.dpkgAdmin + "/triggers");
    P::Error ignored; struct stat named;
    if (!P::ValidateDpkgAdminPath(environment.dpkgAdmin, true, &ignored))
        return Fail(error, "provider_trigger_directory_unsafe");
    if (lstat(path.c_str(), &named) != 0) {
        if (errno != ENOENT) return Fail(error, "provider_trigger_directory_unavailable");
        P::Evidence absent;
        if (!P::CaptureAdminEvidence(path, true, true, &absent, &ignored) || !absent.absent ||
            !P::RecheckEvidence({absent}, &ignored)) return Fail(error, "provider_trigger_state_changed");
        if (!Active(deadline, cancelled, error)) return false;
        files->push_back(absent); return true;
    }
    if (!Protected(named, true) || !P::ValidateDpkgAdminPath(path, true, &ignored))
        return Fail(error, "provider_trigger_directory_unsafe");
    Descriptor directory(open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    struct stat opened;
    if (directory.value < 0 || fstat(directory.value, &opened) != 0 || !Same(named, opened))
        return Fail(error, "provider_trigger_state_changed");
    Descriptor lock;
    struct stat lockIdentity;
    if (fstatat(directory.value, "Lock", &lockIdentity, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!Protected(lockIdentity, false) || lockIdentity.st_size != 0)
            return Fail(error, "provider_trigger_lock_invalid");
        lock.value = openat(directory.value, "Lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        if (lock.value < 0 || fstat(lock.value, &opened) != 0 || !Same(lockIdentity, opened))
            return Fail(error, "provider_trigger_lock_invalid");
        struct flock request = {}; request.l_type = F_RDLCK; request.l_whence = SEEK_SET;
        while (fcntl(lock.value, F_SETLK, &request) != 0) {
            if (errno != EACCES && errno != EAGAIN && errno != EINTR)
                return Fail(error, "provider_trigger_lock_unavailable");
            if (!Active(deadline, cancelled, error)) return false;
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    } else if (errno != ENOENT) return Fail(error, "provider_trigger_lock_unavailable");
    ProtectedTriggerEvidence first, second;
    first.synchronized = second.synchronized = lock.value >= 0;
    if (!ReadDirectory(directory.value, lock.value, path, &first, error, deadline, cancelled) ||
        !ReadDirectory(directory.value, lock.value, path, &second, error, deadline, cancelled)) return false;
    if (!SameFiles(first.files, second.files) ||
        !P::ValidateDpkgAdminPath(path, true, &ignored) || lstat(path.c_str(), &named) != 0 ||
        !Same(first.files.front().identity, named))
        return Fail(error, "provider_trigger_state_changed");
    if (!Active(deadline, cancelled, error)) return false;
    *files = std::move(second.files); *synchronized = second.synchronized; return true;
}
}} // namespace CydiaAPT::Provider
