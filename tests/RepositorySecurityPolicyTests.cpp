/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/RepositorySecurityPolicy.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

void Require(bool condition, const std::string &message) {
    if (!condition) {
        std::cerr << "[repository-security][FAIL] " << message << std::endl;
        std::exit(1);
    }
}

} // namespace

int main() {
    using namespace CydiaAPT;
    Require(DefaultRepositorySecurityMode() == RepositorySecurityMode::Warning,
            "default must permit insecure repositories with an advisory");
    const RepositorySecurityMode modes[] = {
        RepositorySecurityMode::Allow,
        RepositorySecurityMode::Warning,
        RepositorySecurityMode::Error,
    };
    for (RepositorySecurityMode mode : modes) {
        Require(RepositorySecurityModeFromString(RepositorySecurityModeName(mode)) == mode,
                "persisted mode did not round-trip");
        const bool permissive(mode != RepositorySecurityMode::Error);
        Require(AllowsInsecureRepositories(mode) == permissive,
                "metadata and archive policy disagree");

        for (bool trusted : { false, true }) {
            /* Integrity failure must win even for a trusted source and an
             * explicitly permissive policy. These states are independent
             * from APT's shared StatAuthError status. */
            for (ArchiveIntegrity failure : { ArchiveIntegrity::Mismatch,
                                             ArchiveIntegrity::Unavailable,
                                             ArchiveIntegrity::MissingExpectedHashes }) {
                const ArchiveSecurityDecision denied(EvaluateArchiveSecurity(mode, trusted, failure));
                Require(!denied.allowed && !denied.warning,
                        "integrity failure was demoted to a trust warning");
            }
            for (ArchiveIntegrity valid : { ArchiveIntegrity::Verified,
                                           ArchiveIntegrity::NotRequired }) {
                const ArchiveSecurityDecision decision(EvaluateArchiveSecurity(mode, trusted, valid));
                Require(decision.allowed == (trusted || permissive),
                        "valid archive had incorrect authentication decision");
                Require(decision.warning == (!trusted && mode == RepositorySecurityMode::Warning),
                        "warning must be advisory and limited to unauthenticated archives");
            }
        }
    }
    for (const char *value : { "", "warning", "unknown", "allow-unauthenticated" })
        Require(RepositorySecurityModeFromString(value) == RepositorySecurityMode::Warning,
                "missing/unknown preference did not preserve the Warning default");

    std::cout << "[repository-security][ ok ] three modes, integrity failures, "
                 "local hash exception and preference compatibility" << std::endl;
    return 0;
}
