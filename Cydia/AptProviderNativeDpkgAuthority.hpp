/* Native dpkg configuration and loader authority; never provider wire input.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderNativeDpkgAuthority_HPP
#define Cydia_AptProviderNativeDpkgAuthority_HPP
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/AptProviderComponentSuccession.hpp"

namespace CydiaAPT { namespace Provider {
struct NativeDpkgAuthority {
    std::string configurationIdentity, platformIdentity;
    std::vector<CydiaRuntime::Privileged::Evidence> configurationEvidence;
    std::vector<std::string> componentPaths;
    std::map<std::string, std::vector<std::string>> successorPaths;
    // Root-owned declarations bind the complete native read/command graph to
    // exact executable generations. Neither argv nor an APT configuration
    // dump can establish dpkg's compiled configuration paths or includes.
    std::map<std::string, std::set<std::string>> executorGenerations;
    std::vector<std::string> commands;
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
#if defined(CYDIA_NATIVE_DPKG_AUTHORITY_TESTING)
// Only substitutes the two declaration locations. Parsing, protected reads,
// binary-generation validation and graph rechecks remain the production path.
void SetNativeDpkgAuthorityTestPaths(const std::string &primary, const std::string &fallback);
#endif
}}
#endif
