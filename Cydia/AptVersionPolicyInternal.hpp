/* Cydia - iPhone UIKit Front-End for Debian APT
 * Debian version policy kept behind Cydia's private APT boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_AptVersionPolicyInternal_HPP
#define Cydia_AptVersionPolicyInternal_HPP

class pkgVersioningSystem;

namespace CydiaAPT {

bool IsDpkgVersionUpgrade(pkgVersioningSystem &versions,
                          const char *candidate, const char *installed);

} // namespace CydiaAPT

#endif // Cydia_AptVersionPolicyInternal_HPP
