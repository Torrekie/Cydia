/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/RepositorySecurityPolicy.hpp"

namespace CydiaAPT {

RepositorySecurityMode DefaultRepositorySecurityMode() {
    // Preserve the shipped frontend default while external-provider
    // activation is deferred. Configuration inheritance alone cannot
    // reproduce a distribution's compiled APT policy.
    return RepositorySecurityMode::Warning;
}

RepositorySecurityMode RepositorySecurityModeFromString(const std::string &value) {
    if (value == "allow")
        return RepositorySecurityMode::Allow;
    if (value == "error")
        return RepositorySecurityMode::Error;
    if (value == "warning")
        return RepositorySecurityMode::Warning;
    if (value == "distribution")
        return RepositorySecurityMode::Distribution;
    return DefaultRepositorySecurityMode();
}

const char *RepositorySecurityModeName(RepositorySecurityMode mode) {
    switch (mode) {
        case RepositorySecurityMode::Allow: return "allow";
        case RepositorySecurityMode::Warning: return "warning";
        case RepositorySecurityMode::Error: return "error";
        case RepositorySecurityMode::Distribution: return "distribution";
    }
    return "warning";
}

bool AllowsInsecureRepositories(RepositorySecurityMode mode) {
    return mode == RepositorySecurityMode::Allow ||
        mode == RepositorySecurityMode::Warning;
}

ArchiveSecurityDecision EvaluateArchiveSecurity(RepositorySecurityMode mode,
                                                bool trusted,
                                                ArchiveIntegrity integrity,
                                                bool distributionAllowsUnauthenticated) {
    ArchiveSecurityDecision result = { false, false };
    if (integrity != ArchiveIntegrity::Verified &&
        integrity != ArchiveIntegrity::NotRequired)
        return result;

    result.allowed = trusted || AllowsInsecureRepositories(mode) ||
        (mode == RepositorySecurityMode::Distribution && distributionAllowsUnauthenticated);
    result.warning = result.allowed && !trusted &&
        (mode == RepositorySecurityMode::Warning || mode == RepositorySecurityMode::Distribution);
    return result;
}

} // namespace CydiaAPT
