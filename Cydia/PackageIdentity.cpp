/* Cydia Refurbished package identity policy.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptCompatibility.hpp"

namespace CydiaAPT {

PackageIdentity::PackageIdentity() :
    multiArch(MultiArchMode::None),
    architectureIndependent(false)
{
}

bool PackageIdentity::valid() const {
    return !baseName.empty() && !packageArchitecture.empty() &&
        !versionArchitecture.empty() && !aptName.empty() &&
        !routingName.empty() && !dpkgName.empty();
}

PackageIdentity BuildPackageIdentity(const std::string &baseName,
                                     const std::string &packageArchitecture,
                                     const std::string &versionArchitecture,
                                     const std::string &nativeArchitecture,
                                     MultiArchMode multiArch) {
    PackageIdentity identity;
    if (baseName.empty() || packageArchitecture.empty() ||
        versionArchitecture.empty() || nativeArchitecture.empty())
        return identity;

    identity.baseName = baseName;
    identity.packageArchitecture = packageArchitecture;
    identity.versionArchitecture = versionArchitecture;
    identity.multiArch = multiArch;
    identity.architectureIndependent = versionArchitecture == "all";

    identity.aptName = baseName + ":" + packageArchitecture;
    if (packageArchitecture == nativeArchitecture ||
        packageArchitecture == "all")
        identity.routingName = baseName;
    else
        identity.routingName = identity.aptName;

    const bool foreignPackage = packageArchitecture != nativeArchitecture &&
        packageArchitecture != "all" && packageArchitecture != "any";
    if (!identity.architectureIndependent &&
        (multiArch == MultiArchMode::Same || foreignPackage))
        identity.dpkgName = baseName + ":" + versionArchitecture;
    else
        identity.dpkgName = baseName;

    return identity;
}

} // namespace CydiaAPT
