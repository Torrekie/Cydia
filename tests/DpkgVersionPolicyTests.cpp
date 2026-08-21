/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptVersionPolicyInternal.hpp"

#include <apt-pkg/debversion.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <spawn.h>
#include <string>
#include <sys/wait.h>
#include <vector>

extern char **environ;

namespace {

struct VersionCase {
    const char *candidate;
    const char *installed;
    bool upgrade;
};

void Fail(const std::string &message) {
    std::cerr << "[verify-dpkg-version][FAIL] " << message << std::endl;
    std::exit(1);
}

bool DpkgCompare(const char *left, const char *operation, const char *right) {
    pid_t child(0);
    char *arguments[] = {
        const_cast<char *>("dpkg"),
        const_cast<char *>("--compare-versions"),
        const_cast<char *>(left),
        const_cast<char *>(operation),
        const_cast<char *>(right),
        NULL,
    };
    const int error(posix_spawnp(&child, "dpkg", NULL, NULL, arguments, environ));
    if (error != 0)
        Fail(std::string("execute dpkg: ") + std::strerror(error));

    int status(0);
    while (waitpid(child, &status, 0) == -1) {
        if (errno != EINTR)
            Fail(std::string("wait for dpkg: ") + std::strerror(errno));
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) > 1)
        Fail("dpkg --compare-versions failed");
    return WEXITSTATUS(status) == 0;
}

} // namespace

int main() {
    const VersionCase cases[] = {
        {"2.0", "1.0", true},
        {"1.0", "2.0", false},
        {"1.0", "1.0", false},
        {"2.0", "1:1.0", false},
        {"1:1.0", "2.0", true},
        {"1.0-2", "1.0-1", true},
        {"1.0-1", "1.0-2", false},
        {"1.0~rc1", "1.0", false},
        {"1.0", "1.0~rc1", true},
        {"1.0", "1.0+local1", false},
        {"0:1.0", "1.0", false},
        {"1.0", "1.0-0", false},
    };

    for (std::size_t index(0); index != sizeof(cases) / sizeof(cases[0]); ++index) {
        const VersionCase &test(cases[index]);
        const bool actual(CydiaAPT::IsDpkgVersionUpgrade(
            debVS, test.candidate, test.installed));
        if (actual != test.upgrade)
            Fail(std::string(test.candidate) + " versus " + test.installed +
                 " had the wrong upgrade classification");

        const bool dpkg(DpkgCompare(test.candidate, "gt", test.installed));
        if (actual != dpkg)
            Fail(std::string(test.candidate) + " versus " + test.installed +
                 " disagreed with dpkg --compare-versions");
    }

    if (!DpkgCompare("0:1.0", "eq", "1.0") ||
        !DpkgCompare("1.0", "eq", "1.0-0"))
        Fail("dpkg equality fixtures changed");

    std::cout << "[verify-dpkg-version][ ok ] embedded ordering matches dpkg across "
              << sizeof(cases) / sizeof(cases[0]) << " upgrade cases" << std::endl;
    return 0;
}
