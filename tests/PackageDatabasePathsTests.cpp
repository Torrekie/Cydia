/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageDatabasePaths.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

void Expect(bool condition, const char *message) {
    if (condition)
        return;
    std::cerr << "[verify-paths][FAIL] " << message << std::endl;
    std::exit(1);
}

} // namespace

int main() {
    using CydiaRuntime::PackageDatabaseLayout;
    using CydiaRuntime::PackageDatabasePaths;
    using CydiaRuntime::BootstrapBSDCommand;

    const PackageDatabasePaths rootful(PackageDatabasePaths::ForLayout(PackageDatabaseLayout::Rootful));
    Expect(rootful.AptArchitecture() == "iphoneos-arm", "rootful APT architecture");
    Expect(rootful.DpkgStatusPath() == "/var/lib/dpkg/status", "rootful dpkg status path");
    Expect(rootful.DpkgDataDirectory() == "/usr/share/dpkg", "rootful dpkg data path");
    Expect(rootful.DpkgExecutableSearchPath() == "/bin:/usr/bin:/sbin:/usr/sbin",
           "rootful dpkg executable search path");
    Expect(rootful.AptListsDirectory() == "/var/lib/apt/lists", "rootful APT lists path");
    Expect(rootful.AptConfigDirectory() == "/etc/apt", "rootful APT configuration path");
    Expect(rootful.CydiaSourcesListPath() == "/etc/apt/sources.list.d/cydia.list", "rootful Cydia source link");
    Expect(rootful.CydiaMetadataPath() == "/var/lib/cydia/metadata.plist", "rootful Cydia metadata path");
    Expect(rootful.CydiaHelperPath("firmware.sh") == "/usr/libexec/cydia/firmware.sh", "rootful helper path");
    Expect(rootful.BootstrapBinaryPath("du") == "/usr/bin/du", "rootful bootstrap binary path");
    Expect(rootful.BootstrapBSDCommandPath(BootstrapBSDCommand::Copy) == "/bin/cp",
           "rootful BSD copy path");
    Expect(rootful.BootstrapBSDCommandPath(BootstrapBSDCommand::Link) == "/bin/ln",
           "rootful BSD link path");
    Expect(rootful.BootstrapBSDCommandPath(BootstrapBSDCommand::Remove) == "/bin/rm",
           "rootful BSD remove path");
    Expect(rootful.CydoPath() == "/usr/libexec/cydia/cydo", "rootful cydo path");
    Expect(rootful.DpkgBinaryPath() == "/usr/bin/dpkg", "rootful dpkg binary path");
    Expect(rootful.CydiaApplicationPath() == "/Applications/Cydia.app/Cydia", "rootful application path");
    Expect(rootful.CydiaApplicationDirectory() == "/Applications/Cydia.app", "rootful application directory");
    Expect(rootful.RequiresLegacyUserMigration(false), "rootful missing /User requires migration");
    Expect(!rootful.RequiresLegacyUserMigration(true), "rootful existing /User skips migration");

    const PackageDatabasePaths rootless(PackageDatabasePaths::ForLayout(PackageDatabaseLayout::Rootless));
    Expect(rootless.AptArchitecture() == "iphoneos-arm64", "rootless APT architecture");
    Expect(rootless.DpkgStatusPath() == "/var/jb/var/lib/dpkg/status", "rootless dpkg status path");
    Expect(rootless.DpkgDataDirectory() == "/var/jb/usr/share/dpkg", "rootless dpkg data path");
    Expect(rootless.DpkgExecutableSearchPath() ==
               "/var/jb/bin:/var/jb/usr/bin:/var/jb/sbin:/var/jb/usr/sbin:/bin:/usr/bin:/sbin:/usr/sbin",
           "rootless dpkg executable search path");
    Expect(rootless.AptListsDirectory() == "/var/jb/var/lib/apt/lists", "rootless APT lists path");
    Expect(rootless.AptConfigDirectory() == "/var/jb/etc/apt", "rootless APT configuration path");
    Expect(rootless.CydiaSourcesListPath() == "/var/jb/etc/apt/sources.list.d/cydia.list", "rootless Cydia source link");
    Expect(rootless.CydiaMetadataPath() == "/var/jb/var/lib/cydia/metadata.plist", "rootless Cydia metadata path");
    Expect(rootless.CydiaHelperPath("firmware.sh") == "/var/jb/usr/libexec/cydia/firmware.sh", "rootless helper path");
    Expect(rootless.BootstrapBinaryPath("du") == "/var/jb/usr/bin/du", "rootless bootstrap binary path");
    Expect(rootless.BootstrapBSDCommandPath(BootstrapBSDCommand::Copy) == "/var/jb/bin/cp",
           "rootless BSD copy path");
    Expect(rootless.BootstrapBSDCommandPath(BootstrapBSDCommand::Link) == "/var/jb/bin/ln",
           "rootless BSD link path");
    Expect(rootless.BootstrapBSDCommandPath(BootstrapBSDCommand::Remove) == "/var/jb/bin/rm",
           "rootless BSD remove path");
    Expect(rootless.CydoPath() == "/var/jb/usr/libexec/cydia/cydo", "rootless cydo path");
    Expect(rootless.DpkgBinaryPath() == "/var/jb/usr/bin/dpkg", "rootless dpkg binary path");
    Expect(rootless.CydiaApplicationPath() == "/var/jb/Applications/Cydia.app/Cydia", "rootless application path");
    Expect(rootless.CydiaApplicationDirectory() == "/var/jb/Applications/Cydia.app", "rootless application directory");
    Expect(!rootless.RequiresLegacyUserMigration(false), "rootless install must not own /User migration");
    Expect(!rootless.RequiresLegacyUserMigration(true), "rootless existing /User does not require migration");
    Expect(rootless.DpkgInfoFile("apt", ".list") == "/var/jb/var/lib/dpkg/info/apt.list", "rootless package info path");

    Expect(rootless.DpkgInfoFile("../apt", ".list").empty(), "reject package traversal");
    Expect(rootless.DpkgInfoFile("apt", "/list").empty(), "reject invalid package-info suffix");
    Expect(rootless.CydiaHelperPath("../firmware.sh").empty(), "reject helper traversal");
    Expect(rootless.CydiaHelperPath("").empty(), "reject empty helper name");
    Expect(rootless.BootstrapBinaryPath("../du").empty(), "reject bootstrap binary traversal");
    Expect(rootless.BootstrapBSDCommandPath(static_cast<BootstrapBSDCommand>(-1)).empty(),
           "reject unknown BSD command");

    std::cout << "[verify-paths][ ok ] rootful and rootless package paths are explicit" << std::endl;
    return 0;
}
