/* Immutable native launch environment fixtures; no ambient mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/NativeLaunchEnvironment.hpp"
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <iostream>
#include <spawn.h>
#include <sys/wait.h>
#include <utility>

namespace {
using Environment = CydiaRuntime::NativeLaunchEnvironment;
using Error = Environment::Error;
void Require(bool value, const char *why) {
    if (value) return;
    std::cerr << "[native-launch-environment] " << why << '\n'; std::exit(1);
}
Environment Make(const std::vector<std::string> &entries) {
    Environment result; Error error = Error::NotInitialized;
    Require(Environment::FromEntries(entries, &result, &error) && result.initialized() && error == Error::None,
        "valid explicit entries create an initialized snapshot");
    return result;
}
void ExpectFailure(const std::vector<std::string> &entries, Error expected) {
    auto result = Make({"PREVIOUS=value"}); Error error = Error::None;
    Require(!Environment::FromEntries(entries, &result, &error) && error == expected && !result.initialized(),
        "invalid entries invalidate output with the exact typed failure");
    Environment::Envp view;
    Require(!result.BuildEnvp(&view) && !view.initialized() && view.data() == nullptr,
        "invalid input cannot silently yield an explicit empty or inherited environment");
}
std::string Sized(const std::string &name, std::size_t bytes) {
    const auto prefix = name + '=';
    Require(bytes >= prefix.size(), "sized fixture fits its name");
    return prefix + std::string(bytes - prefix.size(), 'x');
}
void ExactValuesAndDefault() {
    Environment absent; Environment::Envp invalid; Error error = Error::None;
    Require(!absent.initialized() && !absent.BuildEnvp(&invalid, &error) && error == Error::NotInitialized &&
        !invalid.initialized() && invalid.data() == nullptr, "default environment has no launch pointers");
    auto empty = Make({}); Environment::Envp emptyView;
    Require(empty.BuildEnvp(&emptyView) && emptyView.initialized() && emptyView.data() && !emptyView.data()[0],
        "explicit empty environment is a nonnull array with exactly its null terminator");
    const std::string bytes = std::string("VALUE=two words\nline\t=") + char(0xff);
    auto environment = Make({"Z=last", "A0=digit", "EMPTY=", bytes, "A=short", "_PRIVATE=yes"});
    const std::vector<std::string> expected = {"A=short", "A0=digit", "EMPTY=", bytes, "Z=last", "_PRIVATE=yes"};
    Require(environment.entries() == expected, "canonical sorting uses names, with opaque exact values");
    Environment::Envp view;
    Require(environment.BuildEnvp(&view), "valid snapshot supplies explicit pointers");
    for (std::size_t i = 0; i < expected.size(); ++i)
        Require(view.data()[i] && expected[i] == view.data()[i], "envp strings exactly match retained values");
    Require(!view.data()[expected.size()], "envp is null terminated without extra entries");
    Require(!Environment::FromEntries({}, nullptr, &error) && error == Error::InvalidOutput &&
        !environment.BuildEnvp(nullptr, &error) && error == Error::InvalidOutput,
        "missing output pointers fail explicitly");
}
void InvalidSyntax() {
    ExpectFailure({"MISSING"}, Error::MissingEquals);
    ExpectFailure({""}, Error::MissingEquals);
    for (const auto &entry : {"=value", "9BAD=value", "BAD-NAME=value", "BAD.NAME=value", "BAD NAME=value", "A\nB=value"})
        ExpectFailure({entry}, Error::InvalidName);
    ExpectFailure({std::string("A\0B=value", 9)}, Error::EmbeddedNul);
    ExpectFailure({std::string("A=left\0right", 12)}, Error::EmbeddedNul);
    ExpectFailure({std::string(1, char(0xff)) + "=value"}, Error::InvalidName);
    ExpectFailure({"A=first", "A=second"}, Error::DuplicateName);
    ExpectFailure({"A=", "A="}, Error::DuplicateName);
    Require(Make({"A=value", "a=other"}).entries().size() == 2, "variable names are case sensitive");
}
void Bounds() {
    using namespace CydiaRuntime;
    const auto maxEntry = MaximumNativeEnvironmentEntryBytes;
    Require(Make({Sized("EXACT", maxEntry)}).entries()[0].size() == maxEntry, "maximum entry length is inclusive");
    ExpectFailure({Sized("LARGE", maxEntry + 1)}, Error::EntryTooLarge);
    std::vector<std::string> count;
    for (std::size_t i = 0; i < MaximumNativeEnvironmentEntries; ++i) count.push_back("V" + std::to_string(i) + '=');
    Require(Make(count).entries().size() == MaximumNativeEnvironmentEntries, "maximum entry count is inclusive");
    count.push_back("EXCESS="); ExpectFailure(count, Error::TooManyEntries);
    std::vector<std::string> total;
    for (unsigned i = 0; i != 15; ++i) total.push_back(Sized("V" + std::to_string(i), maxEntry));
    const auto last = MaximumNativeEnvironmentBytes - 15 * (maxEntry + 1) - 1;
    total.push_back(Sized("V15", last));
    Require(Make(total).entries().size() == 16, "total limit includes every terminating NUL and accepts exact boundary");
    total.back().push_back('x'); ExpectFailure(total, Error::TotalTooLarge);
}
void Overlays() {
    auto source = Make({"KEEP=old", "REMOVE=value", "EMPTY=previous"});
    Environment result; Error error = Error::NotInitialized;
    Require(source.Overlay({"DPKG_FRONTEND_LOCKED=1", "EMPTY=", "KEEP=new"}, {"REMOVE", "ABSENT"}, &result, &error) &&
        error == Error::None && result.entries() == std::vector<std::string>({"DPKG_FRONTEND_LOCKED=1", "EMPTY=", "KEEP=new"}),
        "explicit overlay replaces, adds, unsets, and preserves empty values");
    Require(source.entries() == std::vector<std::string>({"EMPTY=previous", "KEEP=old", "REMOVE=value"}),
        "overlay never modifies the source snapshot");
    Require(result.Overlay({}, {"EMPTY"}, &result) && result.entries() == std::vector<std::string>({"DPKG_FRONTEND_LOCKED=1", "KEEP=new"}),
        "in-place output assignment returns a new snapshot and distinguishes absent from empty");
    Environment::Envp before;
    Require(result.BuildEnvp(&before), "retain pointer view before failed alias overlay");
    Require(!result.Overlay({"KEEP=again"}, {"KEEP"}, &result, &error) && error == Error::ConflictingOverlay && !result.initialized() &&
        std::strcmp(before.data()[1], "KEEP=new") == 0, "conflicting alias overlay invalidates output without invalidating earlier views");
    Require(!source.Overlay({"A=1", "A=2"}, {}, &result, &error) && error == Error::DuplicateName,
        "duplicate assignments cannot pick an accidental winner");
    Require(!source.Overlay({}, {"REMOVE", "REMOVE"}, &result, &error) && error == Error::DuplicateName,
        "duplicate removals refuse");
    Require(!source.Overlay({}, {"REMOVE="}, &result, &error) && error == Error::InvalidName,
        "unset entries are exact names rather than assignment strings");
    Environment invalid;
    Require(!invalid.Overlay({"A=1"}, {}, &result, &error) && error == Error::NotInitialized && !result.initialized(),
        "overlay cannot initialize a default snapshot implicitly");
    Require(source.Overlay({}, {}, &result) && result.entries() == source.entries(), "empty overlay preserves exact contents");
    Require(Environment::FromEntries(result.entries(), &result) && result.entries() == source.entries(),
        "FromEntries safely supports input that aliases the output snapshot");
}
void OverlayBounds() {
    using namespace CydiaRuntime;
    std::vector<std::string> entries;
    for (std::size_t i = 0; i < MaximumNativeEnvironmentEntries; ++i) entries.push_back("V" + std::to_string(i) + '=');
    auto full = Make(entries); Environment result; Error error;
    Require(full.Overlay({"V0=changed"}, {}, &result) && result.entries().size() == MaximumNativeEnvironmentEntries,
        "replacement at count capacity does not invent an extra entry");
    Require(!full.Overlay({"EXTRA=value"}, {}, &result, &error) && error == Error::TooManyEntries && !result.initialized(),
        "overlay result count is independently bounded");
    Require(full.Overlay({"EXTRA=value"}, {"V0"}, &result) && result.entries().size() == MaximumNativeEnvironmentEntries,
        "explicit removal permits a replacement name at count capacity");
    std::vector<std::string> removal(MaximumNativeEnvironmentEntries, "ABSENT");
    Require(!full.Overlay({"X=value"}, removal, &result, &error) && error == Error::TooManyEntries,
        "combined edit count is bounded before duplicate parsing");
    std::vector<std::string> base, addition;
    for (unsigned i = 0; i != 8; ++i) {
        base.push_back(Sized("BASE" + std::to_string(i), MaximumNativeEnvironmentEntryBytes));
        addition.push_back(Sized("NEW" + std::to_string(i), MaximumNativeEnvironmentEntryBytes));
    }
    Require(!Make(base).Overlay(addition, {}, &result, &error) && error == Error::TotalTooLarge,
        "individually bounded base and overlay cannot produce an oversized merged environment");
    Require(!full.Overlay({Sized("X", MaximumNativeEnvironmentEntryBytes + 1)}, {}, &result, &error) && error == Error::EntryTooLarge,
        "oversized overlay values refuse before replacement copies");
}
void CopyAndPointerLifetime() {
    Environment::Envp retained;
    {
        auto source = Make({"LONG=" + std::string(4096, 'x'), "SHORT=value"});
        auto copy = source;
        Require(source.BuildEnvp(&retained), "create owned launch view");
        source = Environment();
        Require(copy.initialized() && copy.entries().size() == 2 && retained.initialized(),
            "snapshot copy and launch view retain immutable storage independently");
        Require(copy.Overlay({"SHORT=replaced"}, {}, &copy), "copy can be replaced independently");
        Require(std::strcmp(retained.data()[1], "SHORT=value") == 0, "overlay leaves previously retained pointer bytes unchanged");
    }
    Require(retained.data()[0] == std::string("LONG=" + std::string(4096, 'x')) &&
        std::strcmp(retained.data()[1], "SHORT=value") == 0 && !retained.data()[2],
        "owned pointers survive destruction of all source snapshots");
    auto copied = retained;
    retained = Environment::Envp();
    Require(copied.initialized() && std::strcmp(copied.data()[1], "SHORT=value") == 0,
        "copied pointer views retain storage after the original view is reset");
    auto moved = std::move(copied);
    Require(moved.initialized() && !copied.initialized() && copied.data() == nullptr &&
        std::strcmp(moved.data()[1], "SHORT=value") == 0, "moving a view retains pointers and makes its source invalid");
    Environment invalid; Error error;
    Require(!invalid.BuildEnvp(&moved, &error) && error == Error::NotInitialized && moved.data() == nullptr,
        "failed view construction cannot retain stale usable pointers");
}
void CaptureChild() {
    Environment captured; Error error = Error::NotInitialized;
    Require(Environment::CaptureProcess(&captured, &error) && error == Error::None &&
        captured.entries() == std::vector<std::string>({"A=prefix", "A0=digit", "EMPTY=", "VALUE=two words\nsecond=line"}),
        "process capture retains the exact explicit environment without ambient inheritance or normalization");
    Environment::Envp view;
    Require(captured.BuildEnvp(&view) && view.data()[2] && std::strcmp(view.data()[2], "EMPTY=") == 0 && !view.data()[4],
        "captured process environment yields exact owned launch pointers");
}
void ProcessCapture(const char *self) {
    // Use the same fixture executable, not a shell or an installed helper.
    // An explicit envp gives deterministic process input without setenv or
    // temporarily replacing the parent's ambient environ pointer.
    auto snapshot = Make({"VALUE=two words\nsecond=line", "EMPTY=", "A0=digit", "A=prefix"});
    Environment::Envp environment;
    Require(snapshot.BuildEnvp(&environment), "prepare deterministic child capture input");
    char *arguments[] = {const_cast<char *>(self), const_cast<char *>("--capture-child"), nullptr};
    pid_t pid = -1;
    Require(posix_spawn(&pid, self, nullptr, nullptr, arguments, environment.data()) == 0,
        "spawn own fixture with explicit capture input");
    int status = 0; pid_t waited;
    do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
    Require(waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "capture child observes exactly the supplied environment");
}
}
int main(int argc, char **argv) {
    if (argc == 2 && std::strcmp(argv[1], "--capture-child") == 0) { CaptureChild(); return 0; }
    ExactValuesAndDefault(); InvalidSyntax(); Bounds(); Overlays(); OverlayBounds(); CopyAndPointerLifetime();
    ProcessCapture(argv[0]);
    std::cout << "[native-launch-environment] PASS: exact explicit environments, bounds, overlays and owned pointer lifetime\n";
}
