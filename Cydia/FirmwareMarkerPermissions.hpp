// Copyright (C) 2026 Torrekie
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaRuntime {

// Upgrade an existing completion marker without creating it or changing its
// version. The mobile app must be able to read a marker written by root.
inline bool RepairFirmwareMarkerPermissions(const char *path) {
    const int fd(open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK));
    if (fd == -1)
        return errno == ENOENT;
    struct stat info;
    bool success(fstat(fd, &info) == 0);
    if (success && !S_ISREG(info.st_mode)) {
        errno = EINVAL;
        success = false;
    }
    if (success)
        success = fchmod(fd, 0644) == 0;
    const int error(errno);
    close(fd);
    errno = error;
    return success;
}

} // namespace CydiaRuntime
