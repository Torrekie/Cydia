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

    const PackageDatabasePaths rootful(PackageDatabasePaths::ForLayout(PackageDatabaseLayout::Rootful));
    Expect(rootful.DpkgStatusPath() == "/var/lib/dpkg/status", "rootful dpkg status path");
    Expect(rootful.AptConfigDirectory() == "/etc/apt", "rootful APT configuration path");
    Expect(rootful.CydiaSourcesListPath() == "/etc/apt/sources.list.d/cydia.list", "rootful Cydia source link");
    Expect(rootful.CydiaMetadataPath() == "/var/lib/cydia/metadata.plist", "rootful Cydia metadata path");
    Expect(rootful.CydiaHelperPath("firmware.sh") == "/usr/libexec/cydia/firmware.sh", "rootful helper path");
    Expect(rootful.CydiaApplicationPath() == "/Applications/Cydia.app/Cydia", "rootful application path");

    const PackageDatabasePaths rootless(PackageDatabasePaths::ForLayout(PackageDatabaseLayout::Rootless));
    Expect(rootless.DpkgStatusPath() == "/var/jb/var/lib/dpkg/status", "rootless dpkg status path");
    Expect(rootless.AptConfigDirectory() == "/var/jb/etc/apt", "rootless APT configuration path");
    Expect(rootless.CydiaSourcesListPath() == "/var/jb/etc/apt/sources.list.d/cydia.list", "rootless Cydia source link");
    Expect(rootless.CydiaMetadataPath() == "/var/jb/var/lib/cydia/metadata.plist", "rootless Cydia metadata path");
    Expect(rootless.CydiaHelperPath("firmware.sh") == "/var/jb/usr/libexec/cydia/firmware.sh", "rootless helper path");
    Expect(rootless.CydiaApplicationPath() == "/var/jb/Applications/Cydia.app/Cydia", "rootless application path");
    Expect(rootless.DpkgInfoFile("apt", ".list") == "/var/jb/var/lib/dpkg/info/apt.list", "rootless package info path");

    Expect(rootless.DpkgInfoFile("../apt", ".list").empty(), "reject package traversal");
    Expect(rootless.DpkgInfoFile("apt", "/list").empty(), "reject invalid package-info suffix");
    Expect(rootless.CydiaHelperPath("../firmware.sh").empty(), "reject helper traversal");
    Expect(rootless.CydiaHelperPath("").empty(), "reject empty helper name");

    std::cout << "[verify-paths][ ok ] rootful and rootless package paths are explicit" << std::endl;
    return 0;
}
