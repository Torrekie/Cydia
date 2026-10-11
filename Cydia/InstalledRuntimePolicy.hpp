/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_InstalledRuntimePolicy_HPP
#define Cydia_InstalledRuntimePolicy_HPP

#include "Cydia/DpkgAdminAccess.hpp"
#include <fcntl.h>
#include <cstdio>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaRuntime { namespace InstalledPolicy {

enum class Result { Created, Preserved, Refused };

inline bool AbsolutePath(const std::string &path) {
    if (path.empty() || path[0] != '/' || path.size() > 4096 ||
        path.find_first_of("\n\r") != std::string::npos || path.find('\0') != std::string::npos ||
        path.find("//") != std::string::npos) return false;
    for (std::size_t start = 1; start < path.size();) {
        const std::size_t end(path.find('/', start));
        const std::string component(path.substr(start, end - start));
        if (component == "." || component == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return true;
}

/* This input belongs to the root dpkg installer, never an app request. Older
 * dpkg may omit DPKG_ADMINDIR; only its installed absolute control-file path
 * supplies a fallback. Package layout guesses must not select the database. */
inline std::string InstallerAdminDirectory(const char *declared, const char *controlPath) {
    if (declared != NULL && declared[0] != '\0')
        return AbsolutePath(declared) ? std::string(declared) : std::string();
    const std::string control(controlPath == NULL ? "" : controlPath);
    const std::string suffix("/info/cydia.postinst");
    struct stat identity;
    if (!AbsolutePath(control) || control.size() <= suffix.size() ||
        control.compare(control.size() - suffix.size(), suffix.size(), suffix) != 0 ||
        lstat(control.c_str(), &identity) != 0 || !S_ISREG(identity.st_mode) ||
        identity.st_uid != 0 || identity.st_nlink != 1 ||
        (identity.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID)) != 0) return {};
    AdminAccess::Review controlDirectory;
    if (!AdminAccess::Collect(control.substr(0, control.find_last_of('/')), &controlDirectory)) return {};
    return control.substr(0, control.size() - suffix.size());
}

inline bool PrivateDirectory(int directory) {
    struct stat identity;
    return getuid() == 0 && geteuid() == 0 && fstat(directory, &identity) == 0 &&
        S_ISDIR(identity.st_mode) && identity.st_uid == 0 &&
        (identity.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID | S_ISVTX)) == 0;
}

/* Publish only an absent Cydia-private policy. The hard-link publication is
 * atomic and exclusive: a concurrent user decision always remains intact.
 * Existing bytes, including an empty explicit revocation, are never replaced. */
inline Result CreateAbsentAt(int directory, const char *leaf, const std::string &bytes, mode_t mode = 0600) {
    if (!PrivateDirectory(directory) || leaf == NULL || leaf[0] == '\0' ||
        std::strchr(leaf, '/') != NULL || std::strcmp(leaf, ".") == 0 || std::strcmp(leaf, "..") == 0 ||
        (mode != 0600 && mode != 0644)) {
        errno = EPERM; return Result::Refused;
    }
    struct stat existing;
    if (fstatat(directory, leaf, &existing, AT_SYMLINK_NOFOLLOW) == 0) return Result::Preserved;
    if (errno != ENOENT) return Result::Refused;
    static unsigned sequence(0);
    const std::string temporary(std::string(".") + leaf + ".install." +
        std::to_string(getpid()) + '.' + std::to_string(++sequence));
    const int file(openat(directory, temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (file < 0) return Result::Refused;
    bool success(true);
    for (std::size_t offset = 0; offset < bytes.size();) {
        const ssize_t count(write(file, bytes.data() + offset, bytes.size() - offset));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { success = false; break; }
        offset += count;
    }
    if (success) success = fchmod(file, mode) == 0 && fsync(file) == 0;
    const int writeError(errno); close(file);
    Result result(Result::Refused);
    if (success) {
        if (linkat(directory, temporary.c_str(), directory, leaf, 0) == 0) result = Result::Created;
        else if (errno == EEXIST) result = Result::Preserved;
    } else errno = writeError;
    const int saved(errno); unlinkat(directory, temporary.c_str(), 0);
    if (result == Result::Created && fsync(directory) != 0 && errno != EINVAL) return Result::Refused;
    errno = saved;
    return result;
}

inline Result InitializeAdminAccessAt(int directory, const std::string &admin) {
    if (!PrivateDirectory(directory)) { errno = EPERM; return Result::Refused; }
    struct stat previous;
    if (fstatat(directory, "admin-access.lock", &previous, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISREG(previous.st_mode) || previous.st_uid != 0 || previous.st_nlink != 1 ||
            (previous.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID)) != 0) {
            errno = EPERM; return Result::Refused;
        }
    } else if (errno != ENOENT) return Result::Refused;
    const int lock(openat(directory, "admin-access.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600));
    if (lock < 0) return Result::Refused;
    struct stat identity;
    struct flock action = {};
    action.l_type = F_WRLCK; action.l_whence = SEEK_SET;
    const bool locked(fstat(lock, &identity) == 0 && S_ISREG(identity.st_mode) &&
        identity.st_uid == 0 && identity.st_nlink == 1 &&
        (identity.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID)) == 0 &&
        fcntl(lock, F_SETLK, &action) == 0);
    Result result(Result::Refused);
    if (locked) {
        struct stat existing;
        if (fstatat(directory, "admin-access.conf", &existing, AT_SYMLINK_NOFOLLOW) == 0)
            result = Result::Preserved;
        else if (errno == ENOENT) {
            AdminAccess::Review review, current;
            if (AbsolutePath(admin) && AdminAccess::Collect(admin, &review) &&
                AdminAccess::Collect(admin, &current) && review.token == current.token) {
                const std::string installed(AdminAccess::InstalledToken(review));
                // The mobile app independently resolves this data-only
                // metadata before calling the authenticated root helper.
                if (!installed.empty()) result = CreateAbsentAt(directory, "admin-access.conf", installed, 0644);
                else errno = EOVERFLOW;
            }
            else errno = EPERM;
        }
    }
    const int saved(errno); close(lock); errno = saved;
    return result;
}

inline Result InitializeSourceProtectionAt(int directory) {
    // SerializeProtectionPolicy({}): no distribution source is inferred by
    // installing Cydia. Explicit selections saved by users stay authoritative.
    // The native UI reads these data-only roles; root alone may change them.
    return CreateAbsentAt(directory, "source-protection", "CYDIA-SOURCE-PROTECTION-1\n1:0,", 0644);
}

} }
#endif
