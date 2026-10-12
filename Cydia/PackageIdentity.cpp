/* Cydia Refurbished package identity policy.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptCompatibility.hpp"

#include <algorithm>

namespace CydiaAPT {

PackageSelector ParsePackageSelector(const std::string &name) {
    PackageSelector selector;
    const std::string::size_type colon(name.find(':'));
    const std::string base(name.substr(0, colon));
    if (base.empty() || base.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789+.-") != std::string::npos ||
        base.find_first_of("abcdefghijklmnopqrstuvwxyz0123456789") != 0)
        return selector;
    if (colon != std::string::npos) {
        const std::string architecture(name.substr(colon + 1));
        if (architecture.empty() || architecture.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-") != std::string::npos ||
            architecture.front() == '-')
            return selector;
        selector.architecture = architecture;
        selector.kind = architecture == "any" ? PackageSelectorKind::Any :
            architecture == "native" ? PackageSelectorKind::Native : PackageSelectorKind::ExactArchitecture;
    }
    selector.baseName = base;
    return selector;
}

const TransactionPackageData *FindTransactionPackage(const TransactionData &transaction,
                                                     const std::string &identifier) {
    const auto direct(transaction.packages.find(identifier));
    if (direct != transaction.packages.end()) return &direct->second;
    const TransactionPackageData *match(NULL);
    for (const auto &operation : transaction.packages) {
        const PackageIdentity &identity(operation.second.identity);
        if (identifier != identity.aptName && identifier != identity.dpkgName &&
            identifier != identity.baseName + ":" + identity.versionArchitecture)
            continue;
        if (match != NULL) return NULL;
        match = &operation.second;
    }
    return match;
}

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

std::string BuildPackageRouteName(const std::string &baseName,
                                  const std::string &packageArchitecture,
                                  const std::string &nativeArchitecture) {
    if (baseName.empty() || packageArchitecture.empty() || nativeArchitecture.empty())
        return std::string();
    // APT stores qualified dependency proxies as Name="foo:any", Arch="any".
    if (packageArchitecture == "any" && baseName.find(':') != std::string::npos)
        return baseName;
    if (packageArchitecture == nativeArchitecture || packageArchitecture == "all")
        return baseName;
    return baseName + ":" + packageArchitecture;
}

bool IsNativeOrArchitectureIndependent(const std::string &versionArchitecture,
                                       const std::string &nativeArchitecture) {
    return !versionArchitecture.empty() && !nativeArchitecture.empty() &&
        (versionArchitecture == nativeArchitecture || versionArchitecture == "all");
}

bool IsPackageArchitectureVisible(const std::string &versionArchitecture,
                                  bool hasLocalState,
                                  const std::vector<std::string> &configuredArchitectures) {
    if (hasLocalState || versionArchitecture == "all")
        return true;
    return !versionArchitecture.empty() &&
        std::find(configuredArchitectures.begin(), configuredArchitectures.end(),
                  versionArchitecture) != configuredArchitectures.end();
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
    identity.routingName = BuildPackageRouteName(baseName, packageArchitecture,
                                                 nativeArchitecture);

    const bool foreignVersion = versionArchitecture != nativeArchitecture &&
        versionArchitecture != "all";
    if (!identity.architectureIndependent &&
        (multiArch == MultiArchMode::Same || foreignVersion))
        identity.dpkgName = baseName + ":" + versionArchitecture;
    else
        identity.dpkgName = baseName;

    return identity;
}

} // namespace CydiaAPT
