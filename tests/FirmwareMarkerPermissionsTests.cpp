/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "Cydia/FirmwareMarkerPermissions.hpp"
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

static void Expect(bool value, const char *message) {
    if (!value) {
        std::cerr << "[firmware-marker][FAIL] " << message << std::endl;
        std::exit(1);
    }
}

int main() {
    char temporary[] = "/tmp/cydia-firmware-marker.XXXXXX";
    Expect(mkdtemp(temporary) != NULL, "temporary directory");
    const std::string base(temporary), marker(base + "/firmware.ver");
    using CydiaRuntime::RepairFirmwareMarkerPermissions;
    Expect(RepairFirmwareMarkerPermissions(marker.c_str()), "missing marker is allowed");
    Expect(access(marker.c_str(), F_OK) == -1, "missing marker is not manufactured");
    int fd(open(marker.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600));
    Expect(fd >= 0 && write(fd, "5\n", 2) == 2 && close(fd) == 0, "old version fixture");
    struct stat before, after;
    Expect(stat(marker.c_str(), &before) == 0, "prestate");
    Expect(RepairFirmwareMarkerPermissions(marker.c_str()), "repair existing root-only mode");
    Expect(stat(marker.c_str(), &after) == 0 && (after.st_mode & 07777) == 0644, "mobile-readable mode");
    Expect(before.st_uid == after.st_uid && before.st_gid == after.st_gid, "ownership preserved");
    char content[3] = {};
    fd = open(marker.c_str(), O_RDONLY);
    Expect(fd >= 0 && read(fd, content, 3) == 2 && close(fd) == 0 &&
           std::strcmp(content, "5\n") == 0, "version bytes are not rewritten to 6");
    Expect(RepairFirmwareMarkerPermissions(marker.c_str()), "idempotent repair");
    Expect(chmod(marker.c_str(), 0600) == 0, "symlink target prestate");
    const std::string link(base + "/link"), fifo(base + "/fifo"), directory(base + "/directory");
    Expect(symlink(marker.c_str(), link.c_str()) == 0, "symlink fixture");
    Expect(!RepairFirmwareMarkerPermissions(link.c_str()), "symlink rejected");
    Expect(stat(marker.c_str(), &after) == 0 && (after.st_mode & 07777) == 0600, "symlink target unchanged");
    Expect(mkfifo(fifo.c_str(), 0600) == 0, "fifo fixture");
    Expect(!RepairFirmwareMarkerPermissions(fifo.c_str()), "fifo rejected without blocking");
    Expect(mkdir(directory.c_str(), 0700) == 0, "directory fixture");
    Expect(!RepairFirmwareMarkerPermissions(directory.c_str()), "directory rejected");
    Expect(stat(directory.c_str(), &after) == 0 && (after.st_mode & 07777) == 0700, "directory mode unchanged");
    Expect(unlink(link.c_str()) == 0 && unlink(fifo.c_str()) == 0 &&
           unlink(marker.c_str()) == 0 && rmdir(directory.c_str()) == 0 &&
           rmdir(base.c_str()) == 0, "owned fixture cleanup");
    std::cout << "[firmware-marker][ ok ] existing/missing/content/owner/idempotence/symlink/fifo/directory" << std::endl;
}
