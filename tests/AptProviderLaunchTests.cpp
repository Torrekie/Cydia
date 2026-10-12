/* Real child descriptor/spool/deadline fixtures; no provider or package state.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderLaunch.hpp"
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <iostream>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
extern char **environ;
namespace {
using namespace CydiaAPT::Provider;
void Require(bool good, const char *message) {
    if (good) return;
    std::cerr << "[provider-launch] " << message << '\n'; std::exit(1);
}
std::string Executable() {
#ifdef __APPLE__
    uint32_t size = 0; _NSGetExecutablePath(nullptr, &size);
    std::string path(size, '\0'); Require(_NSGetExecutablePath(&path[0], &size) == 0, "read test executable");
    path.resize(std::strlen(path.c_str()));
#else
    char bytes[4096]; const auto size = readlink("/proc/self/exe", bytes, sizeof(bytes));
    Require(size > 0 && static_cast<std::size_t>(size) < sizeof(bytes), "read test executable");
    std::string path(bytes, size);
#endif
    char *resolved = realpath(path.c_str(), nullptr); Require(resolved, "resolve test executable");
    path = resolved; free(resolved); return path;
}
std::string Payload() {
    std::string result(MaximumRecoveryCapsuleBytes, '\0');
    for (std::size_t i = 0; i < result.size(); ++i) result[i] = static_cast<char>((i * 37) % 251);
    const std::string marker = "private-capsule-test-token";
    result.replace(0, marker.size(), marker); return result;
}
bool WriteAll(int fd, const std::string &value) {
    for (std::size_t offset = 0; offset < value.size();) {
        const auto count = write(fd, value.data() + offset, value.size() - offset);
        if (count > 0) offset += count;
        else if (count < 0 && errno == EINTR) continue;
        else return false;
    }
    return true;
}
int Child(int argc, char **argv) {
    const std::string mode = argv[1];
    const bool external = mode == "--external" || mode == "--duplex" || mode == "--hang" || mode == "--overflow";
    for (int fd = external ? 3 : 4; fd != 128; ++fd) if (fcntl(fd, F_GETFD) >= 0 || errno != EBADF) return 20;
    for (int i = 0; i < argc; ++i) if (std::string(argv[i]).find("private-capsule-test-token") != std::string::npos) return 21;
    for (char **entry = environ; entry && *entry; ++entry)
        if (std::string(*entry).find("private-capsule-test-token") != std::string::npos) return 22;
    if (!external) {
        struct stat info;
        if (fstat(3, &info) || !S_ISREG(info.st_mode) || info.st_nlink != 0 || info.st_size != static_cast<off_t>(MaximumRecoveryCapsuleBytes) ||
            (info.st_mode & 077) || (info.st_uid != 0 && info.st_uid != geteuid()) ||
            (fcntl(3, F_GETFL) & O_ACCMODE) != O_RDONLY || (fcntl(3, F_GETFD) & FD_CLOEXEC)) return 23;
        std::string actual(info.st_size, '\0');
        for (std::size_t offset = 0; offset < actual.size();) {
            const auto count = pread(3, &actual[offset], actual.size() - offset, offset);
            if (count > 0) offset += count;
            else if (count < 0 && errno == EINTR) continue;
            else return 24;
        }
        if (actual != Payload() || write(3, "x", 1) != -1 || errno != EBADF) return 25;
        if (mode == "--mutate-capsule" && fchmod(3, 0600)) return 26;
        close(3);
    }
    if (mode == "--hang") { for (;;) pause(); }
    if (mode == "--duplex" && !WriteAll(1, std::string(128 * 1024, 'r'))) return 28;
    std::size_t count = 0;
    for (;;) {
        char input[4096]; const auto readCount = read(0, input, sizeof(input));
        if (readCount > 0) count += readCount;
        else if (!readCount) break;
        else if (errno != EINTR) return 29;
    }
    // Consume the query before exiting: closing an AF_UNIX socket with unread
    // input can reset the peer on Linux before it observes the queued output.
    if (mode == "--overflow") return WriteAll(1, std::string(128 * 1024, 'x')) ? 0 : 27;
    if (mode == "--duplex" && count != 128 * 1024) return 30;
    return WriteAll(1, external ? "external-ok" : "capsule-ok") ? 0 : 31;
}
struct Fixture {
    std::string directory, executable = Executable(), payload = Payload();
    std::shared_ptr<const RecoveryLaunchCapsule> capsule;
    Fixture() {
        char pattern[] = "/tmp/cydia-provider-launch-XXXXXX";
        const auto made = mkdtemp(pattern); Require(made, "create fixture directory"); directory = made;
        std::string error; capsule = RecoveryLaunchCapsule::Create(payload, directory, &error);
        Require(capsule && capsule->unchanged(), error.c_str());
        Require(std::filesystem::is_empty(directory), "capsule pathname survived creation");
    }
    ~Fixture() { capsule.reset(); std::filesystem::remove_all(directory); }
    Launch::ProbeRunResult Run(const std::string &mode, std::string *output, bool recovery = true,
            unsigned timeout = 3000, const std::function<bool()> &cancelled = {}, std::size_t outputLimit = 256 * 1024,
            const std::string &input = "query") {
        return Launch::RunProbe(executable, {mode}, recovery ? capsule : nullptr, input, output, outputLimit, timeout, cancelled);
    }
};
void DescriptorAndDataIsolation() {
    Fixture f; std::string output;
    const int ordinary = open("/dev/null", O_RDONLY);
    Require(ordinary >= 0, "open unrelated descriptor");
    const int leaked = fcntl(ordinary, F_DUPFD, 100); Require(leaked >= 100, "create non-CLOEXEC descriptor");
    for (const char *mode : {"--cydia-provider-info", "--cydia-provider-session"}) {
        const auto run = f.Run(mode, &output);
        Require(run.kind == Launch::ProbeExit::Exited && run.code == 0 && output == "capsule-ok", "recovery child descriptor contract failed");
        Require(f.capsule->unchanged() && std::filesystem::is_empty(f.directory), "child changed or named capsule");
    }
    const auto external = f.Run("--external", &output, false);
    Require(external.kind == Launch::ProbeExit::Exited && external.code == 0 && output == "external-ok", "external child inherited a private fd");
    Require(fcntl(leaked, F_GETFD) >= 0, "launcher closed a caller-owned descriptor");
    close(leaked); close(ordinary);
    const auto duplex = f.Run("--duplex", &output, false, 3000, {}, 256 * 1024, std::string(128 * 1024, 'q'));
    Require(duplex.kind == Launch::ProbeExit::Exited && duplex.code == 0 && output == std::string(128 * 1024, 'r') + "external-ok",
        "bounded probe deadlocked writing while the child produced output");
}
void ClosedStdioCollisions() {
    Fixture f;
    const pid_t child = fork(); Require(child >= 0, "fork isolated collision fixture");
    if (!child) {
        close(0); close(1); close(2); close(3);
        std::string output;
        const auto run = f.Run("--cydia-provider-session", &output);
        if (run.kind != Launch::ProbeExit::Exited || run.code || output != "capsule-ok") _exit(1);
        const auto external = f.Run("--external", &output, false);
        _exit(external.kind == Launch::ProbeExit::Exited && !external.code && output == "external-ok" ? 0 : 2);
    }
    int status; Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status), "stdio/fd3 collision corrupted launch");
}
void BoundsCancellationAndCleanup() {
    Fixture f; std::string output, error;
    Require(!RecoveryLaunchCapsule::Create("", f.directory, &error) && error == "provider_capsule_invalid", "empty capsule accepted");
    Require(!RecoveryLaunchCapsule::Create(std::string(MaximumRecoveryCapsuleBytes + 1, 'x'), f.directory, &error), "oversized capsule accepted");
    unsigned checks = 0;
    Require(!RecoveryLaunchCapsule::Create(f.payload, f.directory, &error, [&] { return ++checks > 2; }) &&
        error == "provider_cancelled" && std::filesystem::is_empty(f.directory), "cancelled capsule left named data");
    Require(chmod(f.directory.c_str(), 0777) == 0, "change fixture permissions");
    Require(!RecoveryLaunchCapsule::Create(f.payload, f.directory, &error) && error == "provider_capsule_directory_unsafe", "unsafe directory accepted");
    Require(chmod(f.directory.c_str(), 0700) == 0, "restore fixture permissions");
    Require(symlink(f.directory.c_str(), (f.directory + "-link").c_str()) == 0, "create directory alias");
    Require(!RecoveryLaunchCapsule::Create(f.payload, f.directory + "-link", &error), "directory alias accepted");
    unlink((f.directory + "-link").c_str());
    const auto started = std::chrono::steady_clock::now();
    Require(f.Run("--hang", &output, false, 50).kind == Launch::ProbeExit::TimedOut, "probe timeout not reported");
    Require(std::chrono::steady_clock::now() - started < std::chrono::seconds(2), "probe timeout exceeded termination bound");
    const auto cancelAt = std::chrono::steady_clock::now() + std::chrono::milliseconds(20);
    Require(f.Run("--hang", &output, false, 3000, [&] { return std::chrono::steady_clock::now() >= cancelAt; }).kind == Launch::ProbeExit::Cancelled,
        "probe cancellation not reported");
    Require(f.Run("--overflow", &output, false, 3000, {}, 1024).kind == Launch::ProbeExit::OutputLimit && output.empty(), "probe output limit failed");
    Require(f.Run("--cydia-provider-info", &output, true, 12000).kind == Launch::ProbeExit::Exited && output == "capsule-ok",
        "recovery startup bound was shortened before launch");
    const auto oversizedTimeout(f.Run("--hang", &output, true, MaximumRecoveryStartupMilliseconds + 1));
    Require(oversizedTimeout.kind == Launch::ProbeExit::LaunchFailed && oversizedTimeout.error == EINVAL && output.empty(),
        "unbounded recovery startup timeout accepted");
    Launch::Child bad;
    Require(!Launch::Start("/not-present/cydia-provider", {}, f.capsule, &bad, &error) && bad.pid == -1 && bad.channel == -1,
        "failed spawn transferred invalid child ownership");
    Require(std::filesystem::is_empty(f.directory), "failed launches recreated capsule names");
}
void ChangedCapsuleCannotBeReused() {
    Fixture f; std::string output;
    const auto changed = f.Run("--mutate-capsule", &output);
    Require(changed.kind == Launch::ProbeExit::Exited && changed.code == 0 && !f.capsule->unchanged(), "changed capsule went undetected");
    Launch::Child child; std::string error;
    Require(!Launch::Start(f.executable, {"--cydia-provider-session"}, f.capsule, &child, &error) &&
        error == "provider_capsule_changed" && child.pid == -1 && child.channel == -1, "changed capsule was relaunched");
}
}
int main(int argc, char **argv) {
    if (argc > 1) return Child(argc, argv);
    DescriptorAndDataIsolation(); ClosedStdioCollisions(); BoundsCancellationAndCleanup(); ChangedCapsuleCannotBeReused();
    std::cout << "[provider-launch] readonly capsule/descriptor/deadline fixtures passed\n";
}
