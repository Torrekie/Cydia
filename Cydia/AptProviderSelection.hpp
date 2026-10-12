/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderSelection_HPP
#define Cydia_AptProviderSelection_HPP
#include "Cydia/AptProviderClient.hpp"
#include "Cydia/AptRuntimeDescriptor.hpp"

namespace CydiaAPT { namespace Provider {

// Session-independent authority. Every privileged operation rereads the
// protected registration and compares these locally derived identities.
struct RegistrationIdentity {
    std::string registrationPath, providerIdentifier;
    std::string configurationIdentity, policyIdentity, methodsIdentity;
    std::string libraryIdentity, frontendIdentity;
};
bool SameRegistrationIdentity(const RegistrationIdentity &, const RegistrationIdentity &);
std::string SerializeRegistrationIdentity(const RegistrationIdentity &);
bool ParseRegistrationIdentity(const std::string &, RegistrationIdentity *);

struct RegisteredProviderEnvironment {
    RegistrationIdentity identity;
    std::string executable, executableSearchPath;
    RuntimeDescriptor runtime; // Complete paths/policy, but no session yet.
    CydiaRuntime::Privileged::Environment environment;
};

// Root-owned registration v1 is the runtime authority; embedded libapt's
// defaults are never consulted. expected == nullptr is permitted only for
// initial nonmutating discovery. All later calls compare the exact identity.
// The caller supplies its authenticated source reader identity before taking
// RuntimeSnapshot/TrustSnapshot. No app-only symbols are needed by this API.
//
// File format: Privileged::SerializeFields({"CYDIA-APT-PROVIDER-1", key,
// value, ...}). Every key below is required exactly once; unused values are
// empty. List values are nested SerializeFields arrays, preserving order.
// Scalars: Identifier, Adapter, ExecutableSearchPath, SourceList, SourceParts,
// ManagedSourceList, Dpkg, DpkgQuery, DpkgDeb, Gpg, AptConfigOverride, DpkgRoot,
// DpkgAdmin, PackageInstallPrefix, DpkgChroot, ExtendedStates, Methods, Lists,
// Trusted, TrustedParts, Preferences, PreferencesParts.
// Lists: Libraries, Frontends, ConfigurationFiles, ConfigurationDirectories,
// OptionalConfigurationFiles, OptionalConfigurationDirectories, PolicyFiles,
// PolicyDirectories, DpkgOptions, AcquisitionArchitectures.
// Libraries declares the complete non-system dependency closure; Frontends
// includes the distribution frontend whose compiled policy is used. Config
// lists declare the complete read graph, including defaults/optional includes;
// directories are captured recursively. A changed effective path or default
// requires an updated protected registration, never a claim from Info.
// Empty AcquisitionArchitectures uses verified dpkg architectures; otherwise
// native is prepended if absent. Cydia's own helper path cannot be overridden
// here. Native saved tool overrides remain separate protected authority.
bool ResolveRegisteredProviderEnvironment(const CydiaRuntime::PackageDatabasePaths &paths,
    const std::string &registrationPath, const RegistrationIdentity *expected,
    RegisteredProviderEnvironment *result, CydiaRuntime::Privileged::Error *error,
    unsigned timeoutMilliseconds = 4000,
    const std::function<bool()> &cancelled = std::function<bool()>());

// Value response from Cydia's authenticated privileged snapshot route. The
// authority resolver fills runtime; its freshly captured RuntimeSnapshot fills
// packageStateIdentity. Registration paths/options remain root-selected data.
struct RegisteredProviderSnapshot {
    RegistrationIdentity identity;
    std::string executable, executableSearchPath, packageStateIdentity;
    RuntimeDescriptor runtime;
};
// Pure shape validation; this does not establish registration authority.
bool ValidateRegisteredProviderSnapshot(const RegisteredProviderSnapshot &);
std::string SerializeRegisteredProviderSnapshot(const RegisteredProviderSnapshot &);
bool ParseRegisteredProviderSnapshot(const std::string &, RegisteredProviderSnapshot *);
RegisteredProviderSnapshot MakeRegisteredProviderSnapshot(const RegisteredProviderEnvironment &,
    const std::string &packageStateIdentity);

std::vector<std::string> ProviderRegistrationCandidates(const CydiaRuntime::PackageDatabasePaths &paths);
typedef std::function<bool(const std::string &, const RegistrationIdentity *,
    RegisteredProviderSnapshot *, CydiaRuntime::Privileged::Error *, unsigned,
    const std::function<bool()> &)> RegistrationSnapshotReader;
struct SelectionResult {
    Availability availability = Availability::Missing;
    std::string errorCode;
    RegisteredProviderSnapshot snapshot;
    ProbeResult probe;
    Hello hello;
    bool ready() const { return availability == Availability::Ready; }
};
// The reader must call the authenticated Cydia helper route, not the adapter.
// A present but invalid explicit registration never falls through to another
// provider. This function probes only; the coordinator owns Session::Start,
// descriptor adoption, backend replacement and rollback before any operation.
SelectionResult DiscoverProvider(const CydiaRuntime::PackageDatabasePaths &paths,
    const InitializationOptions &options, const std::string &savedSecurityPreference,
    const RegistrationSnapshotReader &reader, unsigned timeoutMilliseconds = 4000,
    const std::function<bool()> &cancelled = std::function<bool()>());

}} // namespace CydiaAPT::Provider
#endif
