/* Cydia - iPhone UIKit Front-End for Debian APT
 * Debian version policy kept behind Cydia's private APT boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptVersionPolicyInternal.hpp"

#include <apt-pkg/version.h>

namespace CydiaAPT {

bool IsDpkgVersionUpgrade(pkgVersioningSystem &versions,
                          const char *candidate, const char *installed) {
    if (candidate == NULL || installed == NULL)
        return false;

    // debSystem supplies debVS, which uses dpkg's epoch, upstream-version,
    // Debian-revision, and tilde ordering. Only a strictly newer candidate is
    // an available upgrade; a negative comparison is an optional downgrade.
    return versions.CmpVersion(candidate, installed) > 0;
}

} // namespace CydiaAPT
