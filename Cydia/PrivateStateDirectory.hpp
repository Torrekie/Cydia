// Copyright (C) 2026 Torrekie
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaRuntime {

// The caller supplies a verified parent descriptor. Repair only Cydia's own
// directory, never the parent or existing policy/configuration children.
inline bool EnsurePrivateStateDirectoryAt(int parent, const char *leaf,
                                         uid_t owner, gid_t group) {
    if (leaf == NULL || leaf[0] == '\0' || std::strchr(leaf, '/') != NULL ||
            std::strcmp(leaf, ".") == 0 || std::strcmp(leaf, "..") == 0) {
        errno = EINVAL;
        return false;
    }
    struct stat parentInfo;
    if (fstat(parent, &parentInfo) != 0)
        return false;
    if (!S_ISDIR(parentInfo.st_mode) || (parentInfo.st_uid != 0 && parentInfo.st_uid != owner) ||
            (parentInfo.st_mode & 0022) != 0) {
        errno = EPERM;
        return false;
    }
    if (mkdirat(parent, leaf, 0755) != 0 && errno != EEXIST)
        return false;
    const int fd(openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (fd == -1)
        return false;
    struct stat info;
    bool success(fstat(fd, &info) == 0);
    if (success && !S_ISDIR(info.st_mode)) {
        errno = EINVAL;
        success = false;
    }
    if (success && (info.st_uid != owner || info.st_gid != group))
        success = fchown(fd, owner, group) == 0;
    if (success)
        success = fchmod(fd, 0755) == 0;
    struct stat current;
    if (success) {
        success = fstat(fd, &info) == 0 &&
            fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0;
        if (success && (info.st_dev != current.st_dev || info.st_ino != current.st_ino ||
                !S_ISDIR(current.st_mode) || current.st_uid != owner ||
                current.st_gid != group || (current.st_mode & 07777) != 0755)) {
            errno = ESTALE;
            success = false;
        }
    }
    const int error(errno);
    close(fd);
    errno = error;
    return success;
}

} // namespace CydiaRuntime
