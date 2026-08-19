/* Cydia - iPhone UIKit Front-End for Debian APT
 * Version-sensitive libapt-pkg calls used only by the private backend.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_AptCompatibilityInternal_HPP
#define Cydia_AptCompatibilityInternal_HPP

#include "Cydia/AptCompatibility.hpp"

class pkgCache;
class pkgDepCache;
class pkgAcquireStatus;
class pkgPackageManager;
class pkgProblemResolver;
class pkgSourceList;

namespace CydiaAPT {

PackageManagerResult RunPackageManager(pkgPackageManager &manager, int statusFd);
bool CleanArchives(const std::string &directory, pkgCache &cache);
bool ApplyStatus(pkgDepCache &cache);
bool FixBroken(pkgDepCache &cache);
bool MinimizeUpgrade(pkgDepCache &cache);
bool PrepareDistUpgrade(pkgDepCache &cache);
bool ResolveDependencies(pkgProblemResolver &resolver);
bool UpdateLists(pkgAcquireStatus &status, pkgSourceList &list, int pulseInterval);

} // namespace CydiaAPT

#endif // Cydia_AptCompatibilityInternal_HPP
