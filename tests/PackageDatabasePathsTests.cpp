/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageDatabasePaths.hpp"

#include <cstdlib>
#include <cstdio>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

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
    Expect(rootful.LegacyCydiaSourcesListPath() == "/etc/apt/sources.list.d/cydia.list", "rootful legacy Cydia source path");
    Expect(rootful.CydiaSourcesListPath() == rootful.LegacyCydiaSourcesListPath(), "rootful legacy path compatibility");
    Expect(rootful.CydiaMetadataPath() == "/var/lib/cydia/metadata.plist", "rootful Cydia metadata path");
    Expect(rootful.CydiaLegacySourceMarkerPath() == "/var/lib/cydia/cydia.legacy-source-marker",
           "rootful legacy source marker path");
    Expect(rootful.CydiaHelperPath("firmware.sh") == "/usr/libexec/cydia/firmware.sh", "rootful helper path");
    Expect(rootful.BootstrapBinaryPath("du") == "/usr/bin/du", "rootful bootstrap binary path");
    Expect(rootful.BootstrapBSDCommandPath(BootstrapBSDCommand::Copy) == "/bin/cp",
           "rootful BSD copy path");
    Expect(rootful.BootstrapBSDCommandPath(BootstrapBSDCommand::Move) == "/bin/mv",
           "rootful BSD move path");
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
    Expect(rootless.LegacyCydiaSourcesListPath() == "/var/jb/etc/apt/sources.list.d/cydia.list", "rootless legacy Cydia source path");
    Expect(rootless.CydiaSourcesListPath() == rootless.LegacyCydiaSourcesListPath(), "rootless legacy path compatibility");
    Expect(rootless.CydiaMetadataPath() == "/var/jb/var/lib/cydia/metadata.plist", "rootless Cydia metadata path");
    Expect(rootless.CydiaLegacySourceMarkerPath() == "/var/jb/var/lib/cydia/cydia.legacy-source-marker",
           "rootless legacy source marker path");
    Expect(rootless.CydiaHelperPath("firmware.sh") == "/var/jb/usr/libexec/cydia/firmware.sh", "rootless helper path");
    Expect(rootless.BootstrapBinaryPath("du") == "/var/jb/usr/bin/du", "rootless bootstrap binary path");
    Expect(rootless.BootstrapBSDCommandPath(BootstrapBSDCommand::Copy) == "/var/jb/bin/cp",
           "rootless BSD copy path");
    Expect(rootless.BootstrapBSDCommandPath(BootstrapBSDCommand::Move) == "/var/jb/bin/mv",
           "rootless BSD move path");
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
    Expect(rootless.DpkgInfoFile("bash-builtins:iphoneos-arm64", ".list") ==
               "/var/jb/var/lib/dpkg/info/bash-builtins:iphoneos-arm64.list",
           "rootless Multi-Arch: same package info path");

    Expect(rootless.DpkgInfoFile("../apt", ".list").empty(), "reject package traversal");
    Expect(rootless.DpkgInfoFile("apt", "/list").empty(), "reject invalid package-info suffix");
    Expect(rootless.CydiaHelperPath("../firmware.sh").empty(), "reject helper traversal");
    Expect(rootless.CydiaHelperPath("").empty(), "reject empty helper name");
    Expect(rootless.BootstrapBinaryPath("../du").empty(), "reject bootstrap binary traversal");
    Expect(rootless.BootstrapBSDCommandPath(static_cast<BootstrapBSDCommand>(-1)).empty(),
           "reject unknown BSD command");

    // Both installed variants can remain present after a bootstrap change.
    // An app/helper's canonical installed identity wins over launcher hints.
    char pattern[] = "/tmp/cydia-layout-XXXXXX";
    char *created(mkdtemp(pattern)); Expect(created != NULL, "create isolated layout fixture");
    const std::string fixture(created);
    const std::string rooted(fixture + "/rooted-Cydia"), rootlessApp(fixture + "/rootless-Cydia");
    const std::string rootedHelper(fixture + "/rooted-cydo"), rootlessHelper(fixture + "/rootless-cydo");
    const std::string unrelated(fixture + "/unrelated-Cydia");
    for (const auto &file : {rooted, rootlessApp, rootedHelper, rootlessHelper, unrelated}) {
        FILE *output(fopen(file.c_str(), "wb")); Expect(output != NULL, "create fixture executable");
        Expect(fclose(output) == 0, "close fixture executable");
    }
    const std::vector<CydiaRuntime::InstalledExecutableCandidate> candidates = {
        {PackageDatabaseLayout::Rootless, rootlessApp}, {PackageDatabaseLayout::Rootless, rootlessHelper},
        {PackageDatabaseLayout::Rootful, rooted}, {PackageDatabaseLayout::Rootful, rootedHelper}};
    PackageDatabaseLayout selected(PackageDatabaseLayout::Rootless);
    setenv("CYDIA_PACKAGE_LAYOUT", "rootless", 1);
    Expect(CydiaRuntime::ResolveInstalledExecutableLayout(rooted, candidates, &selected) && selected == PackageDatabaseLayout::Rootful,
           "installed rooted app overrides rootless launcher hint");
    Expect(CydiaRuntime::ResolveInstalledExecutableLayout(rootedHelper, candidates, &selected) && selected == PackageDatabaseLayout::Rootful,
           "installed rooted helper identity");
    setenv("CYDIA_PACKAGE_LAYOUT", "rootful", 1);
    Expect(CydiaRuntime::ResolveInstalledExecutableLayout(rootlessApp, candidates, &selected) && selected == PackageDatabaseLayout::Rootless,
           "installed rootless app overrides rooted launcher hint");
    Expect(CydiaRuntime::ResolveInstalledExecutableLayout(rootlessHelper, candidates, &selected) && selected == PackageDatabaseLayout::Rootless,
           "installed rootless helper identity");
    const std::string alias(fixture + "/application-alias");
    Expect(symlink(rootlessApp.c_str(), alias.c_str()) == 0, "create canonical package alias");
    Expect(CydiaRuntime::ResolveInstalledExecutableLayout(alias, candidates, &selected) && selected == PackageDatabaseLayout::Rootless,
           "package aliases select canonical installed identity");
    Expect(!CydiaRuntime::ResolveInstalledExecutableLayout(unrelated, candidates, &selected), "identical app suffix is not installed identity");
    Expect(!CydiaRuntime::ResolveInstalledExecutableLayout(fixture + "/missing-Cydia", candidates, &selected), "missing candidates never identify a package");
    Expect(!CydiaRuntime::ResolveInstalledExecutableLayout(rooted + std::string("\0suffix", 7), candidates, &selected), "reject embedded NUL identity");
    // The test executable is outside installed paths; its legacy CLI override
    // remains supported without influencing an identifiable installed app.
    Expect(PackageDatabasePaths::Detect().layout() == PackageDatabaseLayout::Rootful, "host CLI rooted override remains supported");
    setenv("CYDIA_PACKAGE_LAYOUT", "rootless", 1);
    Expect(PackageDatabasePaths::Detect().layout() == PackageDatabaseLayout::Rootless, "host CLI rootless override remains supported");
    unsetenv("CYDIA_PACKAGE_LAYOUT");
    unlink(alias.c_str());
    for (const auto &file : {rooted, rootlessApp, rootedHelper, rootlessHelper, unrelated}) unlink(file.c_str());
    Expect(rmdir(fixture.c_str()) == 0, "remove isolated layout fixture");

    std::cout << "[verify-paths][ ok ] rootful and rootless package paths are explicit" << std::endl;
    return 0;
}
