/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoverySnapshot_HPP
#define Cydia_AptRecoverySnapshot_HPP
#include "Cydia/AptRecoveryAuthority.hpp"
#include "Cydia/AptProviderProtocol.hpp"

namespace CydiaAPT { namespace Recovery {
constexpr std::size_t MaximumSnapshotBytes = 4 * 1024 * 1024;
constexpr std::size_t MaximumConfigurationBytes = 1024 * 1024;
const char *ProviderIdentifier();

// User choices accepted only from the authenticated Cydia parent. These do
// not supply executable, configuration-directory, payload or database paths.
// The optional apt.conf override is independently opened as protected input.
struct Preferences {
    std::string aptConfigOverride, securityPreference, translation, languages;
    int maxParallel = 0;
    bool forceEssential = false;
};
struct RequestAuthority {
    Identity identity;
    Preferences preferences;
};
bool ValidatePreferences(const Preferences &);
std::string SerializePreferences(const Preferences &);
bool ParsePreferences(const std::string &, Preferences *);
std::string SerializeIdentity(const Identity &);
bool ParseIdentity(const std::string &, Identity *);
std::string SerializeRequestAuthority(const RequestAuthority &);
bool ParseRequestAuthority(const std::string &, RequestAuthority *);

// A value-only capsule from Cydia's authenticated helper. It deliberately
// contains no privileged Environment/evidence, fake external registration,
// session nonce, or claim that a worker handshake has already succeeded.
// configuration is the clean effective configuration before Cydia's selected
// security override. The worker must not reread ambient configuration.
struct Snapshot {
    Identity identity;
    RuntimeDescriptor runtime;
    InitializationOptions startup;
    std::string executable, executableSearchPath, cacheDirectory, archivesDirectory, logDirectory;
    // Derived by the protected parent from executable's recovery-bin sibling
    // followed by executableSearchPath; never an inventory-supplied environment.
    std::string acquisitionSearchPath;
    std::string configuration, packageStateIdentity;
    bool securityPreferenceExplicit = false;
    std::map<std::string, std::string> configuredSecurity;
    std::vector<Component> components;
};
// These are bounded shape/coherence checks, not independent runtime proof.
bool ValidateSnapshot(const Snapshot &);
bool MakeSnapshot(const Authority &, const std::string &packageStateIdentity, Snapshot *);
std::string SerializeSnapshot(const Snapshot &);
bool ParseSnapshot(const std::string &, Snapshot *);
RequestAuthority AuthorityRequest(const Snapshot &);
Provider::Environment SnapshotEnvironment(const Snapshot &);
}} // namespace CydiaAPT::Recovery
#endif
