/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#include "Cydia/DpkgRunner.h"
#include "Cydia/PackageDatabasePaths.hpp"

#include <cerrno>

#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace Cydia {
namespace Dpkg {

namespace {

Result launchFailure(int error) {
    Result result = {ResultKind::LaunchFailed, -1, error};
    return result;
}

Result fromWaitStatus(int status) {
    if (WIFEXITED(status)) {
        Result result = {ResultKind::Exited, WEXITSTATUS(status), 0};
        return result;
    }

    if (WIFSIGNALED(status)) {
        Result result = {ResultKind::Signaled, WTERMSIG(status), 0};
        return result;
    }

    /* waitpid() should not normally return a stopped status here because we
     * do not request WUNTRACED.  Treat an unexpected status as a failed
     * launch rather than reporting success to package-operation callers.
     */
    return launchFailure(ECHILD);
}

bool hasStatusArgument(const std::vector<std::string> &arguments) {
    for (std::vector<std::string>::const_iterator it = arguments.begin(); it != arguments.end(); ++it) {
        if (*it == "--status-fd" || it->compare(0, sizeof("--status-fd=") - 1, "--status-fd=") == 0)
            return true;
    }
    return false;
}

} // namespace

bool Result::succeeded() const {
    return kind == ResultKind::Exited && code == 0;
}

std::string Runner::DefaultPath(Executable executable) {
    const PackageDatabasePaths &paths(PackageDatabasePaths::Current());
    switch (executable) {
        case Executable::Cydo:
            return paths.CydoPath();
        case Executable::DeviceDpkg:
            return paths.DpkgBinaryPath();
    }

    return std::string();
}

Runner::Runner(Executable executable) : executable_(DefaultPath(executable)) {
}

Runner::Runner(const std::string &executable) : executable_(executable) {
}

const std::string &Runner::executable() const {
    return executable_;
}

Result Runner::Run(const std::vector<std::string> &arguments, int statusFd) const {
    if (executable_.empty() || statusFd < -1)
        return launchFailure(EINVAL);

    if (statusFd >= 0 && fcntl(statusFd, F_GETFD) == -1)
        return launchFailure(errno);

    std::vector<std::string> storage;
    storage.reserve(arguments.size() + 3);
    storage.push_back(executable_);
    storage.insert(storage.end(), arguments.begin(), arguments.end());

    if (statusFd >= 0 && !hasStatusArgument(arguments)) {
        storage.push_back("--status-fd");
        storage.push_back(std::to_string(statusFd));
    }

    std::vector<char *> argv;
    argv.reserve(storage.size() + 1);
    for (std::vector<std::string>::iterator it = storage.begin(); it != storage.end(); ++it)
        argv.push_back(const_cast<char *>(it->c_str()));
    argv.push_back(NULL);

    /* posix_spawn avoids forking a multithreaded UIKit process.  The Darwin
     * inherit action also clears close-on-exec on a caller-supplied status
     * descriptor, making the status-fd contract independent of how the pipe
     * was created (unlike dup2(fd, fd), which is a no-op on some systems).
     */
    posix_spawn_file_actions_t actions;
    int actionError = posix_spawn_file_actions_init(&actions);
    if (actionError != 0)
        return launchFailure(actionError);

    if (statusFd >= 0) {
        actionError = posix_spawn_file_actions_addinherit_np(&actions, statusFd);
        if (actionError != 0) {
            (void) posix_spawn_file_actions_destroy(&actions);
            return launchFailure(actionError);
        }
    }

    pid_t child;
    int spawnError = posix_spawn(&child, executable_.c_str(), &actions, NULL, argv.data(), environ);
    (void) posix_spawn_file_actions_destroy(&actions);
    if (spawnError != 0)
        return launchFailure(spawnError);

    int status;
    pid_t waited;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited == -1 && errno == EINTR);

    if (waited == -1)
        return launchFailure(errno);

    return fromWaitStatus(status);
}

} // namespace Dpkg
} // namespace Cydia
