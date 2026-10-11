/* Cydia - iPhone UIKit Front-End for Debian APT
 * Repository trust decisions, independent of download integrity.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_RepositorySecurityPolicy_HPP
#define Cydia_RepositorySecurityPolicy_HPP

#include <string>

namespace CydiaAPT {

enum class RepositorySecurityMode {
    Allow,
    Warning,
    Error,
};

RepositorySecurityMode DefaultRepositorySecurityMode();
RepositorySecurityMode RepositorySecurityModeFromString(const std::string &value);
const char *RepositorySecurityModeName(RepositorySecurityMode mode);
bool AllowsInsecureRepositories(RepositorySecurityMode mode);

/* APT authentication status alone cannot distinguish an untrusted source
 * from a corrupt download. The backend supplies the independent integrity
 * result after checking the actual archive against its expected hashes. */
enum class ArchiveIntegrity {
    Verified,
    NotRequired,
    MissingExpectedHashes,
    Mismatch,
    Unavailable,
};

struct ArchiveSecurityDecision {
    bool allowed;
    bool warning;
};

ArchiveSecurityDecision EvaluateArchiveSecurity(RepositorySecurityMode mode,
                                                bool trusted,
                                                ArchiveIntegrity integrity);

} // namespace CydiaAPT

#endif // Cydia_RepositorySecurityPolicy_HPP
