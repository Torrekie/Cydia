/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
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
    const std::string &DpkgStatusPath() const;
    const std::string &DpkgInfoDirectory() const;
    const std::string &AptExtendedStatesPath() const;
    const std::string &CydoPath() const;
    const std::string &DpkgBinaryPath() const;

    /* Returns an empty string for an invalid package name or suffix. */
    std::string DpkgInfoFile(const char *packageName, const char *suffix) const;

  private:
    PackageDatabasePaths(PackageDatabaseLayout layout,
                         const char *dpkgStatus,
                         const char *dpkgInfoDirectory,
                         const char *aptExtendedStates,
                         const char *cydo,
                         const char *dpkgBinary);

    PackageDatabaseLayout layout_;
    std::string dpkgStatusPath_;
    std::string dpkgInfoDirectory_;
    std::string aptExtendedStatesPath_;
    std::string cydoPath_;
    std::string dpkgBinaryPath_;
};

} // namespace CydiaRuntime

#endif // Cydia_PackageDatabasePaths_HPP
