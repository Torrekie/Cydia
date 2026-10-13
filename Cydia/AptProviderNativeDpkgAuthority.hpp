/* Native dpkg configuration and loader authority; never provider wire input.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderNativeDpkgAuthority_HPP
#define Cydia_AptProviderNativeDpkgAuthority_HPP
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/AptProviderComponentSuccession.hpp"
#include "Cydia/AptProviderNativeEffectPolicy.hpp"
#include "Cydia/NativeLaunchEnvironment.hpp"

namespace CydiaAPT { namespace Provider {
enum class NativeEffectRecordState { Missing, Parsed, Invalid };
struct NativeDpkgAuthority {
    std::string configurationIdentity, platformIdentity;
    // Parent-local exact launch snapshot. Configuration/approval identity
    // binds it; queries and mutation callbacks must pass this same envp.
    CydiaRuntime::NativeLaunchEnvironment launchEnvironment;
    std::string launchEnvironmentBytes; // Canonical consistency binding, never wire input.
    std::vector<CydiaRuntime::Privileged::Evidence> configurationEvidence;
    std::vector<std::string> componentPaths;
    std::map<std::string, std::vector<std::string>> successorPaths;
    // Root-owned declarations bind the complete native read/command graph to
    // exact executable generations. Neither argv nor an APT configuration
    // dump can establish dpkg's compiled configuration paths or includes.
    std::map<std::string, std::set<std::string>> executorGenerations;
    std::vector<std::string> commands;
    // Captured parent-local inputs for optional effective-policy matching.
    // V1 remains a complete graph declaration without an effect assertion.
    unsigned declarationVersion = 0;
    std::string declarationPath, dpkgRoot, dpkgAdmin, executableSearchPath;
    NativeEffectRecordState effectRecordState = NativeEffectRecordState::Missing;
    NativeEffectPolicy::Error effectRecordError = NativeEffectPolicy::Error::None;
    std::string effectRecordBytes;
    std::vector<NativeEffectPolicy::Record> effectRecords;
};
// Optional protected native-dpkg.conf: Cydia state first, then distribution
// cydia data beside dpkg data. A present invalid declaration never falls
// through. Missing/unsupported graph refuses transaction-owner admission.
bool ResolveNativeDpkgAuthority(const BrokerEnvironment &, const ReviewedTransaction &,
    NativeDpkgAuthority *, std::string *error, const std::function<bool()> &cancelled = {});
bool ResolveNativeDpkgAuthority(const CydiaRuntime::PackageDatabasePaths &, const BrokerEnvironment &,
    const ReviewedTransaction &, NativeDpkgAuthority *, std::string *error,
    const std::function<bool()> &cancelled = {});
bool RevalidateNativeDpkgAuthority(const NativeDpkgAuthority &,
    const std::vector<InstalledComponentEvidence> &, std::string *error);
bool CaptureNativeDpkgClosure(const NativeDpkgAuthority &, const std::string &executable,
    const std::vector<InstalledComponentEvidence> &, ComponentClosureEvidence *,
    std::string *error, const std::function<bool()> &cancelled = {});
// Build solely from retained protected graph evidence, freshly revalidated
// actual component/loader bytes and the authority's immutable launch snapshot.
// Prefix must be the parent's exact post-Bind/final-status-fd arguments; no
// argv interpretation, config parser, producer or policy activation occurs.
// Declaration bytes (including inline policy output), local stat/group fields
// and graph capture order are excluded from the content lookup identity.
bool BuildNativeEffectPolicyInputs(const NativeDpkgAuthority &, const std::string &executable,
    const std::vector<InstalledComponentEvidence> &, const std::string &semanticProfile,
    NativeEffectPolicy::Role, const std::vector<std::string> &finalizedOptionPrefix,
    NativeEffectPolicy::Inputs *, std::string *error, const std::function<bool()> &cancelled = {});
// Uses parent-owned APT SHA256. Matched is only a distributor assertion match:
// it grants no readiness/capability, deconfiguration approval or execution.
// Invalid/missing/unsupported records do not alter graph-v1 transaction gates.
NativeEffectPolicy::Match MatchNativeEffectPolicy(const NativeDpkgAuthority &, const std::string &executable,
    const std::vector<InstalledComponentEvidence> &, const std::string &semanticProfile,
    NativeEffectPolicy::Role, const std::vector<std::string> &finalizedOptionPrefix,
    std::string *error, const std::function<bool()> &cancelled = {});
#if defined(CYDIA_NATIVE_DPKG_AUTHORITY_TESTING)
// Only substitutes the two declaration locations. Parsing, protected reads,
// binary-generation validation and graph rechecks remain the production path.
void SetNativeDpkgAuthorityTestPaths(const std::string &primary, const std::string &fallback);
#endif
}}
#endif
