/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/DpkgRunner.h"

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

namespace {

const char kArgument[] = "argument with spaces;$(not-a-shell)";
const char kInput[] = "selection one install\nselection two deinstall\n";
const char kOutput[] = "dpkg runner output\n";

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

void VerifyStatusDescriptor(const CydiaRuntime::Dpkg::Runner &runner, bool explicitArgument) {
    int descriptors[2];
    Expect(pipe(descriptors) == 0, "create status pipe");
    Expect(fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0, "mark status descriptor close-on-exec");

    std::vector<std::string> arguments;
    arguments.push_back("--fixture");
    arguments.push_back("status");
    if (explicitArgument)
        arguments.push_back("--status-fd=" + std::to_string(descriptors[1]));

    const CydiaRuntime::Dpkg::Result result(runner.Run(arguments, descriptors[1]));
    Expect(close(descriptors[1]) == 0, "close status writer");
    const std::string payload(ReadDescriptor(descriptors[0]));
    Expect(close(descriptors[0]) == 0, "close status reader");
    Expect(result.succeeded(), explicitArgument ? "preserve explicit status-fd" : "append status-fd");
    Expect(payload == "status: ok\n", "inherit close-on-exec status descriptor");
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

    VerifyStatusDescriptor(runner, false);
    VerifyStatusDescriptor(runner, true);

    result = runner.Run({}, -2);
    Expect(result.kind == ResultKind::LaunchFailed && result.error == EINVAL,
           "reject invalid status descriptor");

    const Runner missing("/path/that/does/not/exist/cydia-dpkg");
    result = missing.Run({"--version"});
    Expect(result.kind == ResultKind::LaunchFailed && result.error == ENOENT,
           "report executable launch failure");

    std::cout << "[verify-dpkg-runner][ ok ] shell-free dpkg process contract" << std::endl;
    return 0;
}
