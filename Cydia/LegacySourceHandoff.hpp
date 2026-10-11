/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_LegacySourceHandoff_HPP
#define Cydia_LegacySourceHandoff_HPP

namespace CydiaRuntime {
class PackageDatabasePaths;

/* Restore a marker-authorized sole legacy source without replacing a file
 * created by the maintainer between unpack and configure.  The implementation
 * is shared by the iOS postinst and host fixtures so the recovery contract is
 * executable rather than grep-only. */
bool RestoreLegacySourceHandoff();
// Maintscripts pass their package build layout explicitly; runtime detection
// is retained only for existing callers and generic host recovery fixtures.
bool RestoreLegacySourceHandoff(const PackageDatabasePaths &paths);

} // namespace CydiaRuntime

#endif // Cydia_LegacySourceHandoff_HPP
