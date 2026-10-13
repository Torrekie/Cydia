/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PrivilegedClient.h"
#include "Cydia/DpkgConffile.hpp"
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/AptProviderTransactionRequest.hpp"
#include <apt-pkg/fileutl.h>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <poll.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <thread>

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
int ScopedChildren(CydiaAPT::Provider::TransactionChannel::Channel &channel,
    const CydiaAPT::Provider::TransactionChannel::Frame &request, const std::string &mode,
    const CydiaAPT::Provider::TransactionBeginRequest &begin, std::uint64_t *ordinal) {
    namespace P = CydiaAPT::Provider; namespace TC = P::TransactionChannel;
    P::ParentExecutionRequest execution;
    if (!P::Decode(request.payload, &execution)) return 80;
    bool anyStarted = false;
    for (unsigned index = 0; index != (request.conffilePolicy ? 1u : 2u); ++index) {
        TC::ChildDescriptor purpose;
        if (!index) { purpose.primaryBatch = execution.batch; purpose.primaryAction = static_cast<unsigned>(execution.action); purpose.primaryActions = execution.actions; }
        else {
            purpose.purpose = TC::ChildPurpose::TriggerDrain; purpose.envelopeIdentity = begin.reviewedEffects->identity;
            purpose.checkpointIdentity.assign(64, 'c'); purpose.pass = 1; purpose.primaryCheckpoint = 1;
            purpose.targets.push_back({"cache", "1", "amd64"});
        }
        TC::Frame event = request; event.payload.clear(); event.event = TC::Event::ChildNeeded; event.childOrdinal = ++*ordinal;
        if (!TC::EncodeChildDescriptor(purpose, &event.childDescriptor)) return 81;
        if (mode == "scoped-wrong-ordinal") ++event.childOrdinal;
        if (!channel.Send(event)) return 82;
        TC::Frame answer; std::vector<int> descriptors;
        if (!channel.Receive(&answer, &descriptors)) return 0;
        if (answer.event == TC::Event::ChildDenied) {
            event = request; event.payload.clear(); event.event = TC::Event::Settled;
            event.errorCode = "provider_cancelled"; event.mutationStarted = anyStarted;
            return channel.Send(event) ? 0 : 83;
        }
        if (answer.event != TC::Event::ChildChannels || descriptors.size() != 2 || answer.childOrdinal != event.childOrdinal ||
            answer.childDescriptor != event.childDescriptor || answer.sequence != request.sequence || answer.nonce != request.nonce) return 84;
        if (mode == "scoped-no-spawn") {
            for (int fd : descriptors) close(fd);
            descriptors.clear();
            P::ParentExecutionReply denied; denied.launchError = EACCES;
            event.event = TC::Event::ChildSettled; event.success = true;
            if (!P::Encode(denied, &event.payload) || !channel.Send(event) || !channel.Receive(&answer, &descriptors) ||
                !descriptors.empty() || answer.event != TC::Event::ChildReleased || answer.mutationStarted) return 93;
            event = request; event.payload.clear(); event.event = TC::Event::Settled; event.errorCode = "provider_execution_denied";
            return channel.Send(event) ? 0 : 94;
        }
        if (request.conffilePolicy) {
            P::ConffilePolicyDecision policy;
            policy.match = P::NativeEffectPolicy::Status::Matched;
            policy.input = mode == "policy-refusal" ? CydiaRuntime::Dpkg::ConffileInputPolicy::Interactive : CydiaRuntime::Dpkg::ConffileInputPolicy::Automatic;
            policy.inputIdentity.assign(64, 'a'); policy.recordIdentity.assign(64, 'b'); policy.launchIdentity.assign(64, 'c');
            if (mode == "policy-missing" || mode == "policy-unknown-default") {
                policy.match = P::NativeEffectPolicy::Status::Unsupported; policy.recordIdentity.clear();
                policy.input = CydiaRuntime::Dpkg::ConffileInputPolicy::Unverified;
            }
            event.event = TC::Event::ChildPolicy; event.success = true;
            if (!TC::EncodeConffilePolicy(policy, &event.payload)) return 95;
            if (mode == "policy-wrong-ordinal") ++event.childOrdinal;
            if (!channel.Send(event)) return 96;
            std::vector<int> extra;
            if (!channel.Receive(&answer, &extra)) { for (int fd : descriptors) close(fd); return 0; }
            if (!extra.empty() || answer.event != TC::Event::ChildPolicyAccepted || answer.payload != event.payload ||
                answer.childDescriptor != event.childDescriptor || answer.childOrdinal != event.childOrdinal ||
                answer.sequence != event.sequence || answer.nonce != event.nonce || !answer.conffilePolicy) return 97;
            if (mode == "policy-replayed") {
                if (!channel.Send(event)) return 0;
                const bool accepted = channel.Receive(&answer, &extra, 1000);
                for (int fd : descriptors) close(fd);
                return accepted ? 98 : 0;
            }
            event.payload.clear();
        }
        const pid_t child = fork(); if (child < 0) return 85;
        if (!child) {
            channel.Close();
            if (!WriteAll(descriptors[1], "status: /etc/with spaces.conf : conffile-prompt : '/etc/with spaces.conf' '/etc/with spaces.conf.dpkg-new' 1 1 \n")) _exit(86);
            char answer[2];
            if (request.conffilePolicy && mode != "policy-refusal") {
                pollfd input = {descriptors[0], POLLIN, 0};
                const int ready = poll(&input, 1, 250);
                if (mode == "policy-missing" || mode == "policy-unknown-default")
                    _exit(ready == 1 && read(descriptors[0], answer, 2) == 0 ? 0 : 99);
                _exit(ready == 0 ? 0 : 100);
            }
            if (read(descriptors[0], answer, 2) != 2 || std::string(answer, 2) != "N\n") _exit(87);
            if (mode == "scoped-loss") std::this_thread::sleep_for(std::chrono::milliseconds(180));
            _exit(0);
        }
        for (int fd : descriptors) close(fd);
        descriptors.clear();
        anyStarted = true; event.event = TC::Event::ChildStarted; event.success = event.mutationStarted = true;
        const bool sent = channel.Send(event);
        if (mode == "scoped-loss") channel.Close();
        int state; while (waitpid(child, &state, 0) < 0 && errno == EINTR) {}
        if (!sent || mode == "scoped-loss") return 0;
        P::ParentExecutionReply result; result.started = true;
        result.exitCode = WIFEXITED(state) ? WEXITSTATUS(state) : -1; result.signal = WIFSIGNALED(state) ? WTERMSIG(state) : 0;
        event.event = TC::Event::ChildSettled;
        if (!P::Encode(result, &event.payload) || !channel.Send(event) || !channel.Receive(&answer, &descriptors)) return 88;
        if (!descriptors.empty() || answer.childOrdinal != event.childOrdinal || answer.childDescriptor != event.childDescriptor ||
            answer.sequence != request.sequence || answer.nonce != request.nonce || answer.mutationStarted != event.mutationStarted) return 89;
        if (answer.event == TC::Event::ChildCancelled) {
            event = request; event.payload.clear(); event.event = TC::Event::Settled;
            event.errorCode = "provider_cancelled"; event.mutationStarted = true;
            return channel.Send(event) ? 0 : 90;
        }
        if (answer.event != TC::Event::ChildReleased) return 91;
        // A second child is requested only after the first UI scope released.
    }
    TC::Frame settled = request; settled.event = TC::Event::Settled; settled.success = settled.mutationStarted = true;
    settled.payload = "scoped-settled"; return channel.Send(settled) ? 0 : 92;
}
int TransactionHelper(int socket) {
    namespace TC = CydiaAPT::Provider::TransactionChannel;
    TC::Channel channel(socket); TC::Frame request; std::vector<int> descriptors;
    if (fcntl(200, F_GETFD) >= 0 || !channel.Receive(&request, &descriptors) || request.operation != TC::Operation::Begin) return 60;
    CydiaRuntime::Privileged::Request begin; CydiaRuntime::Privileged::Error ignored;
    if (!CydiaRuntime::Privileged::ParseRequest(request.payload, &begin, &ignored)) return 61;
    std::string mode = begin.payload; CydiaAPT::Provider::TransactionBeginRequest approved;
    if (request.scopedChildren) {
        std::vector<std::string> fields;
        if (!CydiaAPT::Provider::Decode(begin.payload, &fields) || fields.size() != 3 ||
            !CydiaAPT::Provider::DecodeTransactionBegin(fields[2], &approved) || (!request.conffilePolicy && !approved.reviewedEffects)) return 75;
        mode = approved.extendedState;
    }
    if (mode == "begin-timeout") { std::this_thread::sleep_for(std::chrono::milliseconds(200)); return 0; }
    TC::Frame reply = request; reply.event = TC::Event::Settled; reply.success = true;
    reply.payload.clear(); reply.nonce = "fake-helper-generated-nonce";
    if (mode == "wrong-digest") reply.reviewDigest = "SHA256:wrong";
    if (!channel.Send(reply)) return 62;
    std::uint64_t sequence = 0, childOrdinal = 0;
    for (;;) {
        descriptors.clear();
        if (!channel.Receive(&request, &descriptors, 4000)) return 0;
        if (request.sequence != ++sequence || request.nonce != reply.nonce || request.reviewDigest != reply.reviewDigest) return 63;
        reply = request; reply.event = TC::Event::Settled; reply.success = true; reply.payload.clear();
        if (request.operation == TC::Operation::Close) return channel.Send(reply) ? 0 : 64;
        if (request.operation == TC::Operation::Capture) {
            if (mode == "capture-timeout") { std::this_thread::sleep_for(std::chrono::milliseconds(200)); return 0; }
            if (mode == "wrong-sequence") ++reply.sequence;
            reply.payload = "captured-state";
            if (!channel.Send(reply)) return 65;
            continue;
        }
        if (request.operation == TC::Operation::Commit) {
            reply.event = TC::Event::Started; reply.mutationStarted = true;
            if (!channel.Send(reply)) return 66;
            reply.event = TC::Event::Settled; reply.payload = "committed";
            if (!channel.Send(reply)) return 67;
            continue;
        }
        if (request.operation == TC::Operation::Execute && request.scopedChildren) {
            if (!descriptors.empty()) return 76;
            const int result = ScopedChildren(channel, request, mode, approved, &childOrdinal);
            if (result || (mode != "scoped-normal" && mode.compare(0, 7, "policy-") != 0)) return result;
            continue;
        }
        if (request.operation != TC::Operation::Execute || descriptors.size() != 2) return 68;
        if (mode == "lost-before-start" || mode == "success-without-start") {
            for (const int fd : descriptors) close(fd);
            if (mode == "success-without-start" && !channel.Send(reply)) return 74;
            return 0;
        }
        const pid_t child = fork(); if (child < 0) return 69;
        if (!child) {
            channel.Close();
            if (mode == "lost-after-start") { std::this_thread::sleep_for(std::chrono::milliseconds(180)); _exit(0); }
            if (!WriteAll(descriptors[1],
                "status: /etc/with spaces.conf : conffile-prompt : '/etc/with spaces.conf' '/etc/with spaces.conf.dpkg-new' 1 1 \n")) _exit(70);
            char answer[2];
            _exit(read(descriptors[0], answer, sizeof(answer)) == 2 && answer[0] == (request.payload == "new" ? 'Y' : 'N') && answer[1] == '\n' ? 0 : 71);
        }
        for (const int fd : descriptors) close(fd);
        reply.event = TC::Event::Started; reply.mutationStarted = true;
        if (!channel.Send(reply)) { int status; waitpid(child, &status, 0); return 72; }
        if (mode == "lost-after-start") channel.Close();
        int status = 0; while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        if (mode == "lost-after-start") return 0;
        reply.event = TC::Event::Settled; reply.success = WIFEXITED(status) && WEXITSTATUS(status) == 0;
        if (!reply.success) reply.errorCode = "provider_child_failed";
        reply.payload = "settled";
        if (!channel.Send(reply)) return 73;
    }
}
int Helper(int argc, char **argv) {
    if (argc > 1 && std::strncmp(argv[argc - 1], "--cydia-deadline-ms=", 20) == 0) --argc;
    const std::string command(argv[1]);
    if (command == "--cydia-provider-transaction" && argc == 3) return TransactionHelper(std::atoi(argv[2]));
    if (command == "--cydia-provider-direct" && argc == 3) {
        CydiaRuntime::Privileged::Request request; CydiaRuntime::Privileged::Error error;
        const int channel = std::atoi(argv[2]);
        if (!CydiaRuntime::Privileged::ReadRequest(channel, &request, &error)) return 31;
        if (request.payload == "started") return WriteAll(channel, "S") ? 0 : 32;
        if (request.payload == "denied") return WriteAll(channel, "N") ? 7 : 33;
        if (request.payload == "lost") return 0;
        if (request.payload == "input") {
            char input[4];
            return read(STDIN_FILENO, input, sizeof(input)) == 4 && std::string(input, 4) == "hold" &&
                WriteAll(channel, "S") ? 0 : 34;
        }
        if (request.payload.compare(0, 9, "conffile:") == 0) {
            const auto separator = request.payload.find(':', 9);
            if (separator == std::string::npos) return 37;
            const int status = std::atoi(request.payload.substr(9, separator - 9).c_str());
            const auto mode = request.payload.substr(separator + 1);
            if (!WriteAll(channel, "S") || !WriteAll(status,
                "status: /etc/with spaces.conf : conffile-prompt : '/etc/with spaces.conf' '/etc/with spaces.conf.dpkg-new' 1 1 \n")) return 38;
            pollfd input{STDIN_FILENO, POLLIN, 0};
            const int ready = poll(&input, 1, mode == "automatic" ? 200 : 4000);
            if (mode == "automatic") return ready == 0 ? 0 : 39;
            char answer[2];
            if (ready != 1 || read(STDIN_FILENO, answer, sizeof(answer)) != 2 ||
                answer[0] != (mode == "new" ? 'Y' : 'N') || answer[1] != '\n') return 40;
            return WriteAll(status, "status: sample: installed\n") ? 0 : 41;
        }
        return 35;
    }
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
    if (command == "--cydia-provider-snapshot")
        return WriteAll(STDOUT_FILENO, CydiaRuntime::Privileged::SerializeFields(
            {"CYDIA-PROVIDER-SNAPSHOT-1", "provider_registration_missing", "localized diagnostic", ""})) ? 0 : 36;
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
    namespace Provider = CydiaAPT::Provider;
    Provider::RegisteredProviderSnapshot snapshot;
    Expect(!PrivilegedClient::ReadProviderSnapshot(executable, "/missing", nullptr, &snapshot, &error) &&
        error.code == "provider_registration_missing", "read exact provider error code without matching diagnostics");
    request = Privileged::Request(); request.payload = "started";
    auto execution = PrivilegedClient::RunProviderDpkg(executable, "--cydia-provider-direct", request, -1);
    Expect(execution.result.succeeded() && execution.started && !execution.indeterminate,
        "separate request channel reports started child");
    request.payload = "denied";
    execution = PrivilegedClient::RunProviderDpkg(executable, "--cydia-provider-direct", request, -1);
    Expect(!execution.result.succeeded() && !execution.started && !execution.indeterminate,
        "typed pre-launch denial cannot be mistaken for a mutation");
    request.payload = "lost";
    execution = PrivilegedClient::RunProviderDpkg(executable, "--cydia-provider-direct", request, -1);
    Expect(!execution.result.succeeded() && execution.indeterminate,
        "lost launch status forbids a safe retry even if helper exits zero");
    request.payload = "input"; const std::string input = "hold";
    execution = PrivilegedClient::RunProviderDpkg(executable, "--cydia-provider-direct", request, -1, &input);
    Expect(execution.result.succeeded() && execution.started && !execution.indeterminate,
        "protected request does not consume dpkg selection input");
    // Exercise the actual helper spawn seam: private status + stdin, inherited
    // request channel, old question rejection and known automatic policy.
    int statusPipe[2]; Expect(pipe(statusPipe) == 0, "fixture status pipe");
    Expect(fcntl(statusPipe[0], F_SETFL, O_NONBLOCK) == 0, "nonblocking fixture status");
    Dpkg::ConffilePrompt previous;
    unsigned questionCount = 0;
    bool keepOld = true;
    Dpkg::ConffileCallbacks conffiles;
    conffiles.question = [&](const Dpkg::ConffilePrompt &question) {
        if (previous.question)
            Expect(!Dpkg::AnswerConffilePrompt(previous.execution, previous.question, true), "prior child answer must be stale");
        Expect(question.oldPath == "/etc/with spaces.conf", "helper prompt preserves filename spaces");
        Expect(Dpkg::AnswerConffilePrompt(question.execution, question.question, keepOld), "reply through isolated helper stdin");
        previous = question; ++questionCount;
    };
    Dpkg::SetConffileCallbacks(conffiles);
    request.payload = "conffile:" + std::to_string(statusPipe[1]) + ":old";
    execution = PrivilegedClient::RunProviderDpkg(executable, "--cydia-provider-direct", request, statusPipe[1]);
    Expect(execution.result.succeeded() && questionCount == 1 && execution.started, "interactive keep-old helper");
    keepOld = false;
    request.payload = "conffile:" + std::to_string(statusPipe[1]) + ":new";
    execution = PrivilegedClient::RunProviderDpkg(executable, "--cydia-provider-direct", request, statusPipe[1]);
    Expect(execution.result.succeeded() && questionCount == 2, "interactive accept-new helper");
    request.payload = "conffile:" + std::to_string(statusPipe[1]) + ":automatic";
    execution = PrivilegedClient::RunProviderDpkg(executable, "--cydia-provider-direct", request, statusPipe[1], nullptr,
        {"--force-confdef", "--force-confold"});
    Expect(execution.result.succeeded() && questionCount == 2, "known automatic policy receives no UI answer");
    Expect(!Dpkg::AnswerConffilePrompt(previous.execution, previous.question, true), "settled helper question cannot queue input");
    char unused;
    Expect(read(statusPipe[0], &unused, 1) < 0 && errno == EAGAIN, "private status never enters an untagged global pipe");
    // The persistent authenticated helper receives only fd3; each real child
    // gets a new descriptor pair and its Started/Settled notifications bind to
    // the exact monotonically increasing request.
    namespace TC = Provider::TransactionChannel;
    int sentinel = open("/dev/null", O_RDONLY);
    Expect(sentinel >= 0 && dup2(sentinel, 200) == 200, "unrelated inheritable descriptor fixture"); close(sentinel);
    std::string transactionError; request.payload = "normal";
    auto transaction = PrivilegedClient::ProviderTransaction::Start(executable, request, "SHA256:review", &transactionError);
    Expect(transaction && transaction->valid(), "persistent Begin authenticates its reply binding and closes unrelated descriptors");
    auto response = transaction->Request(TC::Operation::Capture, "");
    Expect(response.transportValid && response.success && response.payload == "captured-state", "persistent capture reply");
    unsigned starts = 0;
    for (const bool old : {true, false}) {
        keepOld = old; bool operationCancelled = false;
        response = transaction->Request(TC::Operation::Execute, old ? "old" : "new", statusPipe[1], {},
            [&] { ++starts; operationCancelled = true; }, 4000, [&] { return operationCancelled; });
        Expect(response.transportValid && response.success && response.started && !response.indeterminate,
            "actual child start and settlement, isolated per-child conffile input");
    }
    Expect(starts == 2 && transaction->mutationStarted() && questionCount == 4, "started callbacks and question generations");
    response = transaction->Request(TC::Operation::Commit, "", -1, {}, [&] { ++starts; });
    Expect(response.success && response.started && response.payload == "committed" && starts == 3,
        "persistent commit reports start and settlement");
    Expect(transaction->Close(&transactionError) && !transaction->valid(), "persistent close handshake");
    for (const std::string mode : {"lost-before-start", "lost-after-start", "success-without-start"}) {
        request.payload = mode;
        transaction = PrivilegedClient::ProviderTransaction::Start(executable, request, "SHA256:review", &transactionError);
        Expect(static_cast<bool>(transaction), "loss fixture begin");
        const auto before = std::chrono::steady_clock::now();
        response = transaction->Request(TC::Operation::Execute, "old", statusPipe[1], {}, {}, 20);
        Expect(!response.transportValid && response.indeterminate && transaction->indeterminate() && !transaction->valid(),
            "lost execution transport is indeterminate even before Started");
        if (mode == "lost-after-start") Expect(response.started && std::chrono::steady_clock::now() - before >= std::chrono::milliseconds(100),
            "started mutation settles without timeout killing the helper/child");
    }
    for (const std::string mode : {"wrong-sequence", "capture-timeout"}) {
        request.payload = mode;
        transaction = PrivilegedClient::ProviderTransaction::Start(executable, request, "SHA256:review", &transactionError);
        Expect(static_cast<bool>(transaction), "nonmutation failure fixture begin");
        const auto before = std::chrono::steady_clock::now();
        response = transaction->Request(TC::Operation::Capture, "", -1, {}, {}, 40);
        Expect(!response.transportValid && !response.indeterminate && !transaction->valid() &&
            std::chrono::steady_clock::now() - before < std::chrono::seconds(1), "mismatched/bounded nonmutating reply fails closed");
    }
    for (const std::string mode : {"wrong-digest", "begin-timeout"}) {
        request.payload = mode;
        transaction = PrivilegedClient::ProviderTransaction::Start(executable, request, "SHA256:review", &transactionError, 40);
        Expect(!transaction && !transactionError.empty(), "Begin cannot publish mismatched or timed-out authority");
    }
    for (const std::string mode : {"policy-cfg-old", "policy-confdef", "policy-refusal", "policy-missing", "policy-unknown-default",
            "policy-wrong-ordinal", "policy-replayed"}) {
        Provider::TransactionBeginRequest approved;
        auto &binding = approved.review.binding;
        binding.providerIdentifier = "fixture"; binding.session.assign(64, 'a'); binding.configurationIdentity = "config";
        binding.policyIdentity = "policy"; binding.packageStateIdentity = "state"; binding.cacheEpoch = binding.selectionRevision = 1; binding.review = "review";
        Provider::ReviewedAction action; action.identifier = 1; action.action = Provider::ExecutionAction::Configure; action.package = {"sample", "1", "all"};
        approved.review.execution.actions.push_back(action); approved.extendedState = mode;
        std::string beginBytes;
        Expect(Provider::EncodeTransactionBegin(approved, &beginBytes) &&
            Provider::Encode(std::vector<std::string>{"CYDIA-BROKER-1", "fixture authority", beginBytes}, &request.payload), "encode v3 ordinary approval");
        transaction = PrivilegedClient::ProviderTransaction::Start(executable, request, "SHA256:review", &transactionError, 4000, {}, false, true);
        Expect(transaction && transaction->valid(), "v3 ordinary child negotiation requires no trigger approval");
        Provider::ParentExecutionRequest child; child.binding = binding; child.batch = 1; child.actions = {1}; child.action = action.action;
        child.arguments = {"--status-fd=99", "--configure", "sample:all"};
        std::string childBytes; Expect(Provider::Encode(child, &childBytes), "encode v3 child");
        keepOld = true; const unsigned beforeQuestions = questionCount;
        response = transaction->Request(TC::Operation::Execute, childBytes, statusPipe[1], {"--force-confold"});
        if (mode == "policy-wrong-ordinal" || mode == "policy-replayed") {
            Expect(!response.transportValid && !response.started && response.indeterminate && !transaction->valid() &&
                questionCount == beforeQuestions, "misbound/replayed policy cannot start a child or publish UI");
        } else {
            Expect(response.transportValid && response.success && response.started && !response.indeterminate &&
                questionCount == beforeQuestions + (mode == "policy-refusal" ? 1u : 0u),
                "authenticated final policy governs actual child-pipe bytes, not argv hints");
            Expect(transaction->Close(), "close v3 transaction after child release");
        }
    }
    for (const std::string mode : {"scoped-normal", "scoped-cancel", "scoped-loss", "scoped-wrong-ordinal", "scoped-no-ui", "scoped-no-spawn"}) {
        Provider::TransactionBeginRequest approved;
        auto &binding = approved.review.binding;
        binding.providerIdentifier = "fixture"; binding.session.assign(64, 'a'); binding.configurationIdentity = "config";
        binding.policyIdentity = "policy"; binding.packageStateIdentity = "state"; binding.cacheEpoch = binding.selectionRevision = 1; binding.review = "review";
        Provider::ReviewedAction action; action.identifier = 1; action.action = Provider::ExecutionAction::Configure; action.package = {"sample", "1", "all"};
        approved.review.execution.actions.push_back(action); approved.extendedState = mode;
        auto effects = std::make_shared<Provider::TriggerEffectEnvelope>(); effects->identity.assign(64, 'a'); effects->initialCheckpoint.assign(64, 'b');
        effects->nativeAuthorityIdentity.assign(64, 'd'); effects->primaryReview = approved.review; effects->recipients["cache:amd64@1"] = {"cache", "1", "amd64"};
        effects->awaiters = effects->recipients; approved.reviewedEffects = effects;
        std::string beginBytes;
        Expect(Provider::EncodeTransactionBegin(approved, &beginBytes) &&
            Provider::Encode(std::vector<std::string>{"CYDIA-BROKER-1", "fixture authority", beginBytes}, &request.payload), "encode scoped fixture approval");
        transaction = PrivilegedClient::ProviderTransaction::Start(executable, request, "SHA256:review", &transactionError, 4000, {}, true);
        Expect(transaction && transaction->valid(), "explicitly negotiate reviewed finite children");
        Provider::ParentExecutionRequest child; child.binding = binding; child.batch = 1; child.actions = {1}; child.action = action.action;
        child.arguments = {"--status-fd=99", "--no-triggers", "--configure", "sample:all"};
        std::string childBytes; Expect(Provider::Encode(child, &childBytes), "encode scoped primary action");
        keepOld = true; bool cancelled = false; unsigned notifications = 0; const unsigned beforeQuestions = questionCount;
        if (mode == "scoped-no-ui") Dpkg::SetConffileCallbacks({});
        const auto before = std::chrono::steady_clock::now();
        response = transaction->Request(TC::Operation::Execute, childBytes, statusPipe[1], {}, [&] {
            ++notifications; if (mode == "scoped-cancel") cancelled = true;
        }, 20, [&] { return cancelled; });
        if (mode == "scoped-no-ui") Dpkg::SetConffileCallbacks(conffiles);
        if (mode == "scoped-normal") {
            const bool complete = response.transportValid && response.success && response.started && !response.indeterminate &&
                notifications == 1 && questionCount == beforeQuestions + 2;
            if (!complete) std::cerr << "[verify-privileged-client][scoped] error=" << response.errorCode
                << " transport=" << response.transportValid << " success=" << response.success << " started=" << response.started
                << " indeterminate=" << response.indeterminate << " notifications=" << notifications
                << " questions=" << questionCount - beforeQuestions << '\n';
            Expect(complete, "primary and trigger children have separate question generations under one Execute");
            Expect(transaction->Close(), "close scoped transaction after both channels released");
        } else if (mode == "scoped-cancel") {
            Expect(response.transportValid && !response.success && response.started && !response.indeterminate &&
                notifications == 1 && questionCount == beforeQuestions + 1, "cancellation waits for first settlement and prevents trigger child");
        } else if (mode == "scoped-no-ui" || mode == "scoped-no-spawn") {
            Expect(response.transportValid && !response.success && !response.started && !response.indeterminate &&
                !notifications && questionCount == beforeQuestions, "denied channels or validated no-spawn settlement cannot report a mutation");
        } else {
            Expect(!response.transportValid && response.indeterminate && !transaction->valid(), "scope mismatch or lost execution channel remains indeterminate");
            if (mode == "scoped-loss") Expect(response.started && questionCount == beforeQuestions + 1 &&
                std::chrono::steady_clock::now() - before >= std::chrono::milliseconds(100), "live scoped child settles beyond timeout without losing its UI input");
            else Expect(!notifications && questionCount == beforeQuestions, "wrong ordinal cannot obtain a channel pair");
        }
        Expect(!Dpkg::AnswerConffilePrompt(previous.execution, previous.question, true), "finished child never leaves an answer for the next scope");
    }
    close(200);
    Dpkg::SetConffileCallbacks({}); close(statusPipe[0]); close(statusPipe[1]);
    std::cout << "[verify-privileged-client][ ok ] bounded duplex I/O, descriptor validation and frontend-owned locks\n";
    return 0;
}
