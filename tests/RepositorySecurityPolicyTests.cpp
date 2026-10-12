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
            "default must retain compatibility until external provider activation");
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
    for (const char *value : { "", "unknown", "allow-unauthenticated" })
        Require(RepositorySecurityModeFromString(value) == RepositorySecurityMode::Warning,
                "missing/unknown preference changed the existing Warning default");
    Require(RepositorySecurityModeFromString("distribution") == RepositorySecurityMode::Distribution,
            "explicit inheritance preference did not round-trip");
    Require(RepositorySecurityModeFromString("warning") == RepositorySecurityMode::Warning,
            "explicitly saved Warning must not migrate to inheritance");
    for (const char *saved : { "allow", "warning", "error", "distribution" }) {
        Require(IsRepositorySecurityModeName(saved), "saved security choice was not recognized");
        for (bool externalReady : { false, true })
            Require(EffectiveRepositorySecurityMode(saved, externalReady) == RepositorySecurityModeFromString(saved),
                    "provider activation changed an explicit security choice");
    }
    for (const char *absent : { "", "unknown", "WARNING", "allow-unauthenticated" }) {
        Require(!IsRepositorySecurityModeName(absent), "invalid preference became an explicit choice");
        Require(EffectiveRepositorySecurityMode(absent, false) == RepositorySecurityMode::Warning,
                "absence changed the shipped default before external activation");
        Require(EffectiveRepositorySecurityMode(absent, true) == RepositorySecurityMode::Distribution,
                "absence did not inherit the selected ready external provider");
    }
    Require(!IsRepositorySecurityModeName(std::string("warning\0extra", 13)),
            "a malformed preference with an embedded NUL became a saved choice");
    for (bool trusted : { false, true }) {
        for (bool allowUnauthenticated : { false, true }) {
            const auto accepted(EvaluateArchiveSecurity(RepositorySecurityMode::Distribution,
                trusted, ArchiveIntegrity::Verified, allowUnauthenticated));
            Require(accepted.allowed == (trusted || allowUnauthenticated),
                    "distribution archive allowance was not respected");
            Require(accepted.warning == (!trusted && allowUnauthenticated),
                    "accepted unauthenticated distribution archives need an advisory");
            const auto corrupt(EvaluateArchiveSecurity(RepositorySecurityMode::Distribution,
                trusted, ArchiveIntegrity::Mismatch, allowUnauthenticated));
            Require(!corrupt.allowed && !corrupt.warning,
                    "distribution allowance bypassed archive integrity");
        }
    }

    std::cout << "[repository-security][ ok ] inheritance, explicit overrides, integrity failures, "
                 "local hash exception and preference compatibility" << std::endl;
    return 0;
}
