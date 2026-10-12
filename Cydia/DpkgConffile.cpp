/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/DpkgConffile.hpp"
#include "Cydia/DpkgStatusParser.hpp"
#include <atomic>
#include <cerrno>
#include <fcntl.h>
#include <limits>
#include <mutex>
#include <poll.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

namespace CydiaRuntime { namespace Dpkg {
namespace {
constexpr std::size_t MaximumLine = 65536, MaximumPath = 4096;
std::mutex registryMutex;
ConffileCallbacks callbacks;
std::weak_ptr<void> active;
std::uint64_t nextExecution = 0;
void Close(int &fd) { if (fd >= 0) close(fd); fd = -1; }
bool Descriptor(int &fd) {
    if (fd < 3) { const int copy = fcntl(fd, F_DUPFD, 3); if (copy < 0) return false; close(fd); fd = copy; }
    return fcntl(fd, F_SETFD, FD_CLOEXEC) == 0;
}
bool Path(const std::string &value) {
    return !value.empty() && value.front() == '/' && value.size() <= MaximumPath &&
        value.find_first_of("\r\n") == std::string::npos && value.find('\0') == std::string::npos;
}
}
bool ParseConffilePrompt(const std::string &payload, ConffilePrompt *prompt) {
    if (!prompt || payload.size() > MaximumLine || payload.empty() || payload.front() != '\'') return false;
    const auto end = payload.find_last_not_of(' ');
    if (end == std::string::npos || end < 7 || (payload[end] != '0' && payload[end] != '1') ||
        payload[end - 1] != ' ' || (payload[end - 2] != '0' && payload[end - 2] != '1') ||
        payload[end - 3] != ' ' || payload[end - 4] != '\'') return false;
    const auto separator = payload.find("' '", 1);
    if (separator == std::string::npos || separator + 3 > end - 4 ||
        payload.find("' '", separator + 3) != std::string::npos) return false;
    ConffilePrompt parsed;
    parsed.oldPath = payload.substr(1, separator - 1);
    parsed.newPath = payload.substr(separator + 3, end - 4 - separator - 3);
    if (!Path(parsed.oldPath) || !Path(parsed.newPath)) return false;
    parsed.userEdited = payload[end - 2] == '1'; parsed.distributionEdited = payload[end] == '1';
    *prompt = std::move(parsed); return true;
}
bool ParseConffileStatus(const std::string &line, ConffilePrompt *prompt) {
    if (line.size() > MaximumLine) return false;
    if (line.compare(0, 8, "status: ") == 0) {
        const std::string marker(" : conffile-prompt : ");
        const auto at = line.find(marker, 8);
        return at != std::string::npos && Path(line.substr(8, at - 8)) &&
            ParseConffilePrompt(line.substr(at + marker.size()), prompt);
    }
    PackageManagerProgressRecord record;
    return ParsePackageManagerProgress(line, &record) && record.type == "pmconffile" &&
        ParseConffilePrompt(record.message, prompt);
}
bool ConffileChoiceIsAutomatic(const std::vector<std::string> &arguments) {
    // These exact switches are the protected option spellings admitted by the
    // broker. Do not infer config-file choices or interpret arbitrary argv.
    bool automatic = false;
    for (const auto &argument : arguments) {
        if (argument == "--") break;
        if (argument == "--force-confold" || argument == "--force-confnew") automatic = true;
        else if ((argument.compare(0, 8, "--force-") == 0 || argument.compare(0, 8, "--force=") == 0 ||
            argument.compare(0, 11, "--no-force-") == 0 || argument.compare(0, 9, "--refuse-") == 0) &&
            argument.find("conf") != std::string::npos && argument != "--force-confdef" &&
            argument != "--force-confmiss" && argument != "--force-confask") return false;
    }
    return automatic;
}

struct ConffileExecution::State {
    std::mutex mutex;
    std::atomic<bool> stop{false};
    ConffileCallbacks callbacks;
    std::thread reader;
    int input = -1, writer = -1, status = -1, readerFd = -1;
    std::uint64_t execution = 0, nextQuestion = 0, question = 0;
    bool alive = true, automatic = false, unavailable = false;
    std::string lastProgress;
    ~State() { Close(input); Close(writer); Close(status); Close(readerFd); }
    void Invalidate() {
        std::uint64_t old;
        { std::lock_guard<std::mutex> lock(mutex); old = question; question = 0; }
        if (old && callbacks.invalidated) callbacks.invalidated(execution, old);
    }
    void Unavailable() {
        Invalidate();
        { std::lock_guard<std::mutex> lock(mutex);
            if (!alive || automatic || unavailable) return;
            unavailable = true; Close(writer);
        }
        if (callbacks.unavailable) callbacks.unavailable();
    }
    void Line(const std::string &line) {
        ConffilePrompt prompt;
        const bool isPrompt = ParseConffileStatus(line, &prompt);
        const bool claimsPrompt = line.compare(0, 11, "pmconffile:") == 0 ||
            (line.compare(0, 8, "status: ") == 0 && line.find(" : conffile-prompt : ", 8) != std::string::npos);
        if (claimsPrompt && !isPrompt) {
            Unavailable(); if (callbacks.status) callbacks.status(line); return;
        }
        const bool pmstatus = line.compare(0, 9, "pmstatus:") == 0;
        const bool progressed = pmstatus && line != lastProgress;
        if (pmstatus) lastProgress = line;
        // A new status/progression supersedes a question. Output from stdout
        // does not establish that dpkg progressed and is deliberately ignored.
        if (isPrompt || line.compare(0, 8, "status: ") == 0 || line.compare(0, 12, "processing: ") == 0 ||
            progressed || line.compare(0, 8, "pmerror:") == 0) Invalidate();
        if (isPrompt) {
            { std::lock_guard<std::mutex> lock(mutex);
                if (!alive || automatic || unavailable || nextQuestion == std::numeric_limits<std::uint64_t>::max()) return;
                prompt.execution = execution; prompt.question = question = ++nextQuestion;
            }
            if (callbacks.question) callbacks.question(prompt);
        } else if (callbacks.status) callbacks.status(line);
    }
    void Read() {
        std::string line; bool oversized = false;
        std::size_t tailBudget = 4 * MaximumLine;
        while (true) {
            const bool stopping = stop.load();
            if (stopping && tailBudget == 0) break;
            pollfd item{readerFd, POLLIN, 0};
            const int ready = poll(&item, 1, stopping ? 0 : 100);
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0 || (ready && (item.revents & (POLLERR | POLLNVAL)))) break;
            if (!ready) { if (stopping) break; continue; }
            char bytes[4096];
            const auto capacity = stopping && tailBudget < sizeof(bytes) ? tailBudget : sizeof(bytes);
            const ssize_t count = read(readerFd, bytes, capacity);
            if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            if (count <= 0) break;
            if (stopping) tailBudget -= static_cast<std::size_t>(count);
            for (ssize_t i = 0; i < count; ++i) {
                if (bytes[i] == '\n') {
                    if (!oversized) Line(line);
                    line.clear(); oversized = false;
                } else if (!oversized) {
                    if (line.size() == MaximumLine) { line.clear(); oversized = true; Unavailable(); }
                    else line.push_back(bytes[i]);
                }
            }
        }
        Invalidate();
    }
};
void SetConffileCallbacks(const ConffileCallbacks &value) {
    std::lock_guard<std::mutex> lock(registryMutex); callbacks = value;
}
ConffileExecution::ConffileExecution(const std::vector<std::string> &arguments, bool enable) {
    std::lock_guard<std::mutex> lock(registryMutex);
    enabled_ = enable && static_cast<bool>(callbacks.question);
    if (!enabled_ || !active.expired() || nextExecution == std::numeric_limits<std::uint64_t>::max()) return;
    std::shared_ptr<State> state(new State());
    state->callbacks = callbacks; state->automatic = ConffileChoiceIsAutomatic(arguments);
    int input[2] = {-1, -1}, status[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, input) != 0) return;
    state->input = input[0]; state->writer = input[1];
    if (pipe(status) != 0) return;
    state->readerFd = status[0]; state->status = status[1];
    for (int *fd : {&state->input, &state->writer, &state->readerFd, &state->status}) if (!Descriptor(*fd)) return;
    if (fcntl(state->writer, F_SETFL, O_NONBLOCK) != 0) return;
#ifdef SO_NOSIGPIPE
    int yes = 1;
    if (setsockopt(state->writer, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) != 0) return;
#endif
    state->execution = ++nextExecution;
    try { state->reader = std::thread([state]() { state->Read(); }); }
    catch (...) { return; }
    state_ = state; active = state;
}
ConffileExecution::~ConffileExecution() { Finish(); }
bool ConffileExecution::valid() const { return !enabled_ || state_ != nullptr; }
int ConffileExecution::inputDescriptor() const { return state_ ? state_->input : -1; }
int ConffileExecution::statusDescriptor() const { return state_ ? state_->status : -1; }
void ConffileExecution::ChildStarted() { if (state_) { Close(state_->input); Close(state_->status); } }
void ConffileExecution::Finish() {
    if (!state_) return;
    auto state(state_);
    { std::lock_guard<std::mutex> lock(state->mutex); state->alive = false; Close(state->writer); }
    state->Invalidate(); state->stop.store(true);
    Close(state->input); Close(state->status);
    if (state->reader.joinable()) state->reader.join();
    { std::lock_guard<std::mutex> lock(registryMutex); if (active.lock() == state) active.reset(); }
    state_.reset();
}
bool IsCurrentConffilePrompt(std::uint64_t execution, std::uint64_t question) {
    std::shared_ptr<ConffileExecution::State> state;
    { std::lock_guard<std::mutex> lock(registryMutex); state = std::static_pointer_cast<ConffileExecution::State>(active.lock()); }
    if (!state) return false;
    std::lock_guard<std::mutex> lock(state->mutex);
    return question && state->alive && state->execution == execution && state->question == question;
}
bool AnswerConffilePrompt(std::uint64_t execution, std::uint64_t question, bool keepOld) {
    std::shared_ptr<ConffileExecution::State> state;
    { std::lock_guard<std::mutex> lock(registryMutex); state = std::static_pointer_cast<ConffileExecution::State>(active.lock()); }
    if (!state) return false;
    bool success = false;
    { std::lock_guard<std::mutex> lock(state->mutex);
        if (!question || !state->alive || state->execution != execution || state->question != question || state->writer < 0) return false;
        const char *answer = keepOld ? "N\n" : "Y\n";
        ssize_t written;
        do {
#ifdef MSG_NOSIGNAL
            written = send(state->writer, answer, 2, MSG_NOSIGNAL);
#else
            written = send(state->writer, answer, 2, 0);
#endif
        } while (written < 0 && errno == EINTR);
        state->question = 0; success = written == 2;
        // A short write cannot be retried as a second answer; close input so a
        // partial line fails visibly instead of waiting or reaching a new child.
        if (!success) Close(state->writer);
    }
    if (state->callbacks.invalidated) state->callbacks.invalidated(execution, question);
    return success;
}
ScopedConffileStandardInput::ScopedConffileStandardInput(const ConffileExecution &execution) {
    if (!execution.enabled()) return;
    if (!execution.valid()) { valid_ = false; return; }
    flags_ = fcntl(STDIN_FILENO, F_GETFD);
    if (flags_ < 0) { valid_ = false; return; }
    saved_ = fcntl(STDIN_FILENO, F_DUPFD, 3);
    if (saved_ < 0 || fcntl(saved_, F_SETFD, FD_CLOEXEC) != 0 || dup2(execution.inputDescriptor(), STDIN_FILENO) < 0) {
        Close(saved_); valid_ = false;
    }
}
ScopedConffileStandardInput::~ScopedConffileStandardInput() {
    if (saved_ >= 0) { if (dup2(saved_, STDIN_FILENO) >= 0) fcntl(STDIN_FILENO, F_SETFD, flags_); Close(saved_); }
}
}}
