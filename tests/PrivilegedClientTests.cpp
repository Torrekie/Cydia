/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PrivilegedClient.h"
#include <apt-pkg/fileutl.h>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
LockFileOpener opener = NULL;
void *openerContext = NULL;
std::string executable;
std::string admin;
std::string empty;
std::string root("/");
std::string query("/synthetic/bin/dpkg-query");
std::string deb("/synthetic/bin/dpkg-deb");
std::string sources("/synthetic/etc/apt/sources.list");
std::string parts("/synthetic/etc/apt/sources.list.d");
unsigned environmentReads = 0;
void Expect(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "[verify-privileged-client][FAIL] " << message << '\n';
        std::exit(1);
    }
}
bool WriteAll(int fd, const std::string &bytes) {
    std::size_t offset = 0;
    while (offset != bytes.size()) {
        ssize_t count = write(fd, bytes.data() + offset, bytes.size() - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        offset += static_cast<std::size_t>(count);
    }
    return true;
}
int Helper(int argc, char **argv) {
    if (argc > 1 && std::strncmp(argv[argc - 1], "--cydia-deadline-ms=", 20) == 0) --argc;
    const std::string command(argv[1]);
    if (command == "--cydia-early") return 17;
    if (command == "--cydia-hang" || command == "--cydia-hang-closed") {
        if (command == "--cydia-hang-closed") {
            close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO);
        }
        for (;;) pause();
    }
    if (command == "--cydia-duplex") {
        if (!WriteAll(STDOUT_FILENO, std::string(262144, 'o')) ||
            !WriteAll(STDERR_FILENO, std::string(262144, 'e'))) return 20;
    }
    CydiaRuntime::Privileged::Request request;
    CydiaRuntime::Privileged::Error error;
    if (!CydiaRuntime::Privileged::ReadRequest(STDIN_FILENO, &request, &error)) return 21;
    if (command == "--cydia-duplex")
        return request.payload == std::string(1048576, 'p') ? 0 : 22;
    if (command == "--cydia-signal") { raise(SIGTERM); return 23; }
    if (command == "--cydia-echo")
        return WriteAll(STDOUT_FILENO, request.payload) && WriteAll(STDERR_FILENO, "diagnostic") ? 0 : 24;
    if (command == "--cydia-set-executable") {
        const auto &expected(request.expected);
        if (!expected.aptConfigOverride.empty() || !expected.dpkgRoot.empty() || !expected.dpkgAdmin.empty() ||
            !expected.dpkg.empty() || !expected.dpkgQuery.empty() || !expected.dpkgDeb.empty() ||
            !expected.sourceList.empty() || !expected.sourceParts.empty()) return 28;
        std::vector<std::string> fields;
        return CydiaRuntime::Privileged::ParseFields(request.payload, 2, &fields, &error) &&
            WriteAll(STDOUT_FILENO, request.payload) ? 0 : 29;
    }
    if (command == "--cydia-open-lock" && argc == 3) {
        if (request.expected.sourceList == "hang") for (;;) pause();
        int fd = open(request.expected.dpkgAdmin.c_str(), O_RDWR);
        if (fd < 0) return 25;
        int descriptors[] = {fd, fd};
        char byte = request.expected.sourceList == "bad-byte" ? 'X' : 'L';
        struct iovec data = {&byte, 1};
        union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(descriptors))]; } control;
        std::memset(&control, 0, sizeof(control));
        struct msghdr message;
        std::memset(&message, 0, sizeof(message));
        const std::size_t count = request.expected.sourceParts == "multiple" ? 2 : 1;
        message.msg_iov = &data; message.msg_iovlen = 1;
        message.msg_control = control.bytes; message.msg_controllen = CMSG_SPACE(count * sizeof(int));
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(count * sizeof(int));
        std::memcpy(CMSG_DATA(header), descriptors, count * sizeof(int));
        const bool success = sendmsg(std::atoi(argv[2]), &message, 0) == 1;
        close(fd);
        return success ? 0 : 26;
    }
    return 27;
}
} // namespace

void SetLockFileOpener(LockFileOpener selected, void *context) {
    opener = selected; openerContext = context;
}
namespace CydiaAPT {
const std::string &AptConfigOverride() { return empty; }
const std::string &DpkgRootDirectory() { ++environmentReads; return root; }
const std::string &DpkgAdminDirectory() { return admin; }
const std::string &DpkgExecutablePath() { return executable; }
const std::string &DpkgQueryExecutablePath() { return query; }
const std::string &DpkgDebExecutablePath() { return deb; }
const std::string &SourceListPath() { return sources; }
const std::string &SourcePartsDirectory() { return parts; }
const std::string &PrivilegedHelperPath() { return executable; }
} // namespace CydiaAPT

int main(int argc, char **argv) {
    if (argc > 1 && std::strncmp(argv[1], "--cydia-", 8) == 0) return Helper(argc, argv);
    char *resolved = realpath(argv[0], NULL);
    Expect(resolved != NULL, "discover executable");
    executable = resolved; std::free(resolved);
    const char *temporary = std::getenv("TMPDIR");
    std::string name = std::string(temporary == NULL ? "/tmp" : temporary) + "/cydia-lock-client.XXXXXX";
    std::vector<char> writable(name.begin(), name.end()); writable.push_back('\0');
    int seed = mkstemp(writable.data());
    Expect(seed >= 0, "create lock fixture"); close(seed); admin = writable.data();
    using namespace CydiaRuntime;
    const std::string settingsPayload(Privileged::SerializeFields({"dpkg", ""}));
    Privileged::Request settings = PrivilegedClient::PrivateSettingsRequest(settingsPayload);
    Expect(settings.payload == settingsPayload && settings.expected.dpkg.empty() && environmentReads == 0,
           "private settings request does not resolve selected tools or APT state");
    PrivilegedClient::Result settingsResult = PrivilegedClient::RunPrivateSettingsCommand(
        "--cydia-set-executable", settingsPayload);
    Expect(settingsResult.succeeded() && settingsResult.output == settingsPayload && environmentReads == 0,
           "private executable reset sends only its payload without runtime expectations");
    settingsResult = PrivilegedClient::RunPrivateSettingsCommand("--cydia-recovery-configure", settingsPayload);
    Expect(!settingsResult.succeeded() && settingsResult.launchError == EINVAL && environmentReads == 0,
           "private settings client cannot bypass runtime resolution for package actions");
    Privileged::Request request = PrivilegedClient::RuntimeRequest("hello\nworld");
    Expect(request.expected.dpkgQuery == query && request.expected.dpkgDeb == deb,
           "shared expected descriptor");
    PrivilegedClient::Result result = PrivilegedClient::RunNativeCommand("--cydia-echo", request.payload);
    Expect(result.succeeded() && result.output == request.payload && result.error == "diagnostic",
           "request framing and separate bounded capture");
    request.payload.assign(1048576, 'p');
    result = PrivilegedClient::Run(executable, "--cydia-duplex", request);
    Expect(result.succeeded() && result.output == std::string(262144, 'o') &&
           result.error == std::string(262144, 'e'), "multiplex large input and output without deadlock");
    result = PrivilegedClient::Run(executable, "--cydia-duplex", request, 16384);
    Expect(!result.succeeded() && result.exitCode == 0 && result.outputLimitExceeded &&
           result.output.size() + result.error.size() == 16384, "drain oversized output and fail closed");
    result = PrivilegedClient::Run(executable, "--cydia-early", request);
    Expect(!result.succeeded() && result.exitCode == 17, "early helper exit survives a broken input socket");
    request.payload.clear();
    result = PrivilegedClient::Run(executable, "--cydia-signal", request);
    Expect(!result.succeeded() && result.termSignal == SIGTERM, "signal termination is not success");
    result = PrivilegedClient::Run("/nonexistent-cydia-helper", "--cydia-echo", request);
    Expect(!result.succeeded() && result.launchError == ENOENT, "launch failure");
    for (const char *command : {"--cydia-hang", "--cydia-hang-closed"}) {
        const auto before(std::chrono::steady_clock::now());
        result = PrivilegedClient::Run(executable, command, request, 1024, 100);
        const auto elapsed(std::chrono::steady_clock::now() - before);
        Expect(!result.succeeded() && result.launchError == ETIMEDOUT && result.termSignal == SIGKILL,
            "bounded helper is terminated and reaped even after closing its pipes");
        Expect(elapsed < std::chrono::seconds(2), "bounded helper returns within its deadline tolerance");
    }
    Privileged::Error error;
    int fd = PrivilegedClient::OpenLock(executable, request, "lock-frontend", &error);
    Expect(fd >= 0 && (fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0, "receive close-on-exec lock descriptor");
    struct flock lock;
    std::memset(&lock, 0, sizeof(lock)); lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
    Expect(fcntl(fd, F_GETLK, &lock) == 0 && lock.l_type == F_UNLCK,
           "helper opens without owning the fcntl lock");
    lock.l_type = F_WRLCK;
    Expect(fcntl(fd, F_SETLK, &lock) == 0, "frontend acquires lock");
    pid_t child = fork();
    Expect(child >= 0, "start lock observer");
    if (child == 0) {
        lock.l_type = F_WRLCK;
        _exit(fcntl(fd, F_GETLK, &lock) == 0 && lock.l_type == F_WRLCK && lock.l_pid == getppid() ? 0 : 1);
    }
    int status = 0;
    Expect(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
           "lock belongs to the frontend process");
    close(fd);
    int ready[2], release[2];
    Expect(pipe(ready) == 0 && pipe(release) == 0, "create contention synchronization");
    child = fork();
    Expect(child >= 0, "start foreign frontend");
    if (child == 0) {
        close(ready[0]); close(release[1]);
        int foreign = open(admin.c_str(), O_RDWR);
        struct flock held = {};
        held.l_type = F_WRLCK; held.l_whence = SEEK_SET;
        if (foreign < 0 || fcntl(foreign, F_SETLK, &held) != 0 || !WriteAll(ready[1], "R")) _exit(2);
        char done;
        if (read(release[0], &done, 1) != 1) _exit(3);
        close(foreign); _exit(0);
    }
    close(ready[1]); close(release[0]);
    char synchronized = 0;
    Expect(read(ready[0], &synchronized, 1) == 1 && synchronized == 'R', "foreign frontend holds lock");
    fd = PrivilegedClient::OpenLock(executable, request, "lock-frontend", &error);
    Expect(fd >= 0, "helper may open a contended lock without taking ownership");
    lock.l_type = F_WRLCK;
    Expect(fcntl(fd, F_SETLK, &lock) < 0 && (errno == EACCES || errno == EAGAIN),
           "frontend cannot bypass a foreign process lock");
    close(fd);
    Expect(WriteAll(release[1], "D"), "release foreign frontend");
    close(ready[0]); close(release[1]);
    Expect(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
           "foreign frontend exits normally");
    request.expected.sourceList = "bad-byte";
    Expect(PrivilegedClient::OpenLock(executable, request, "lock", &error) < 0,
           "reject unexpected descriptor message");
    request.expected.sourceList = sources; request.expected.sourceParts = "multiple";
    Expect(PrivilegedClient::OpenLock(executable, request, "lock", &error) < 0,
           "reject multiple transferred descriptors");
    request.expected.sourceParts = parts; request.expected.sourceList = "hang";
    Expect(PrivilegedClient::OpenLock(executable, request, "lock", &error, 100) < 0 && errno == ETIMEDOUT,
        "bounded descriptor handoff terminates and reaps a stalled helper");
    PrivilegedClient::ConfigureLockBridge(executable, PrivilegedClient::CurrentExpectedEnvironment());
    Expect(opener != NULL, "register opener");
    Expect(PrivilegedClient::SetLockBridgeTimeoutMilliseconds(4000) == 0 &&
        PrivilegedClient::SetLockBridgeTimeoutMilliseconds(0) == 4000,
        "scoped diagnostic timeout preserves the registered bridge");
    fd = -1;
    Expect(!opener("/synthetic/lists/lock", &fd, openerContext) && fd < 0,
           "leave unrelated acquisition locks unchanged");
    Expect(opener(admin + "/lock-frontend", &fd, openerContext) && fd >= 0,
           "route only the expected dpkg lock through the helper");
    close(fd); PrivilegedClient::ClearLockBridge();
    Expect(opener == NULL, "clear opener"); unlink(admin.c_str());
    std::cout << "[verify-privileged-client][ ok ] bounded duplex I/O, descriptor validation and frontend-owned locks\n";
    return 0;
}
