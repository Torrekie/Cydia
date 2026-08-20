/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageDatabasePaths_HPP
#define Cydia_PackageDatabasePaths_HPP

#include <string>

namespace CydiaRuntime {

/*
 * The package database is owned by the selected bootstrap.  Rootless
 * jailbreaks keep it below /var/jb; rooted installs keep the historical
 * paths.  The selected layout also owns the package-manager helpers. Keep
 * this choice explicit instead of mechanically prefixing every path with
 * /var/jb.
 */
enum class PackageDatabaseLayout {
    Rootful,
    Rootless,
};

class PackageDatabasePaths {
  public:
    static PackageDatabasePaths ForLayout(PackageDatabaseLayout layout);
    static PackageDatabasePaths Detect();
    static const PackageDatabasePaths &Current();

    PackageDatabaseLayout layout() const;
    const std::string &AptArchitecture() const;
    const std::string &DpkgStatusPath() const;
    const std::string &DpkgInfoDirectory() const;
    const std::string &DpkgDataDirectory() const;
    const std::string &DpkgExecutableSearchPath() const;
    const std::string &AptExtendedStatesPath() const;
    const std::string &AptListsDirectory() const;
    const std::string &AptConfigDirectory() const;
    const std::string &CydiaStateDirectory() const;
    const std::string &PackageLibraryDirectory() const;
    const std::string &CydiaLibexecDirectory() const;
    const std::string &CydiaApplicationPath() const;
    std::string CydiaApplicationDirectory() const;
    const std::string &CydoPath() const;
    const std::string &DpkgBinaryPath() const;

    std::string AptSourcesListPath() const;
    std::string AptSourcesDirectory() const;
    std::string CydiaSourcesListPath() const;
    std::string CydiaMetadataPath() const;
    std::string CydiaFirmwareVersionPath() const;

    /* Returns an empty string for an invalid package name or suffix. */
    std::string DpkgInfoFile(const char *packageName, const char *suffix) const;

    /* Returns an empty string unless name is a single helper filename. */
    std::string CydiaHelperPath(const char *name) const;

    /* Returns a tool supplied by the selected bootstrap's /usr/bin. */
    std::string BootstrapBinaryPath(const char *name) const;

  private:
    PackageDatabasePaths(PackageDatabaseLayout layout,
                         const char *aptArchitecture,
                         const char *dpkgStatus,
                         const char *dpkgInfoDirectory,
                         const char *dpkgDataDirectory,
                         const char *dpkgExecutableSearchPath,
                         const char *aptExtendedStates,
                         const char *aptListsDirectory,
                         const char *aptConfigDirectory,
                         const char *cydiaStateDirectory,
                         const char *packageLibraryDirectory,
                         const char *cydiaLibexecDirectory,
                         const char *cydiaApplication,
                         const char *cydo,
                         const char *dpkgBinary);

    PackageDatabaseLayout layout_;
    std::string aptArchitecture_;
    std::string dpkgStatusPath_;
    std::string dpkgInfoDirectory_;
    std::string dpkgDataDirectory_;
    std::string dpkgExecutableSearchPath_;
    std::string aptExtendedStatesPath_;
    std::string aptListsDirectory_;
    std::string aptConfigDirectory_;
    std::string cydiaStateDirectory_;
    std::string packageLibraryDirectory_;
    std::string cydiaLibexecDirectory_;
    std::string cydiaApplicationPath_;
    std::string cydoPath_;
    std::string dpkgBinaryPath_;
};

} // namespace CydiaRuntime

#endif // Cydia_PackageDatabasePaths_HPP
