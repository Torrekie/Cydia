/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SharedConfigHandoff_HPP
#define Cydia_SharedConfigHandoff_HPP

#include "Cydia/DpkgRunner.h"
#include <cerrno>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaRuntime {

// iOS does not reliably spawn shebang scripts directly. Invoke the package's
// bootstrap Bash explicitly, keeping the private control file as an argv item.
inline Dpkg::Result RunSharedConfigHandoff(const char *scriptPath,
                                         const std::string &interpreter) {
    const auto failure = [](int error) {
        return Dpkg::Result{Dpkg::ResultKind::LaunchFailed, -1, error};
    };
    if (scriptPath == NULL || scriptPath[0] != '/' || interpreter.empty() || interpreter[0] != '/')
        return failure(EINVAL);
    const std::string script(scriptPath);
    const std::string::size_type slash(script.rfind('/'));
    if (slash == std::string::npos)
        return failure(EINVAL);
    const std::string directory(script.substr(0, slash + 1));
    struct stat metadata;
    if (stat(directory.c_str(), &metadata) != 0)
        return failure(errno);
    if (!S_ISDIR(metadata.st_mode) || metadata.st_uid != geteuid() || (metadata.st_mode & 0022) != 0)
        return failure(EACCES);
    if (stat(interpreter.c_str(), &metadata) != 0)
        return failure(errno);
    if (!S_ISREG(metadata.st_mode) || metadata.st_uid != 0 ||
            (metadata.st_mode & 0022) != 0 || (metadata.st_mode & 0111) == 0)
        return failure(EACCES);

    // Installed private control files acquire a package prefix; incoming
    // control files keep their archive filename.
    const char *names[] = {"cydia.cydia-shared-config-lifecycle", "cydia-shared-config-lifecycle"};
    for (const char *name : names) {
        const std::string helper(directory + name);
        if (lstat(helper.c_str(), &metadata) != 0) {
            if (errno == ENOENT) continue;
            return failure(errno);
        }
        if (!S_ISREG(metadata.st_mode) || metadata.st_uid != geteuid() || (metadata.st_mode & 0022) != 0)
            return failure(EACCES);
        Dpkg::Runner runner(interpreter);
        return runner.Run({helper, "--cydia-shared-config-lifecycle", "postinst", "configure"});
    }
    return failure(ENOENT);
}

} // namespace CydiaRuntime
#endif
