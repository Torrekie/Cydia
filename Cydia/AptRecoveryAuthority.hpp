/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoveryAuthority_HPP
#define Cydia_AptRecoveryAuthority_HPP
#include "Cydia/AptRuntime.hpp"
#include "Cydia/PrivilegedRuntime.hpp"
#include <functional>

namespace CydiaAPT { namespace Recovery {

// Built by Cydia's authenticated helper from package-owned installation paths,
// never decoded from a worker or accepted as a native preference. The inputs
// describe the complete private payload; file existence is not closure proof.
struct BundleInputs {
    std::string executable;
    std::vector<std::string> libraries, dataFiles, requiredMethods;
};
struct Component {
    std::string path, sha256;
    bool executable = false;
};
struct DependencyProof {
    // A parent-owned inspector must bind an actual architecture/loadability
    // and dependency-closure check to this exact independently hashed set.
    // A version string, worker Info, or an installed-package record is not a
    // producer of this proof. No default inspector is supplied by this module.
    std::string inventoryIdentity, loaderIdentity;
    std::vector<std::string> nonPlatformDependencies;
    // Only the trusted parent inspector may discover selected external
    // dpkg/helper dylibs from their load commands. Private payload closures
    // remain declared. Authority recaptures every discovered hash itself.
    std::vector<Component> discoveredComponents;
    std::vector<std::string> unresolvedFields;
};
struct Identity {
    std::string configuration, policy, methods, libraries, frontend, dependencies;
};
bool SameIdentity(const Identity &, const Identity &);

struct Authority {
    Identity identity;
    RuntimeDescriptor runtime; // Embedded origin; no fabricated session/state binding.
    CydiaRuntime::Privileged::Environment environment;
    InitializationOptions startup;
    std::string executable, executableSearchPath, cacheDirectory, archivesDirectory, logDirectory;
    // Acquisition subprocesses prefer package-owned recovery-bin helpers.
    // executableSearchPath remains the selected dpkg policy for parent execution.
    std::string acquisitionSearchPath;
    // Effective clean parser output, including protected executable overrides.
    // The inspector must also cover configured subprocess/interpreter policy,
    // not only Mach-O load commands. Never log this potentially private text.
    std::string configuration;
    bool securityPreferenceExplicit = false;
    // Captured before Cydia's process-local override; absent keys stay absent.
    std::map<std::string, std::string> configuredSecurity;
    std::vector<Component> components;
    std::vector<std::string> unresolvedFields;
};
using DependencyInspector = std::function<DependencyProof(const Authority &,
    const std::string &inventoryIdentity, const std::function<bool()> &cancelled)>;

// Nonmutating capture in the existing, serialized authenticated helper. Seeds
// must be reconstructed by that helper, not trusted from worker/IPC claims.
// ResolveCurrentEnvironment remains authority for dpkg/source/trust/state
// paths; the local private-APT parser supplies the remaining recovery fields
// and must agree with that independently resolved core. No global Initialize,
// pkgInitSystem, acquisition, source writes or privileged child is invoked.
// APT_CONFIG must be unset: the explicit protected override is read here.
// Existing helper resolution is synchronous; timeout/cancellation bounds all
// work this module controls, including architecture children and file hashing.
//
// true means complete capture including supplied trusted dependency proof;
// it is NOT a successful worker probe, protocol capability or activation.
// On missing dependency proof, false retains the captured Authority with
// unresolvedFields and mutationEnvironmentValid=false for diagnostics only.
// Other failures clear the output. Package-state capture must be done later
// with the authenticated source-reader identity and the normal held lock.
bool ResolveAuthority(const CydiaRuntime::PackageDatabasePaths &paths,
    const InitializationOptions &helperStartup, const std::string &aptConfigOverride,
    const std::string &savedSecurityPreference, const BundleInputs &bundle,
    const Identity *expected, Authority *result, CydiaRuntime::Privileged::Error *error,
    const DependencyInspector &inspect = DependencyInspector(), unsigned timeoutMilliseconds = 4000,
    const std::function<bool()> &cancelled = std::function<bool()>());

// Recompute hashes and configuration, then compare identities. Retaining a
// snapshot or merely re-statting its files never renews authority.
bool RecheckAuthority(const CydiaRuntime::PackageDatabasePaths &paths, const Authority &previous,
    const std::string &savedSecurityPreference, const BundleInputs &bundle,
    CydiaRuntime::Privileged::Error *error, const DependencyInspector &inspect = DependencyInspector(),
    unsigned timeoutMilliseconds = 4000, const std::function<bool()> &cancelled = std::function<bool()>());

#if defined(CYDIA_RECOVERY_AUTHORITY_TESTING)
// Fixture-only core resolver: production cannot substitute worker-provided
// paths for the protected helper's resolver. File/parser/hash checks remain real.
using FixtureResolver = std::function<bool(const CydiaRuntime::PackageDatabasePaths &,
    const std::string &, CydiaRuntime::Privileged::Environment *, CydiaRuntime::Privileged::Error *)>;
bool ResolveAuthorityForTesting(const CydiaRuntime::PackageDatabasePaths &, const InitializationOptions &,
    const std::string &, const std::string &, const BundleInputs &, const Identity *, Authority *,
    CydiaRuntime::Privileged::Error *, const FixtureResolver &, const DependencyInspector &,
    unsigned timeoutMilliseconds = 4000, const std::function<bool()> &cancelled = std::function<bool()>());
#endif
}} // namespace CydiaAPT::Recovery
#endif
