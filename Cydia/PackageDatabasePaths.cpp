/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/PackageDatabasePaths.hpp"

#include <cstdlib>
#include <cstring>
#include <strings.h>
#include <unistd.h>

namespace {

struct PackageDatabaseLayoutValues {
    const char *dpkgStatus;
    const char *dpkgInfoDirectory;
    const char *aptExtendedStates;
    const char *cydo;
    const char *dpkgBinary;
};

const PackageDatabaseLayoutValues kRootfulLayout = {
    "/var/lib/dpkg/status",
    "/var/lib/dpkg/info",
    "/var/lib/apt/extended_states",
    "/usr/libexec/cydia/cydo",
    "/usr/bin/dpkg",
};

const PackageDatabaseLayoutValues kRootlessLayout = {
    "/var/jb/var/lib/dpkg/status",
    "/var/jb/var/lib/dpkg/info",
    "/var/jb/var/lib/apt/extended_states",
    "/var/jb/usr/libexec/cydia/cydo",
    "/var/jb/usr/bin/dpkg",
};

const PackageDatabaseLayoutValues &ValuesForLayout(CydiaRuntime::PackageDatabaseLayout layout) {
    return layout == CydiaRuntime::PackageDatabaseLayout::Rootless ? kRootlessLayout : kRootfulLayout;
}

bool Exists(const char *path) {
    return path != NULL && access(path, F_OK) == 0;
}

bool HasPackageDatabase(const PackageDatabaseLayoutValues &values) {
    return Exists(values.dpkgStatus) || Exists(values.dpkgInfoDirectory) || Exists(values.aptExtendedStates);
}

bool IsLayoutValue(const char *value, const char *expected) {
    return value != NULL && strcasecmp(value, expected) == 0;
}

} // namespace

namespace CydiaRuntime {

PackageDatabasePaths::PackageDatabasePaths(PackageDatabaseLayout layout,
                                           const char *dpkgStatus,
                                           const char *dpkgInfoDirectory,
                                           const char *aptExtendedStates,
                                           const char *cydo,
                                           const char *dpkgBinary) :
    layout_(layout),
    dpkgStatusPath_(dpkgStatus),
    dpkgInfoDirectory_(dpkgInfoDirectory),
    aptExtendedStatesPath_(aptExtendedStates),
    cydoPath_(cydo),
    dpkgBinaryPath_(dpkgBinary)
{
}

PackageDatabasePaths PackageDatabasePaths::ForLayout(PackageDatabaseLayout layout) {
    const PackageDatabaseLayoutValues &values(ValuesForLayout(layout));
    return PackageDatabasePaths(layout, values.dpkgStatus, values.dpkgInfoDirectory, values.aptExtendedStates,
                                values.cydo, values.dpkgBinary);
}

PackageDatabasePaths PackageDatabasePaths::Detect() {
    /* An explicit layout is useful for launchers and makes tests deterministic. */
    const char *forced(getenv("CYDIA_PACKAGE_LAYOUT"));
    if (IsLayoutValue(forced, "rootless"))
        return ForLayout(PackageDatabaseLayout::Rootless);
    if (IsLayoutValue(forced, "rootful"))
        return ForLayout(PackageDatabaseLayout::Rootful);

    /* Prefer a complete rootless bootstrap when its database and cydo shim
     * are present.  A rootless device may also retain a system/rootful dpkg
     * database, so database presence alone must not force the historical
     * layout in that case. */
    if (HasPackageDatabase(kRootlessLayout) && Exists(kRootlessLayout.cydo))
        return ForLayout(PackageDatabaseLayout::Rootless);
    return ForLayout(PackageDatabaseLayout::Rootful);
}

const PackageDatabasePaths &PackageDatabasePaths::Current() {
    static const PackageDatabasePaths paths(Detect());
    return paths;
}

PackageDatabaseLayout PackageDatabasePaths::layout() const {
    return layout_;
}

const std::string &PackageDatabasePaths::DpkgStatusPath() const {
    return dpkgStatusPath_;
}

const std::string &PackageDatabasePaths::DpkgInfoDirectory() const {
    return dpkgInfoDirectory_;
}

const std::string &PackageDatabasePaths::AptExtendedStatesPath() const {
    return aptExtendedStatesPath_;
}

const std::string &PackageDatabasePaths::CydoPath() const {
    return cydoPath_;
}

const std::string &PackageDatabasePaths::DpkgBinaryPath() const {
    return dpkgBinaryPath_;
}

std::string PackageDatabasePaths::DpkgInfoFile(const char *packageName, const char *suffix) const {
    if (packageName == NULL || suffix == NULL || packageName[0] == '\0' || suffix[0] != '.' ||
        strchr(packageName, '/') != NULL || strchr(suffix, '/') != NULL)
        return std::string();

    std::string path(dpkgInfoDirectory_);
    path += '/';
    path += packageName;
    path += suffix;
    return path;
}

} // namespace CydiaRuntime
