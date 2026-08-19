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

namespace CydiaRuntime {
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
    return RunInternal(arguments, statusFd, NULL, NULL);
}

Result Runner::RunWithInput(const std::vector<std::string> &arguments,
    const std::string &input,
    int statusFd) const {
    return RunInternal(arguments, statusFd, &input, NULL);
}

Result Runner::RunToFile(const std::vector<std::string> &arguments,
                         const std::string &outputPath,
                         int statusFd) const {
    return RunInternal(arguments, statusFd, NULL, &outputPath);
}

Result Runner::RunInternal(const std::vector<std::string> &arguments,
                           int statusFd,
                           const std::string *input,
                           const std::string *outputPath) const {
    if (executable_.empty() || statusFd < -1 ||
        (outputPath != NULL && outputPath->empty()) ||
        (input != NULL && statusFd == STDIN_FILENO) ||
        (outputPath != NULL && statusFd == STDOUT_FILENO))
        return launchFailure(EINVAL);

    if (statusFd >= 0 && fcntl(statusFd, F_GETFD) == -1)
        return launchFailure(errno);

    int inputPipe[2] = {-1, -1};
    if (input != NULL && pipe(inputPipe) == -1)
        return launchFailure(errno);
#ifdef F_SETNOSIGPIPE
    if (input != NULL && fcntl(inputPipe[1], F_SETNOSIGPIPE, 1) == -1) {
        const int error(errno);
        (void) close(inputPipe[0]);
        (void) close(inputPipe[1]);
        return launchFailure(error);
    }
#endif

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
    int inheritedStatusFd = -1;
    int actionError = posix_spawn_file_actions_init(&actions);
    if (actionError != 0) {
        if (input != NULL) {
            (void) close(inputPipe[0]);
            (void) close(inputPipe[1]);
        }
        return launchFailure(actionError);
    }

    if (statusFd >= 0) {
#ifdef __APPLE__
        actionError = posix_spawn_file_actions_addinherit_np(&actions, statusFd);
#else
        /* POSIX has no addinherit action. Duplicating through another child
         * descriptor makes dup2 clear FD_CLOEXEC on the requested number. */
        inheritedStatusFd = dup(statusFd);
        if (inheritedStatusFd == -1)
            actionError = errno;
        else {
            actionError = posix_spawn_file_actions_adddup2(&actions, inheritedStatusFd, statusFd);
            if (actionError == 0)
                actionError = posix_spawn_file_actions_addclose(&actions, inheritedStatusFd);
        }
#endif
        if (actionError != 0) {
            (void) posix_spawn_file_actions_destroy(&actions);
            if (inheritedStatusFd >= 0)
                (void) close(inheritedStatusFd);
            if (input != NULL) {
                (void) close(inputPipe[0]);
                (void) close(inputPipe[1]);
            }
            return launchFailure(actionError);
        }
    }

    if (input != NULL) {
        actionError = posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO);
        if (actionError == 0 && inputPipe[0] != STDIN_FILENO)
            actionError = posix_spawn_file_actions_addclose(&actions, inputPipe[0]);
        /* The child must not retain the parent's writer.  Otherwise a helper
         * that reads stdin to EOF waits forever because its own copy keeps
         * the pipe open after the parent finishes writing. */
        if (actionError == 0 && inputPipe[1] != STDIN_FILENO)
            actionError = posix_spawn_file_actions_addclose(&actions, inputPipe[1]);
        if (actionError != 0) {
            (void) posix_spawn_file_actions_destroy(&actions);
            if (inheritedStatusFd >= 0)
                (void) close(inheritedStatusFd);
            (void) close(inputPipe[0]);
            (void) close(inputPipe[1]);
            return launchFailure(actionError);
        }
    }

    if (outputPath != NULL) {
        actionError = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
                                                       outputPath->c_str(),
                                                       O_WRONLY | O_CREAT | O_TRUNC,
                                                       0644);
        if (actionError != 0) {
            (void) posix_spawn_file_actions_destroy(&actions);
            if (inheritedStatusFd >= 0)
                (void) close(inheritedStatusFd);
            if (input != NULL) {
                (void) close(inputPipe[0]);
                (void) close(inputPipe[1]);
            }
            return launchFailure(actionError);
        }
    }

    pid_t child;
    int spawnError = posix_spawn(&child, executable_.c_str(), &actions, NULL, argv.data(), environ);
    (void) posix_spawn_file_actions_destroy(&actions);
    if (inheritedStatusFd >= 0)
        (void) close(inheritedStatusFd);
    if (spawnError != 0) {
        if (input != NULL) {
            (void) close(inputPipe[0]);
            (void) close(inputPipe[1]);
        }
        return launchFailure(spawnError);
    }

    int inputError = 0;
    if (input != NULL) {
        (void) close(inputPipe[0]);
        size_t offset = 0;
        while (offset != input->size()) {
            ssize_t written = write(inputPipe[1], input->data() + offset, input->size() - offset);
            if (written > 0) {
                offset += static_cast<size_t>(written);
                continue;
            }
            if (written == -1 && errno == EINTR)
                continue;
            inputError = written == -1 ? errno : EIO;
            break;
        }
        (void) close(inputPipe[1]);
    }

    int status;
    pid_t waited;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited == -1 && errno == EINTR);

    if (waited == -1)
        return launchFailure(errno);

    if (inputError != 0)
        return launchFailure(inputError);
    return fromWaitStatus(status);
}

} // namespace Dpkg
} // namespace CydiaRuntime
