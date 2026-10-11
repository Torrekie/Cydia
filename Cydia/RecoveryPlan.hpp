/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RecoveryPlan_HPP
#define Cydia_RecoveryPlan_HPP
#include <string>
#include <vector>
namespace CydiaRuntime { namespace Recovery {
struct Analysis {
    std::string package, state, stanza, reason;
    bool canConfigure, canEmergencyRemove;
    std::vector<std::string> affected;
    Analysis() : canConfigure(false), canEmergencyRemove(false) {}
};
struct Review {
    Analysis analysis;
    std::vector<std::string> scripts;
    std::string token;
};
bool ValidPackageIdentity(const std::string &identity);
/* Reads actual dpkg state, including versioned/virtual and multiarch
 * dependencies. Unsupported or ambiguous metadata denies emergency removal.
 * The active frontend name is supplied by its independently installed helper,
 * never by a request. No bootstrap/repository/package-name catalogue exists. */
Analysis AnalyzeStatus(const std::string &status, const std::string &identity,
                       const std::string &nativeArchitecture,
                       const std::string &activeFrontend = "cydia");
std::string SerializeReview(const Review &review);
bool ParseReview(const std::string &bytes, Review *review);
} }
#endif
