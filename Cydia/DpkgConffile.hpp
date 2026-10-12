/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_DpkgConffile_HPP
#define Cydia_DpkgConffile_HPP
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace CydiaRuntime { namespace Dpkg {
struct ConffilePrompt {
    std::uint64_t execution = 0, question = 0;
    std::string oldPath, newPath;
    bool userEdited = false, distributionEdited = false;
};
// dpkg's raw status record and APT's pmconffile record share this payload.
// Bounded parsing permits spaces; ambiguous quoted path pairs are refused.
bool ParseConffilePrompt(const std::string &payload, ConffilePrompt *prompt);
bool ParseConffileStatus(const std::string &line, ConffilePrompt *prompt);
// Only explicit argv force-old/new choices are independently known to settle
// without input. Absence and confdef alone do not establish native dpkg policy.
bool ConffileChoiceIsAutomatic(const std::vector<std::string> &arguments);

struct ConffileCallbacks {
    std::function<void(const std::string &)> status;
    std::function<void(const ConffilePrompt &)> question;
    std::function<void(std::uint64_t, std::uint64_t)> invalidated;
    // A bounded/malformed prompt cannot safely be answered. Input is closed
    // without a choice; dpkg retains ownership of its resulting diagnostic.
    std::function<void()> unavailable;
};
// Install once before package work. Callbacks can arrive on a reader thread;
// UI delivery must recheck IsCurrentConffilePrompt before displaying anything.
void SetConffileCallbacks(const ConffileCallbacks &callbacks);
bool IsCurrentConffilePrompt(std::uint64_t execution, std::uint64_t question);
bool AnswerConffilePrompt(std::uint64_t execution, std::uint64_t question, bool keepOld);

// One parent-owned input/status pair per dpkg child. Replies cannot outlive the
// execution or be consumed by the next child, even if dpkg emitted a prompt
// notification then used its native automatic policy. This status protocol
// cannot prove that arbitrary maintainer code is currently waiting on stdin.
class ConffileExecution {
    struct State;
    std::shared_ptr<State> state_;
    bool enabled_ = false;
public:
    explicit ConffileExecution(const std::vector<std::string> &arguments, bool enabled = true);
    ~ConffileExecution();
    ConffileExecution(const ConffileExecution &) = delete;
    ConffileExecution &operator=(const ConffileExecution &) = delete;
    bool enabled() const { return enabled_; }
    bool valid() const;
    int inputDescriptor() const;
    int statusDescriptor() const;
    // After a successful spawn, close the parent's copies of child-only ends.
    void ChildStarted();
    // Call only after the real child has settled. Does not kill that child.
    void Finish();
    friend bool IsCurrentConffilePrompt(std::uint64_t, std::uint64_t);
    friend bool AnswerConffilePrompt(std::uint64_t, std::uint64_t, bool);
};

// Transitional in-process APT has no per-child callback. Scope its inherited
// fd0 to this execution and restore it afterward; its internal dpkg batches
// remain one scope. Brokered children use spawn dup2 actions instead.
class ScopedConffileStandardInput {
    int saved_ = -1;
    int flags_ = 0;
    bool valid_ = true;
public:
    explicit ScopedConffileStandardInput(const ConffileExecution &execution);
    ~ScopedConffileStandardInput();
    bool valid() const { return valid_; }
    ScopedConffileStandardInput(const ScopedConffileStandardInput &) = delete;
    ScopedConffileStandardInput &operator=(const ScopedConffileStandardInput &) = delete;
};
}}
#endif
