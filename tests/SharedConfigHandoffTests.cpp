/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SharedConfigHandoff.hpp"
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

static void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[shared-config-handoff] FAIL: " << message << '\n';
    std::exit(1);
}

int main() {
    char pattern[] = "/tmp/cydia-handoff-bridge.XXXXXX";
    const char *temporary(mkdtemp(pattern));
    Require(temporary != NULL, "create disposable control directory");
    const std::string directory(std::string(temporary) + "/control with spaces");
    Require(mkdir(directory.c_str(), 0700) == 0, "create control directory with spaces");
    const std::string postinst(directory + "/cydia.postinst");
    const std::string installed(directory + "/cydia.cydia-shared-config-lifecycle");
    const std::string incoming(directory + "/cydia-shared-config-lifecycle");
    {
        // No shebang or executable bit: this must be read by the interpreter,
        // rather than depend on the host kernel's script-execution behavior.
        std::ofstream file(installed.c_str());
        file << "test \"$#\" = 3 || exit 21\n"
                "test \"$1\" = --cydia-shared-config-lifecycle || exit 22\n"
                "test \"$2\" = postinst || exit 23\n"
                "test \"$3\" = configure || exit 24\n"
                "exit 0\n";
    }
    Require(chmod(installed.c_str(), 0644) == 0, "set trusted readable helper mode");
    auto result(CydiaRuntime::RunSharedConfigHandoff(postinst.c_str(), "/bin/bash"));
    Require(result.succeeded(), "explicit interpreter preserves helper path and arguments");
    Require(chmod(installed.c_str(), 0666) == 0, "make unsafe helper");
    result = CydiaRuntime::RunSharedConfigHandoff(postinst.c_str(), "/bin/bash");
    Require(result.kind == CydiaRuntime::Dpkg::ResultKind::LaunchFailed && result.error == EACCES,
            "reject writable private control file");
    Require(chmod(installed.c_str(), 0644) == 0, "restore helper mode");
    Require(rename(installed.c_str(), incoming.c_str()) == 0, "use incoming control filename");
    Require(CydiaRuntime::RunSharedConfigHandoff(postinst.c_str(), "/bin/bash").succeeded(),
            "incoming control helper is supported");
    {
        std::ofstream file(incoming.c_str());
        file << "exit 37\n";
    }
    result = CydiaRuntime::RunSharedConfigHandoff(postinst.c_str(), "/bin/bash");
    Require(result.kind == CydiaRuntime::Dpkg::ResultKind::Exited && result.code == 37,
            "preserve lifecycle failure status for postinst diagnostics");
    result = CydiaRuntime::RunSharedConfigHandoff("postinst", "/bin/bash");
    Require(result.kind == CydiaRuntime::Dpkg::ResultKind::LaunchFailed && result.error == EINVAL,
            "reject ambiguous control-file location");
    Require(unlink(incoming.c_str()) == 0, "remove fixture helper");
    result = CydiaRuntime::RunSharedConfigHandoff(postinst.c_str(), "/bin/bash");
    Require(result.kind == CydiaRuntime::Dpkg::ResultKind::LaunchFailed && result.error == ENOENT,
            "missing control helper has a diagnostic error");
    Require(rmdir(directory.c_str()) == 0 && rmdir(temporary) == 0, "remove disposable directory");
    std::cout << "[shared-config-handoff] PASS\n";
}
