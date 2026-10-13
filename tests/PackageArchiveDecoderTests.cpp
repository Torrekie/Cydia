/* Bounded decoder I/O using this fixture executable, never system codecs.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PackageArchiveReader.hpp"
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <iostream>
#include <stdexcept>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
namespace {
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[archive-decoder] " << message << '\n'; std::exit(1); }
}
int Child(const std::string &mode) {
    std::size_t count = 0; for (char **entry = environ; *entry; ++entry) ++count;
    if (count != 2 || !getenv("LANG") || std::strcmp(getenv("LANG"), "C") ||
        !getenv("LC_ALL") || std::strcmp(getenv("LC_ALL"), "C")) return 8;
    if (mode == "signal") { raise(SIGTERM); return 9; }
    if (mode == "close-hang") close(STDOUT_FILENO);
    if (mode == "hang" || mode == "close-hang") for (;;) pause();
    if (mode == "descendant") {
        const auto child = fork(); if (child < 0) return 9;
        if (child == 0) for (;;) pause();
        return 0; // Descendant retains stdout until the group is cancelled.
    }
    if (mode == "descendant-eof") {
        const auto child = fork(); if (child < 0) return 9;
        if (child != 0) return 0;
        alarm(5); // A regressed implementation must not leave a fixture process.
        // A native record lock proves this exact descendant remains alive,
        // without relying on /proc or platform-specific zombie inspection.
        struct flock request{}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
        if (fcntl(STDIN_FILENO, F_SETLK, &request) != 0) return 9;
        char identity[32]; const int length = std::snprintf(identity, sizeof(identity), "%ld\n", static_cast<long>(getpid()));
        if (length <= 0 || write(STDOUT_FILENO, identity, length) != length) return 9;
        close(STDOUT_FILENO);
        for (;;) pause(); // Success and EOF must still terminate this member.
    }
    unsigned char bytes[8192];
    for (;;) {
        const auto size = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (size == 0) break;
        if (size < 0) { if (errno == EINTR) continue; return 9; }
        std::size_t offset = 0;
        while (offset < static_cast<std::size_t>(size)) {
            const auto written = write(STDOUT_FILENO, bytes + offset, size - offset);
            if (written > 0) offset += written;
            else if (errno != EINTR) return 9;
        }
    }
    return mode == "failure" ? 2 : 0;
}
struct Input {
    int descriptor = -1;
    explicit Input(const std::string &bytes) {
        char name[] = "/tmp/cydia-decoder-XXXXXX"; descriptor = mkstemp(name);
        Require(descriptor >= 0 && unlink(name) == 0, "private unlinked input");
        std::size_t offset = 0;
        while (offset < bytes.size()) {
            const auto amount = write(descriptor, bytes.data() + offset, bytes.size() - offset);
            Require(amount > 0, "write fixture input"); offset += amount;
        }
    }
    ~Input() { if (descriptor >= 0) close(descriptor); }
    int Rewind() { Require(lseek(descriptor, 0, SEEK_SET) == 0, "rewind retained input"); return descriptor; }
};
void Cases(const std::string &executable) {
    const std::string payload(180000, 'x'); Input input(payload); std::string bytes;
    const auto consume = [&](const unsigned char *chunk, std::size_t size) {
        bytes.append(reinterpret_cast<const char *>(chunk), size); return true;
    };
    Require(CydiaPackages::StreamArchiveDecoder(input.Rewind(), executable, {"--decoder", "copy"}, payload.size(), 3000, consume) &&
        bytes == payload, "bounded stream validates EOF and actual successful exit under a minimal owned environment");
    bytes.clear();
    Require(!CydiaPackages::StreamArchiveDecoder(input.Rewind(), executable, {"--decoder", "failure"}, payload.size(), 3000, consume) &&
        bytes == payload, "provisional output does not hide invalid compressed trailer exit");
    for (const char *mode : {"hang", "close-hang", "descendant"}) {
        bytes.clear(); const auto start = std::chrono::steady_clock::now();
        Require(!CydiaPackages::StreamArchiveDecoder(input.Rewind(), executable, {"--decoder", mode}, payload.size(), 80, consume),
            "stalled output, post-EOF child and inherited pipe cannot block completion");
        Require(std::chrono::steady_clock::now() - start < std::chrono::seconds(3), "decoder timeout bounded");
    }
    {
        pid_t descendant = -1;
        const CydiaPackages::ArchiveDecodedConsumer retained = [&](const unsigned char *chunk, std::size_t size) {
            const std::string identity(reinterpret_cast<const char *>(chunk), size); char *end = nullptr;
            const long parsed = std::strtol(identity.c_str(), &end, 10);
            Require(parsed > 1 && end && *end == '\n' && end[1] == '\0', "exact retained descendant identity");
            descendant = static_cast<pid_t>(parsed);
            struct flock owner{}; owner.l_type = F_WRLCK; owner.l_whence = SEEK_SET;
            Require(fcntl(input.descriptor, F_GETLK, &owner) == 0 && owner.l_type == F_WRLCK && owner.l_pid == descendant,
                "same-group descendant is alive after closing output and before successful settlement");
            return true;
        };
        Require(CydiaPackages::StreamArchiveDecoder(input.Rewind(), executable, {"--decoder", "descendant-eof"}, 100, 3000, retained),
            "successful leader and EOF still settle the owned decoder group");
        const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(2); bool settled = false;
        while (std::chrono::steady_clock::now() < end) {
            struct flock owner{}; owner.l_type = F_WRLCK; owner.l_whence = SEEK_SET;
            Require(fcntl(input.descriptor, F_GETLK, &owner) == 0, "observe retained descendant settlement");
            if (owner.l_type == F_UNLCK) { settled = true; break; }
            Require(owner.l_pid == descendant, "only the fixture descendant can retain its private input lock");
            (void) poll(nullptr, 0, 10);
        }
        Require(settled, "no live descendant survives successful decoder completion");
    }
    for (unsigned variant = 0; variant != 4; ++variant) {
        bytes.clear(); const auto start = std::chrono::steady_clock::now();
        const auto cancel = [&] { return std::chrono::steady_clock::now() - start >= std::chrono::milliseconds(50); };
        const CydiaPackages::ArchiveDecodedConsumer selected = variant == 1 ? CydiaPackages::ArchiveDecodedConsumer(
            [](const unsigned char *, std::size_t) { return false; }) : variant == 2 ? CydiaPackages::ArchiveDecodedConsumer(
            [](const unsigned char *, std::size_t) -> bool { throw std::runtime_error("fixture refusal"); }) : consume;
        Require(!CydiaPackages::StreamArchiveDecoder(input.Rewind(), executable,
            {"--decoder", variant == 0 ? "hang" : variant == 3 ? "signal" : "copy"}, payload.size(), 3000,
            selected, variant == 0 ? std::function<bool()>(cancel) : std::function<bool()>()),
            "cancellation, refusal, exception and signal never yield complete success");
        Require(std::chrono::steady_clock::now() - start < std::chrono::seconds(3), "failure settlement bounded");
    }
    bytes.clear();
    Require(!CydiaPackages::StreamArchiveDecoder(input.Rewind(), executable, {"--decoder", "copy"}, 100, 3000, consume) && bytes.empty(),
        "excess output is rejected before publishing its chunk");
    Require(!CydiaPackages::StreamArchiveDecoder(input.Rewind(), "relative-tool", {}, 100, 3000, consume) &&
        !CydiaPackages::StreamArchiveDecoder(input.Rewind(), executable, {std::string(4097, 'x')}, 100, 3000, consume) &&
        !CydiaPackages::StreamArchiveDecoder(input.Rewind(), executable, {}, 100, 0, consume), "invalid launches refuse");
    int pipes[2]; Require(pipe(pipes) == 0, "nonregular input fixture");
    Require(!CydiaPackages::StreamArchiveDecoder(pipes[0], executable, {}, 100, 100, consume), "unbounded input pipe is not a retained regular source");
    close(pipes[0]); close(pipes[1]);
    int status; errno = 0;
    Require(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD, "every direct decoder child was reaped");
}
}
int main(int argc, char **argv) {
    if (argc == 3 && std::string(argv[1]) == "--decoder") return Child(argv[2]);
    char *absolute = realpath(argv[0], nullptr); Require(absolute, "absolute fixture executable");
    const std::string executable(absolute); free(absolute); Cases(executable);
    std::cout << "PackageArchiveDecoder tests passed\n";
}
