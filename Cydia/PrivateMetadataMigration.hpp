// Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaRuntime {
inline bool PrivateMetadataLeaf(const char *leaf) {
    return leaf != NULL && leaf[0] != '\0' && std::strchr(leaf, '/') == NULL &&
        std::strcmp(leaf, ".") != 0 && std::strcmp(leaf, "..") != 0;
}
inline bool PrivateMetadataStable(const struct stat &before, const struct stat &after) {
    if (before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
            before.st_size != after.st_size || before.st_nlink != after.st_nlink)
        return false;
#if defined(__APPLE__)
    return before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec;
#else
    return before.st_mtim.tv_sec == after.st_mtim.tv_sec && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec &&
        before.st_ctim.tv_sec == after.st_ctim.tv_sec && before.st_ctim.tv_nsec == after.st_ctim.tv_nsec;
#endif
}

// Source/destination parents are already verified private directory handles.
// Copy then publish without replacement; remove only the unchanged source
// filename after publication. Existing destinations and unrelated files stay.
inline bool MigratePrivateMetadataAt(int sourceParent, const char *sourceLeaf,
                                    int destinationParent, const char *destinationLeaf,
                                    uid_t owner, gid_t group) {
    if (!PrivateMetadataLeaf(sourceLeaf) || !PrivateMetadataLeaf(destinationLeaf)) {
        errno = EINVAL;
        return false;
    }
    struct stat sourceDirectory, destinationDirectory;
    if (fstat(sourceParent, &sourceDirectory) != 0 || fstat(destinationParent, &destinationDirectory) != 0)
        return false;
    if (!S_ISDIR(sourceDirectory.st_mode) || !S_ISDIR(destinationDirectory.st_mode) ||
            (sourceDirectory.st_uid != 0 && sourceDirectory.st_uid != owner) ||
            destinationDirectory.st_uid != owner ||
            (sourceDirectory.st_mode & 0022) != 0 || (destinationDirectory.st_mode & 0022) != 0) {
        errno = EPERM;
        return false;
    }
    struct stat existing;
    if (fstatat(destinationParent, destinationLeaf, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
        if (S_ISREG(existing.st_mode) && existing.st_nlink == 1 && existing.st_uid == owner &&
                (existing.st_mode & 0022) == 0)
            return true;
        errno = EPERM;
        return false;
    }
    if (errno != ENOENT)
        return false;
    const int source(openat(sourceParent, sourceLeaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    if (source < 0)
        return errno == ENOENT;
    struct stat before;
    bool success(fstat(source, &before) == 0);
    if (success && (!S_ISREG(before.st_mode) || before.st_nlink != 1 ||
            (before.st_uid != 0 && before.st_uid != owner) || (before.st_mode & 0022) != 0 ||
            before.st_size < 0 || before.st_size > 128 * 1024 * 1024)) {
        errno = EPERM;
        success = false;
    }
    std::string temporary;
    int output(-1);
    if (success) {
        for (unsigned attempt = 0; attempt < 128; ++attempt) {
            temporary = ".cydia-metadata." + std::to_string(getpid()) + "." + std::to_string(attempt);
            output = openat(destinationParent, temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (output >= 0 || errno != EEXIST)
                break;
        }
        success = output >= 0;
    }
    char buffer[16384];
    off_t total(0);
    while (success) {
        const ssize_t count(read(source, buffer, sizeof(buffer)));
        if (count < 0 && errno == EINTR)
            continue;
        if (count < 0) { success = false; break; }
        if (count == 0)
            break;
        total += count;
        if (total > before.st_size) { errno = ESTALE; success = false; break; }
        ssize_t offset(0);
        while (offset < count) {
            const ssize_t written(write(output, buffer + offset, count - offset));
            if (written < 0 && errno == EINTR)
                continue;
            if (written <= 0) { success = false; break; }
            offset += written;
        }
    }
    struct stat after, named;
    if (success) {
        success = fstat(source, &after) == 0 &&
            fstatat(sourceParent, sourceLeaf, &named, AT_SYMLINK_NOFOLLOW) == 0;
        if (success && (total != before.st_size || !PrivateMetadataStable(before, after) ||
                !PrivateMetadataStable(before, named))) {
            errno = ESTALE;
            success = false;
        }
    }
    if (success)
        success = fchown(output, owner, group) == 0 && fchmod(output, 0644) == 0 && fsync(output) == 0;
    bool published(false);
    if (success) {
        success = linkat(destinationParent, temporary.c_str(), destinationParent, destinationLeaf, 0) == 0;
        published = success;
    }
    const int error(errno);
    if (output >= 0) {
        close(output);
        if (unlinkat(destinationParent, temporary.c_str(), 0) != 0 && published)
            success = false;
        else
            errno = error;
    }
    if (success && fsync(destinationParent) != 0 && errno != EINVAL)
        success = false;
    if (success) {
        success = fstatat(sourceParent, sourceLeaf, &named, AT_SYMLINK_NOFOLLOW) == 0;
        if (success && !PrivateMetadataStable(before, named)) { errno = ESTALE; success = false; }
        if (success)
            success = unlinkat(sourceParent, sourceLeaf, 0) == 0;
        if (success && fsync(sourceParent) != 0 && errno != EINVAL)
            success = false;
    }
    close(source);
    // A published destination is never rolled back after a late error. The
    // source stays available unless its exact, unchanged filename was moved.
    return success;
}
} // namespace CydiaRuntime
