/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/DpkgRunner.h"
#include "Cydia/NativeLaunchEnvironment.hpp"

#include <cerrno>
#include <climits>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include <fcntl.h>
#include <unistd.h>

extern char **environ;

namespace {

const char kArgument[] = "argument with spaces;$(not-a-shell)";
const char kInput[] = "selection one install\nselection two deinstall\n";
const char kOutput[] = "dpkg runner output\n";
const char kFrozenName[] = "CYDIA_RUNNER_FIXTURE_VALUE";
const char kEmptyName[] = "CYDIA_RUNNER_FIXTURE_EMPTY";
const char kAbsentName[] = "CYDIA_RUNNER_FIXTURE_ABSENT";
const char kParentName[] = "CYDIA_RUNNER_FIXTURE_PARENT_ONLY";

std::string EnvironmentReport() {
    std::string result;
    for (const char *name : {kFrozenName, kEmptyName, kAbsentName, kParentName}) {
        const char *value(getenv(name));
        result += std::string(name) + '=' + (value == NULL ? "<absent>" : value) + '\n';
    }
    return result;
}

std::string FrozenReport() {
    return std::string(kFrozenName) + "=frozen value\n" + kEmptyName + "=\n" +
        kAbsentName + "=<absent>\n" + kParentName + "=<absent>\n";
}

std::vector<std::string> ParentEnvironment() {
    std::vector<std::string> entries;
    if (environ != NULL) for (char **entry = environ; *entry != NULL; ++entry) entries.push_back(*entry);
    return entries;
}

void Expect(bool condition, const char *message) {
    if (condition)
        return;
    std::cerr << "[verify-dpkg-runner][FAIL] " << message << std::endl;
    std::exit(1);
}

std::string ReadDescriptor(int descriptor) {
    std::string contents;
    char buffer[256];
    for (;;) {
        const ssize_t count(read(descriptor, buffer, sizeof(buffer)));
        if (count > 0) {
            contents.append(buffer, static_cast<size_t>(count));
            continue;
        }
        if (count == -1 && errno == EINTR)
            continue;
        Expect(count == 0, "read fixture descriptor");
        return contents;
    }
}

std::string ReadStandardInput() {
    return ReadDescriptor(STDIN_FILENO);
}

int ParseStatusDescriptor(int argc, char *argv[], int *count) {
    int descriptor = -1;
    *count = 0;
    for (int index = 3; index != argc; ++index) {
        if (strcmp(argv[index], "--status-fd") == 0 && index + 1 != argc) {
            descriptor = atoi(argv[++index]);
            ++*count;
        } else if (strncmp(argv[index], "--status-fd=", sizeof("--status-fd=") - 1) == 0) {
            descriptor = atoi(argv[index] + sizeof("--status-fd=") - 1);
            ++*count;
        }
    }
    return descriptor;
}

int RunFixture(int argc, char *argv[]) {
    if (argc < 3)
        return 90;

    if (strcmp(argv[2], "exit") == 0)
        return argc == 4 ? atoi(argv[3]) : 91;

    if (strcmp(argv[2], "signal") == 0) {
        raise(SIGTERM);
        return 92;
    }

    if (strcmp(argv[2], "input") == 0)
        return argc == 4 && strcmp(argv[3], kArgument) == 0 && ReadStandardInput() == kInput ? 0 : 93;

    if (strcmp(argv[2], "close-input") == 0) {
        (void) close(STDIN_FILENO);
        return 0;
    }

    if (strcmp(argv[2], "output") == 0) {
        std::cout << kOutput;
        return 0;
    }
    if (strcmp(argv[2], "environment") == 0) {
        std::cout << EnvironmentReport(); return 0;
    }
    if (strcmp(argv[2], "environment-check") == 0)
        return EnvironmentReport() == FrozenReport() ? 0 : 97;
    if (strcmp(argv[2], "environment-input") == 0 || strcmp(argv[2], "environment-input-check") == 0) {
        if (ReadStandardInput() != kInput || EnvironmentReport() != FrozenReport()) return 98;
        if (strcmp(argv[2], "environment-input") == 0) std::cout << EnvironmentReport();
        return 0;
    }
    if (strcmp(argv[2], "environment-count") == 0) {
        std::size_t count = 0; if (environ != NULL) while (environ[count] != NULL) ++count;
        std::cout << count << '\n'; return 0;
    }
    if (strcmp(argv[2], "duplex") == 0) {
        std::cout << std::string(256 * 1024, 'p') << std::flush;
        if (ReadStandardInput() != std::string(1024 * 1024, 'q')) return 94;
        std::cout << "done"; return 0;
    }
    if (strcmp(argv[2], "wait") == 0) {
        std::cout << getpid() << std::endl;
        for (;;) pause();
    }
    if (strcmp(argv[2], "close-output-wait") == 0) {
        close(STDOUT_FILENO);
        for (;;) pause();
    }

    if (strcmp(argv[2], "status") == 0) {
        int count;
        const int descriptor(ParseStatusDescriptor(argc, argv, &count));
        if (count != 1 || descriptor < 0)
            return 94;
        const char payload[] = "status: ok\n";
        return write(descriptor, payload, sizeof(payload) - 1) == sizeof(payload) - 1 ? 0 : 95;
    }

    return 96;
}

std::string AbsoluteExecutable(const char *argument) {
    char resolved[PATH_MAX];
    Expect(realpath(argument, resolved) != NULL, "resolve test executable");
    return resolved;
}

std::string TemporaryOutputPath() {
    const char *temporary(getenv("TMPDIR"));
    std::string pattern(temporary == NULL || temporary[0] == '\0' ? "/tmp" : temporary);
    if (pattern[pattern.size() - 1] != '/')
        pattern += '/';
    pattern += "cydia-dpkg-runner.XXXXXX";

    std::vector<char> writable(pattern.begin(), pattern.end());
    writable.push_back('\0');
    const int descriptor(mkstemp(writable.data()));
    Expect(descriptor >= 0, "create temporary output");
    Expect(close(descriptor) == 0, "close temporary output");
    return writable.data();
}

std::string ReadFile(const std::string &path) {
    std::ifstream stream(path.c_str(), std::ios::in | std::ios::binary);
    Expect(stream.good(), "open redirected output");
    return std::string((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
}

void VerifyStatusDescriptor(const CydiaRuntime::Dpkg::Runner &runner, bool explicitArgument,
    const CydiaRuntime::NativeLaunchEnvironment *environment = nullptr) {
    int descriptors[2];
    Expect(pipe(descriptors) == 0, "create status pipe");
    Expect(fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0, "mark status descriptor close-on-exec");

    std::vector<std::string> arguments;
    arguments.push_back("--fixture");
    arguments.push_back("status");
    if (explicitArgument)
        arguments.push_back("--status-fd=" + std::to_string(descriptors[1]));

    const CydiaRuntime::Dpkg::Result result(environment == NULL ? runner.Run(arguments, descriptors[1]) :
        runner.Run(arguments, *environment, descriptors[1]));
    Expect(close(descriptors[1]) == 0, "close status writer");
    const std::string payload(ReadDescriptor(descriptors[0]));
    Expect(close(descriptors[0]) == 0, "close status reader");
    Expect(result.succeeded(), explicitArgument ? "preserve explicit status-fd" : "append status-fd");
    Expect(payload == "status: ok\n", "inherit close-on-exec status descriptor");
}

class SavedVariable {
    const char *name_;
    bool present_;
    std::string value_;
public:
    explicit SavedVariable(const char *name) : name_(name), present_(getenv(name) != NULL),
        value_(present_ ? getenv(name) : "") {}
    ~SavedVariable() {
        if (present_) (void) setenv(name_, value_.c_str(), 1);
        else (void) unsetenv(name_);
    }
};

void VerifyFrozenEnvironment(const CydiaRuntime::Dpkg::Runner &runner) {
    using CydiaRuntime::NativeLaunchEnvironment;
    using CydiaRuntime::Dpkg::ResultKind;
    SavedVariable savedValue(kFrozenName), savedEmpty(kEmptyName), savedAbsent(kAbsentName), savedParent(kParentName);
    Expect(setenv(kFrozenName, "frozen value", 1) == 0 && setenv(kEmptyName, "", 1) == 0 &&
        unsetenv(kAbsentName) == 0 && unsetenv(kParentName) == 0, "prepare parent environment for capture");
    NativeLaunchEnvironment captured, exact, empty;
    // Capture the controlled entries only. Runner correctness must not depend
    // on unrelated CI variables satisfying the native authority's admission.
    std::vector<std::string> captureEntries;
    for (const char *name : {kFrozenName, kEmptyName, kAbsentName, kParentName}) {
        const char *value(getenv(name)); if (value != NULL) captureEntries.push_back(std::string(name) + '=' + value);
    }
    Expect(NativeLaunchEnvironment::FromEntries(captureEntries, &captured), "capture initialized fixture environment");
    Expect(NativeLaunchEnvironment::FromEntries({std::string(kFrozenName) + "=frozen value", std::string(kEmptyName) + '='}, &exact),
        "construct explicit frozen environment");
    Expect(NativeLaunchEnvironment::FromEntries({}, &empty) && empty.initialized(), "construct valid empty environment");
    Expect(setenv(kFrozenName, "later parent", 1) == 0 && setenv(kEmptyName, "later nonempty", 1) == 0 &&
        setenv(kAbsentName, "now present", 1) == 0 && setenv(kParentName, "ambient only", 1) == 0,
        "change parent after capture");
    const auto before = ParentEnvironment();
    const std::string ambient(EnvironmentReport()); std::string output;
    auto result = runner.RunAndCaptureBounded({"--fixture", "environment"}, captured, &output, 4096, 2000);
    Expect(result.succeeded() && output == FrozenReport(), "child sees captured values after ambient environment changes");
    result = runner.RunAndCapture({"--fixture", "environment"}, &output);
    Expect(result.succeeded() && output == ambient, "existing overload still uses ambient environment");
    result = runner.RunAndCapture({"--fixture", "environment"}, exact, &output);
    Expect(result.succeeded() && output == FrozenReport(), "explicit capture distinguishes absent and empty values");
    result = runner.RunAndCaptureBounded({"--fixture", "environment-count"}, exact, &output, 4096, 2000);
    Expect(result.succeeded() && output == "2\n", "explicit environment is not merged with ambient entries");
    result = runner.RunAndCaptureBounded({"--fixture", "environment-count"}, empty, &output, 4096, 2000);
    Expect(result.succeeded() && output == "0\n", "initialized empty environment launches with a nonnull empty envp");
    result = runner.Run({"--fixture", "environment-check"}, exact);
    Expect(result.succeeded(), "ordinary run uses explicit snapshot");
    result = runner.RunWithInput({"--fixture", "environment-input-check"}, exact, kInput);
    Expect(result.succeeded(), "ordinary input run uses explicit snapshot");
    result = runner.RunWithInputAndCaptureBounded({"--fixture", "environment-input"}, exact, kInput, &output, 4096, 2000);
    Expect(result.succeeded() && output == FrozenReport(), "bounded duplex uses explicit snapshot and preserves input");
    NativeLaunchEnvironment replaced(captured); bool replacedBeforeSpawn = false;
    result = runner.RunAndCaptureBounded({"--fixture", "environment"}, replaced, &output, 4096, 2000, [&]() {
        if (!replacedBeforeSpawn) { replaced = empty; replacedBeforeSpawn = true; }
        return false;
    });
    Expect(result.succeeded() && output == FrozenReport() && replacedBeforeSpawn && replaced.entries().empty(),
        "owned envp retains original frozen values if caller reassigns its snapshot before spawn");
    const std::string path(TemporaryOutputPath());
    result = runner.RunToFile({"--fixture", "environment"}, exact, path);
    Expect(result.succeeded() && ReadFile(path) == FrozenReport(), "file redirection uses explicit snapshot");
    VerifyStatusDescriptor(runner, false, &exact); VerifyStatusDescriptor(runner, true, &exact);

    NativeLaunchEnvironment invalid;
    Expect(!invalid.initialized(), "default snapshot is not a valid empty environment");
    result = runner.RunToFile({"--fixture", "output"}, invalid, path);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EINVAL && ReadFile(path) == FrozenReport(),
        "uninitialized snapshot refuses before redirecting output or spawning");
    unsigned callbacks = 0; output = "stale";
    result = runner.RunAndCaptureBounded({"--fixture", "environment"}, invalid, &output, 4096, 2000,
        [&]() { ++callbacks; return false; });
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EINVAL && output.empty() && callbacks == 0,
        "uninitialized snapshot refuses before cancellation callbacks and clears capture");
    Expect(!NativeLaunchEnvironment::FromEntries({"malformed entry"}, &invalid) && !invalid.initialized(),
        "malformed environment cannot initialize a snapshot");
    result = runner.RunWithInputAndCaptureBounded({"--fixture", "environment-input"}, invalid, kInput, &output, 4096, 2000);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EINVAL && output.empty(),
        "failed environment construction never falls back to ambient values");
    result = runner.Run({"--fixture", "exit", "0"}, invalid);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EINVAL, "ordinary run refuses invalid snapshot");
    result = runner.RunWithInput({"--fixture", "input", kArgument}, invalid, kInput);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EINVAL, "ordinary input run refuses invalid snapshot");
    output = "stale"; result = runner.RunAndCapture({"--fixture", "environment"}, invalid, &output);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EINVAL && output.empty(), "ordinary capture refuses invalid snapshot");
    Expect(unlink(path.c_str()) == 0, "remove frozen-environment output fixture");

    result = runner.RunAndCaptureBounded({"--fixture", "close-output-wait"}, exact, &output, 4096, 100);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == ETIMEDOUT, "frozen capture retains deadline behavior");
    callbacks = 0;
    result = runner.RunWithInputAndCaptureBounded({"--fixture", "wait"}, exact, std::string(1024 * 1024, 'q'), &output, 4096, 2000,
        [&]() { return ++callbacks > 4; });
    Expect(result.kind == ResultKind::LaunchFailed && result.error == ECANCELED, "frozen duplex retains blocked-writer cancellation");
    Expect(before == ParentEnvironment() && EnvironmentReport() == ambient,
        "explicit launches do not mutate any parent environment entry");
}

} // namespace

int main(int argc, char *argv[]) {
    if (argc > 1 && strcmp(argv[1], "--fixture") == 0)
        return RunFixture(argc, argv);

    using CydiaRuntime::Dpkg::Result;
    using CydiaRuntime::Dpkg::ResultKind;
    using CydiaRuntime::Dpkg::Runner;

    const Runner runner(AbsoluteExecutable(argv[0]));

    Result result(runner.Run({"--fixture", "exit", "7"}));
    Expect(result.kind == ResultKind::Exited && result.code == 7 && result.error == 0,
           "report child exit status");

    result = runner.Run({"--fixture", "signal"});
    Expect(result.kind == ResultKind::Signaled && result.code == SIGTERM && result.error == 0,
           "report child signal");

    result = runner.RunWithInput({"--fixture", "input", kArgument}, kInput);
    Expect(result.succeeded(), "preserve argv and stdin without a shell");

#ifdef F_SETNOSIGPIPE
    result = runner.RunWithInput({"--fixture", "close-input"}, std::string(1024 * 1024, 'x'));
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EPIPE,
           "report a closed stdin pipe without SIGPIPE");
#endif

    const std::string outputPath(TemporaryOutputPath());
    result = runner.RunToFile({"--fixture", "output"}, outputPath);
    Expect(result.succeeded(), "redirect child stdout");
    Expect(ReadFile(outputPath) == kOutput, "preserve redirected stdout");
    Expect(unlink(outputPath.c_str()) == 0, "remove temporary output");

    std::string captured("stale");
    result = runner.RunAndCapture({"--fixture", "output"}, &captured);
    Expect(result.succeeded(), "capture child stdout");
    Expect(captured == kOutput, "preserve captured stdout");

    captured = "stale";
    result = runner.RunAndCapture({"--fixture", "output"}, &captured, 4);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EFBIG,
           "report bounded stdout overflow");
    Expect(captured == std::string(kOutput, 4), "retain bounded stdout prefix");

    result = runner.RunAndCapture({"--fixture", "output"}, NULL);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EINVAL,
           "reject a null capture destination");

    result = runner.RunAndCaptureBounded({"--fixture", "output"}, &captured, 1024, 2000);
    Expect(result.succeeded() && captured == kOutput, "bounded helper capture preserves successful output");
    result = runner.RunAndCaptureBounded({"--fixture", "wait"}, &captured, 1024, 300);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == ETIMEDOUT, "terminate a helper retaining stdout at its deadline");
    if (!captured.empty()) {
        const pid_t child(static_cast<pid_t>(strtol(captured.c_str(), NULL, 10)));
        Expect(child > 0 && kill(child, 0) != 0 && errno == ESRCH, "deadline reaps the launched helper before returning");
    }
    result = runner.RunAndCaptureBounded({"--fixture", "close-output-wait"}, &captured, 1024, 100);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == ETIMEDOUT, "closed stdout does not disable the process deadline");
    unsigned cancellationChecks(0);
    result = runner.RunAndCaptureBounded({"--fixture", "wait"}, &captured, 1024, 2000,
        [&]() { return ++cancellationChecks > 2; });
    Expect(result.kind == ResultKind::LaunchFailed && result.error == ECANCELED, "cancel an already launched disposable helper");
    result = runner.RunAndCaptureBounded({"--fixture", "output"}, &captured, 4, 2000);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EFBIG && captured.size() <= 4,
        "bounded helper output overflow terminates acquisition");

    result = runner.RunWithInputAndCaptureBounded({"--fixture", "input", kArgument}, kInput, &captured, 1024, 2000);
    Expect(result.succeeded() && captured.empty(), "bounded input reaches EOF while capturing output");
    result = runner.RunWithInputAndCaptureBounded({"--fixture", "duplex"}, std::string(1024 * 1024, 'q'), &captured, 512 * 1024, 2000);
    Expect(result.succeeded() && captured == std::string(256 * 1024, 'p') + "done",
        "bounded duplex drains output while helper waits to read input");
    result = runner.RunWithInputAndCaptureBounded({"--fixture", "close-input"}, std::string(1024 * 1024, 'q'), &captured, 1024, 2000);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EPIPE, "bounded writer survives a closed input pipe");
    cancellationChecks = 0;
    result = runner.RunWithInputAndCaptureBounded({"--fixture", "wait"}, std::string(1024 * 1024, 'q'), &captured, 1024, 2000,
        [&]() { return ++cancellationChecks > 4; });
    Expect(result.kind == ResultKind::LaunchFailed && result.error == ECANCELED,
        "cancellation interrupts a blocked bounded input writer");

    VerifyStatusDescriptor(runner, false);
    VerifyStatusDescriptor(runner, true);

    result = runner.Run({}, -2);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EINVAL,
           "reject invalid status descriptor");

    const Runner missing("/path/that/does/not/exist/cydia-dpkg");
    result = missing.Run({"--version"});
    Expect(result.kind == ResultKind::LaunchFailed && result.error == ENOENT,
           "report executable launch failure");

    VerifyFrozenEnvironment(runner);

    std::cout << "[verify-dpkg-runner][ ok ] shell-free dpkg process contract" << std::endl;
    return 0;
}
