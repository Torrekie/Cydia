/* Cydia Refurbished dpkg status parsing boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_DpkgStatusParser_H
#define Cydia_DpkgStatusParser_H

#include <string>

namespace CydiaRuntime {
namespace Dpkg {

struct PackageManagerProgressRecord {
    std::string type;
    std::string package;
    double percent;
    std::string message;

    PackageManagerProgressRecord();
};

/* Parse APT's type:package:percent:message stream without assuming package
 * names contain no colon. dpkg emits architecture-qualified names for
 * Multi-Arch: same and foreign package instances. */
bool ParsePackageManagerProgress(const std::string &line,
                                 PackageManagerProgressRecord *record);

} // namespace Dpkg
} // namespace CydiaRuntime

#endif
