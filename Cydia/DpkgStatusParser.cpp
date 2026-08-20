/* Cydia Refurbished dpkg status parsing boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/DpkgStatusParser.hpp"

#include <cerrno>
#include <cmath>
#include <cstdlib>

namespace CydiaRuntime {
namespace Dpkg {

PackageManagerProgressRecord::PackageManagerProgressRecord() : percent(0) {
}

namespace {

bool ParsePercent(const std::string &field, double *percent) {
    if (field.empty() || percent == NULL)
        return false;

    errno = 0;
    char *end(NULL);
    const double value(std::strtod(field.c_str(), &end));
    if (errno == ERANGE || end == field.c_str() || *end != '\0' ||
        !std::isfinite(value) || value < 0 || value > 100)
        return false;
    *percent = value;
    return true;
}

} // namespace

bool ParsePackageManagerProgress(const std::string &line,
                                 PackageManagerProgressRecord *record) {
    if (record == NULL)
        return false;
    *record = PackageManagerProgressRecord();

    const std::string::size_type typeEnd(line.find(':'));
    if (typeEnd == std::string::npos || typeEnd == 0)
        return false;

    const std::string::size_type packageBegin(typeEnd + 1);
    std::string::size_type packageEnd(line.find(':', packageBegin));
    while (packageEnd != std::string::npos) {
        const std::string::size_type percentEnd(line.find(':', packageEnd + 1));
        if (percentEnd == std::string::npos)
            return false;

        double percent;
        if (ParsePercent(line.substr(packageEnd + 1, percentEnd - packageEnd - 1),
                         &percent)) {
            if (packageEnd == packageBegin)
                return false;
            record->type.assign(line, 0, typeEnd);
            record->package.assign(line, packageBegin, packageEnd - packageBegin);
            record->percent = percent;
            record->message.assign(line, percentEnd + 1, std::string::npos);
            return true;
        }

        packageEnd = percentEnd;
    }

    return false;
}

} // namespace Dpkg
} // namespace CydiaRuntime
