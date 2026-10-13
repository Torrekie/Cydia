/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/DpkgConffile.hpp"
#include "Cydia/AptProviderConffilePolicy.hpp"
#include <cerrno>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdlib>
#include <fcntl.h>
#include <iostream>
#include <mutex>
#include <poll.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
extern char **environ;
namespace D = CydiaRuntime::Dpkg;
namespace {
void Check(bool okay, const char *what) {
    if (!okay) { std::cerr << "[dpkg-conffile] " << what << '\n'; std::exit(1); }
}
const std::string payload("'/etc/a file.conf' '/etc/a file.conf.dpkg-new' 1 1 ");
const std::string notification("status: /etc/a file.conf : conffile-prompt : " + payload + "\n");
bool Write(int fd, const std::string &bytes) {
    std::size_t done = 0;
    while (done < bytes.size()) {
        const auto n = write(fd, bytes.data() + done, bytes.size() - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        done += static_cast<std::size_t>(n);
    }
    return true;
}
int Child(int fd, const std::string &mode) {
    if (mode == "oversized" && !Write(fd, std::string(65537, 'x') + "\n")) return 2;
    if (!Write(fd, mode == "malformed" ? "status: /etc/file : conffile-prompt : malformed\n" : notification)) return 3;
    if (mode == "expired") return 0;
    pollfd item{STDIN_FILENO, POLLIN, 0};
    const int ready = poll(&item, 1, mode == "automatic" ? 200 : 4000);
    if (mode == "automatic") return ready == 0 ? 0 : 4;
    if (ready != 1) return 5;
    char answer[2]; const ssize_t n = read(STDIN_FILENO, answer, sizeof(answer));
    if (mode == "oversized" || mode == "malformed" || mode == "suppressed") return n == 0 ? 0 : 8;
    if (n != 2 || answer[0] != (mode == "new" ? 'Y' : 'N') || answer[1] != '\n') return 6;
    return Write(fd, "status: sample: installed\n") ? 0 : 7;
}
struct Events {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<D::ConffilePrompt> questions;
    std::vector<std::string> statuses;
    unsigned invalidated = 0;
    unsigned unavailable = 0;
    D::ConffileCallbacks Callbacks() {
        D::ConffileCallbacks value;
        value.question = [this](const D::ConffilePrompt &question) {
            std::lock_guard<std::mutex> lock(mutex); questions.push_back(question); changed.notify_all();
        };
        value.invalidated = [this](std::uint64_t, std::uint64_t) {
            std::lock_guard<std::mutex> lock(mutex); ++invalidated; changed.notify_all();
        };
        value.status = [this](const std::string &line) {
            std::lock_guard<std::mutex> lock(mutex); statuses.push_back(line); changed.notify_all();
        };
        value.unavailable = [this]() {
            std::lock_guard<std::mutex> lock(mutex); ++unavailable; changed.notify_all();
        };
        return value;
    }
    D::ConffilePrompt Wait(std::size_t count) {
        std::unique_lock<std::mutex> lock(mutex);
        Check(changed.wait_for(lock, std::chrono::seconds(3), [&] { return questions.size() >= count; }), "question timeout");
        return questions[count - 1];
    }
    std::size_t Count() { std::lock_guard<std::mutex> lock(mutex); return questions.size(); }
};
pid_t Spawn(const char *executable, D::ConffileExecution &io, const char *mode) {
    Check(io.enabled() && io.valid(), "execution channel unavailable");
    posix_spawn_file_actions_t actions;
    Check(posix_spawn_file_actions_init(&actions) == 0, "spawn actions");
    Check(posix_spawn_file_actions_adddup2(&actions, io.inputDescriptor(), STDIN_FILENO) == 0, "stdin action");
    Check(posix_spawn_file_actions_addclose(&actions, io.inputDescriptor()) == 0, "stdin close action");
    const int copied = fcntl(io.statusDescriptor(), F_DUPFD, 3);
    Check(copied >= 0, "status duplicate");
    Check(posix_spawn_file_actions_adddup2(&actions, copied, io.statusDescriptor()) == 0, "status action");
    Check(posix_spawn_file_actions_addclose(&actions, copied) == 0, "status close action");
    std::vector<std::string> words{executable, "--child", std::to_string(io.statusDescriptor()), mode};
    std::vector<char *> argv; for (auto &word : words) argv.push_back(&word[0]); argv.push_back(nullptr);
    pid_t child = -1;
    const int result = posix_spawn(&child, executable, &actions, nullptr, argv.data(), environ);
    close(copied); posix_spawn_file_actions_destroy(&actions);
    Check(result == 0, "spawn fake dpkg"); io.ChildStarted(); return child;
}
void Reap(pid_t child, D::ConffileExecution &io) {
    int result = 0; pid_t waited;
    do { waited = waitpid(child, &result, 0); } while (waited < 0 && errno == EINTR);
    io.Finish();
    Check(waited == child && WIFEXITED(result) && WEXITSTATUS(result) == 0, "fake dpkg failed");
}
}
int main(int argc, char **argv) {
    if (argc == 4 && std::string(argv[1]) == "--child") return Child(std::atoi(argv[2]), argv[3]);
    D::ConffilePrompt parsed;
    Check(D::ParseConffilePrompt(payload, &parsed) && parsed.oldPath == "/etc/a file.conf" &&
        parsed.newPath == "/etc/a file.conf.dpkg-new" && parsed.userEdited && parsed.distributionEdited, "space path parsing");
    Check(D::ParseConffileStatus(notification.substr(0, notification.size()-1), &parsed), "raw status parsing");
    Check(D::ParseConffileStatus("pmconffile:sample:arm64:100:" + payload, &parsed), "APT status parsing");
    for (const auto &bad : std::vector<std::string>{"", "'relative' '/new' 1 1", "'/old' '/new' 2 1", "'/old' '/new' 1 1 junk",
        "'/old' '/ambiguous' '/new' 1 1", std::string(65537, 'x'), "'/old\nfile' '/new' 1 1"})
        Check(!D::ParseConffilePrompt(bad, &parsed), "malformed prompt accepted");
    Check(!D::ConffileChoiceIsAutomatic({}) && !D::ConffileChoiceIsAutomatic({"--force-confdef"}) &&
        !D::ConffileChoiceIsAutomatic({"--force-confask"}), "unknown policy became automatic");
    Check(D::ConffileChoiceIsAutomatic({"--force-confdef", "--force-confold"}) &&
        D::ConffileChoiceIsAutomatic({"--force-confnew"}), "explicit automatic choice lost");
    Check(!D::ConffileChoiceIsAutomatic({"--", "--force-confold"}) &&
        !D::ConffileChoiceIsAutomatic({"--force-confold", "--no-force-confold"}), "unmodeled argv policy accepted");
    Events events; D::SetConffileCallbacks(events.Callbacks());
    D::ConffilePrompt old;
    {
        D::ConffileExecution io({}); const auto child = Spawn(argv[0], io, "old");
        old = events.Wait(1);
        Check(D::IsCurrentConffilePrompt(old.execution, old.question), "live question unavailable");
        Check(D::AnswerConffilePrompt(old.execution, old.question, true), "keep-old answer failed");
        Check(!D::AnswerConffilePrompt(old.execution, old.question, false), "question answered twice");
        Reap(child, io);
        Check(!D::IsCurrentConffilePrompt(old.execution, old.question), "settled question stayed active");
    }
    {
        D::ConffileExecution io({}); const auto child = Spawn(argv[0], io, "new");
        const auto current = events.Wait(2);
        Check(current.execution != old.execution, "execution generation reused");
        Check(!D::AnswerConffilePrompt(old.execution, old.question, true), "stale answer reached a later child");
        Check(D::AnswerConffilePrompt(current.execution, current.question, false), "accept-new answer failed");
        Reap(child, io);
    }
    {
        D::ConffileExecution io({"--force-confold"}); const auto before = events.Count();
        Reap(Spawn(argv[0], io, "automatic"), io);
        Check(events.Count() == before, "forced policy opened answer UI");
    }
    {
        D::ConffileExecution io({"--force-confdef"});
        const auto child = Spawn(argv[0], io, "old");
        const auto current = events.Wait(3);
        Check(D::AnswerConffilePrompt(current.execution, current.question, true), "confdef alone suppressed a required question");
        Reap(child, io);
    }
    for (const char *mode : {"oversized", "malformed"}) {
        D::ConffileExecution io({});
        const auto before = events.Count();
        Reap(Spawn(argv[0], io, mode), io);
        Check(events.Count() == before, "unreadable prompt created an answerable question");
    }
    Check(events.unavailable == 2, "unreadable questions did not fail visibly");
    {
        D::ConffileExecution io({});
        const std::string progress("pmstatus:sample:50:Configuring sample\n");
        const auto before = events.Count();
        Check(Write(io.statusDescriptor(), progress + notification), "legacy question fixture");
        const auto question = events.Wait(before + 1);
        std::size_t statuses;
        { std::lock_guard<std::mutex> lock(events.mutex); statuses = events.statuses.size(); }
        Check(Write(io.statusDescriptor(), progress), "unchanged progress fixture");
        { std::unique_lock<std::mutex> lock(events.mutex);
            Check(events.changed.wait_for(lock, std::chrono::seconds(3), [&] { return events.statuses.size() > statuses; }), "progress timeout"); }
        Check(D::IsCurrentConffilePrompt(question.execution, question.question), "unchanged progress dismissed a question");
        Check(Write(io.statusDescriptor(), notification), "replacement question fixture");
        const auto replacement = events.Wait(before + 2);
        Check(!D::AnswerConffilePrompt(question.execution, question.question, true), "superseded question accepted");
        Check(D::IsCurrentConffilePrompt(replacement.execution, replacement.question), "replacement question unavailable");
        io.Finish();
    }
    {
        D::ConffileExecution io({});
        D::ConffileExecution overlap({}); Check(overlap.enabled() && !overlap.valid(), "overlapping execution accepted");
        const auto child = Spawn(argv[0], io, "expired");
        // A notification followed by immediate exit may be discarded before
        // presentation; neither outcome authorizes a post-exit answer.
        Reap(child, io);
        for (const auto &question : events.questions)
            Check(!D::AnswerConffilePrompt(question.execution, question.question, false), "late answer accepted");
    }
    {
        D::ConffileExecution io({});
        const int previous = fcntl(STDIN_FILENO, F_GETFD);
        { D::ScopedConffileStandardInput scoped(io); Check(scoped.valid(), "legacy stdin scope"); }
        Check(fcntl(STDIN_FILENO, F_GETFD) == previous, "legacy stdin flags not restored");
        io.Finish();
    }
    {
        // A descendant could retain and flood status after the actual dpkg
        // exits. Ending that execution must not join its reader indefinitely.
        D::ConffileExecution io({});
        const int retained = dup(io.statusDescriptor()); Check(retained >= 0, "retained status writer");
        Check(fcntl(retained, F_SETFL, O_NONBLOCK) == 0, "nonblocking retained writer");
        std::atomic<bool> done{false};
        const auto previousSignal = std::signal(SIGPIPE, SIG_IGN);
        std::thread flood([&]() {
            const std::string bytes(4093, 'x');
            while (!done.load()) {
                if (write(retained, bytes.data(), bytes.size()) < 0 && errno != EAGAIN && errno != EINTR) break;
                std::this_thread::yield();
            }
        });
        const auto start = std::chrono::steady_clock::now();
        io.Finish();
        const auto elapsed = std::chrono::steady_clock::now() - start;
        done.store(true); flood.join(); close(retained);
        std::signal(SIGPIPE, previousSignal);
        Check(elapsed < std::chrono::seconds(2), "retained status writer prevented bounded settlement");
    }
    {
        namespace P = CydiaAPT::Provider;
        namespace N = P::NativeEffectPolicy;
        const std::string profile("dpkg-1.23.7-effects-1");
        N::Match matched; matched.status = N::Status::Matched;
        auto settings = std::make_shared<N::Settings>(); matched.settings = settings;
        Check(P::ConffilePolicyForMatch(matched, profile) == D::ConffileInputPolicy::Interactive, "complete empty force subset is interactive");
        for (const auto force : {N::Force::Confold, N::Force::Confnew, N::Force::Confdef}) {
            settings->forces = {force};
            const auto policy = P::ConffilePolicyForMatch(matched, profile);
            Check(policy == D::ConffileInputPolicy::Automatic, "native configured automatic force lost");
            D::ConffileExecution io({}, true, true);
            Check(io.ApplyPolicy(policy) && !io.ApplyPolicy(D::ConffileInputPolicy::Interactive), "policy can be applied only once");
            const auto before = events.Count();
            Reap(Spawn(argv[0], io, "automatic"), io);
            Check(events.Count() == before, "matched cfg force queued a question");
        }
        // A distributor record for the exact finalized --refuse-confold prefix
        // describes the FINAL empty force set. argv hints must not override it.
        settings->forces.clear();
        {
            D::ConffileExecution io({"--force-confold", "--refuse-confold"}, true, true);
            Check(io.ApplyPolicy(P::ConffilePolicyForMatch(matched, profile)), "final cfg refusal policy");
            const auto count = events.Count(); const auto child = Spawn(argv[0], io, "old");
            const auto question = events.Wait(count + 1);
            Check(D::AnswerConffilePrompt(question.execution, question.question, true), "final refusal restored input");
            Reap(child, io);
        }
        matched.status = N::Status::Missing;
        Check(P::ConffilePolicyForMatch(matched, profile) == D::ConffileInputPolicy::Unverified, "missing effect policy guessed");
        matched.status = N::Status::Matched; settings->forces = {N::Force::Confdef};
        Check(P::ConffilePolicyForMatch(matched, "unmodeled-vendor") == D::ConffileInputPolicy::Unverified, "unknown default inferred");
        for (const auto policy : {D::ConffileInputPolicy::Unverified, D::ConffileInputPolicy::DefaultUnknown, D::ConffileInputPolicy::Pending}) {
            D::ConffileExecution io({}, true, true);
            if (policy != D::ConffileInputPolicy::Pending) Check(io.ApplyPolicy(policy), "suppressed policy setup");
            const auto before = events.Count(); Reap(Spawn(argv[0], io, "suppressed"), io);
            Check(events.Count() == before && !D::AnswerConffilePrompt(old.execution, old.question, true), "unverified policy wrote an answer");
        }
        std::vector<std::string> source{"--root=/", "--admindir=/db", "--pre-invoke", "--status-fd=99", "--status-fd", "7", "--configure", "sample"}, final;
        Check(P::FinalizeNativeChildArguments(source, 7, 4, 7, &final) && final[3] == "--status-fd=99" &&
            final[4] == "--status-fd" && final[5] == "3" && final.back() == "sample" &&
            P::ValidFinalNativeChildArguments(final, 4), "exact status span preserves opaque hook text");
        Check(!P::FinalizeNativeChildArguments(source, 5, 4, 7, &final) && final.empty(), "split status value crossed prefix");
        Check(!P::FinalizeNativeChildArguments(source, 7, 4, 8, &final), "wrong received descriptor accepted");
        Check(!P::FinalizeNativeChildArguments(source, 7, 7, 7, &final), "operand became status option");
    }
    D::SetConffileCallbacks({});
    D::ConffileExecution disabled({}); Check(!disabled.enabled() && disabled.valid(), "headless behavior changed");
    std::cout << "[dpkg-conffile] OK\n";
}
