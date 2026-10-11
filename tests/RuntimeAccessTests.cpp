/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeAccessController.h"
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

namespace {
void Expect(bool value, const char *message) {
    if (!value) { std::cerr << "[runtime-access] FAIL: " << message << '\n'; std::exit(1); }
}
int Descriptor() {
    char path[] = "/tmp/cydia-access-lock-XXXXXX";
    int fd(mkstemp(path));
    Expect(fd >= 0 && unlink(path) == 0, "private unlinked fixture");
    Expect(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, "fixture close-on-exec descriptor");
    return fd;
}
bool Acquire(int fd) {
    struct flock lock = {};
    lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
    return fcntl(fd, F_SETLK, &lock) == 0;
}
void Tokens() {
    using CydiaRuntime::RuntimeAccess::ValidSnapshotToken;
    const std::string token(64, 'a');
    Expect(ValidSnapshotToken(token.data(), token.size()), "hex snapshot token");
    const std::string line(token + '\n');
    Expect(ValidSnapshotToken(line.data(), line.size()), "helper snapshot framing");
    Expect(!ValidSnapshotToken((token + "trailing").data(), 72), "trailing snapshot data denied");
    const std::string invalid(64, 'g');
    Expect(!ValidSnapshotToken(invalid.data(), invalid.size()) && !ValidSnapshotToken(nullptr, 64), "invalid snapshot rejected");
}
void OwnLockAndCloseRelease() {
    using CydiaRuntime::RuntimeAccess::CheckLockDescriptor;
    int fd(Descriptor()); Expect(Acquire(fd), "parent acquires actual kernel lock");
    const auto held(CheckLockDescriptor(fd, getpid(), false));
    Expect(held.passed && held.observedOwner == getpid() && fd >= 0, "child observes exact caller owner and cannot bypass lock");
    const auto released(CheckLockDescriptor(fd, getpid(), true));
    Expect(released.passed && released.observedOwner == 0 && fd == -1, "close releases parent lock and child can acquire/release");
}
void MissingAndForeignLocks() {
    using CydiaRuntime::RuntimeAccess::CheckLockDescriptor;
    int fd(Descriptor());
    const auto missing(CheckLockDescriptor(fd, getpid(), false));
    Expect(!missing.passed && missing.observedOwner == 0, "unlocked descriptor is never a successful ownership check");
    int ready[2], release[2];
    Expect(pipe(ready) == 0 && pipe(release) == 0, "foreign lock synchronization");
    const pid_t foreign(fork()); Expect(foreign >= 0, "start isolated foreign owner");
    if (foreign == 0) {
        close(ready[0]); close(release[1]);
        if (!Acquire(fd) || write(ready[1], "R", 1) != 1) _exit(1);
        char done;
        if (read(release[0], &done, 1) != 1) _exit(2);
        close(fd); _exit(0);
    }
    close(ready[1]); close(release[0]); char started;
    Expect(read(ready[0], &started, 1) == 1 && started == 'R', "foreign lock is held");
    const auto held(CheckLockDescriptor(fd, getpid(), false));
    Expect(!held.passed && held.busy && held.observedOwner == foreign, "report foreign owner without changing its lock");
    Expect(write(release[1], "D", 1) == 1, "release only owned fixture process");
    close(ready[0]); close(release[1]);
    int status; Expect(waitpid(foreign, &status, 0) == foreign && WIFEXITED(status) && WEXITSTATUS(status) == 0, "foreign fixture exits");
    close(fd);
    int invalid(-1);
    Expect(CheckLockDescriptor(invalid, getpid(), false).errorNumber == EINVAL, "invalid descriptor denied without fork");
}
}
int main() {
    Tokens(); OwnLockAndCloseRelease(); MissingAndForeignLocks();
    std::cout << "[runtime-access] PASS\n";
}
