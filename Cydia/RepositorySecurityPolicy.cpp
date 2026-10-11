/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/RepositorySecurityPolicy.hpp"

namespace CydiaAPT {

RepositorySecurityMode DefaultRepositorySecurityMode() {
    return RepositorySecurityMode::Warning;
}

RepositorySecurityMode RepositorySecurityModeFromString(const std::string &value) {
    if (value == "allow")
        return RepositorySecurityMode::Allow;
    if (value == "error")
        return RepositorySecurityMode::Error;
    return DefaultRepositorySecurityMode();
}

const char *RepositorySecurityModeName(RepositorySecurityMode mode) {
    switch (mode) {
        case RepositorySecurityMode::Allow: return "allow";
        case RepositorySecurityMode::Warning: return "warning";
        case RepositorySecurityMode::Error: return "error";
    }
    return "warning";
}

bool AllowsInsecureRepositories(RepositorySecurityMode mode) {
    return mode == RepositorySecurityMode::Allow ||
        mode == RepositorySecurityMode::Warning;
}

ArchiveSecurityDecision EvaluateArchiveSecurity(RepositorySecurityMode mode,
                                                bool trusted,
                                                ArchiveIntegrity integrity) {
    ArchiveSecurityDecision result = { false, false };
    if (integrity != ArchiveIntegrity::Verified &&
        integrity != ArchiveIntegrity::NotRequired)
        return result;

    result.allowed = trusted || AllowsInsecureRepositories(mode);
    result.warning = result.allowed && !trusted &&
        mode == RepositorySecurityMode::Warning;
    return result;
}

} // namespace CydiaAPT
