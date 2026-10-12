/* Cydia - iPhone UIKit Front-End for Debian APT
 * Stable startup configuration boundary for the embedded APT runtime.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_AptRuntime_HPP
#define Cydia_AptRuntime_HPP

#include "Cydia/RepositorySecurityPolicy.hpp"
#include "Cydia/AptRuntimeDescriptor.hpp"

#include <memory>
#include <string>
#include <vector>

namespace CydiaAPT {

namespace Recovery { struct Snapshot; }

struct InitializationOptions {
    std::string architecture;
    std::string aptConfigDirectory;
    std::string methodsDirectory;
    std::string cacheDirectory;
    std::string stateDirectory;
    std::string listsDirectory;
    std::string logDirectory;
    std::string dpkgStatusPath;
    std::string bootstrapExtendedStatesPath;
    std::string dpkgPath;
    /* Real, unprivileged dpkg used for architecture queries. dpkgPath is
     * Cydia's privileged package-manager wrapper. */
    std::string nativeDpkgPath;
    /* Package payload prefix selected by the installed Cydia layout, not
     * inferred from a CPU architecture or the dpkg database location. */
    std::string packageInstallPrefix;
    /* Root-selected private authority, not a native preference. */
    std::string privateRuntimeConfigurationPath;
    std::string helperPath;
    std::string dpkgDataDirectory;
    std::string dpkgExecutableSearchPath;
    std::string translation;
    std::string languages;
    int maxParallel;
    RepositorySecurityMode repositorySecurityMode;
    bool forceEssential;

    InitializationOptions() : maxParallel(0),
        repositorySecurityMode(DefaultRepositorySecurityMode()), forceEssential(false) {}
};

/* Initializes the process-wide APT configuration and returns its selected
 * architecture.  The implementation is the only place that calls the APT
 * init/configuration API. */
bool Initialize(const InitializationOptions &options, std::string *architecture);
// Recovery-worker startup only: consume a parent-verified, complete capsule.
// No ambient configuration, includes, executable discovery, architecture child
// or shared-state mutation is performed. Shape validation is not authority.
bool InitializeRecoverySnapshot(const Recovery::Snapshot &snapshot,
    std::string *errorCode = nullptr);
/* All selection APIs require Database serialization, closed caches and no
 * active operation. Adoption never initializes or alters embedded APT. The
 * coordinator must independently verify authority before supplying binding.
 * A second adoption requires explicit reset and fresh review/cache state.
 * Legacy getters returning references have the same serialization requirement;
 * use a held immutable snapshot when a value must survive a selection change. */
bool AdoptRuntimeDescriptor(const RuntimeDescriptor &descriptor,
    const RuntimeDescriptorBinding &verifiedBinding, std::string *errorCode = nullptr);
void ResetRuntimeDescriptor();
/* Null until an external descriptor has been adopted. ReadRuntimeDescriptor
 * also exports an immutable copy of the embedded snapshot when unselected.
 * Embedded exports have no verified provider/session binding. */
std::shared_ptr<const RuntimeDescriptor> ActiveRuntimeDescriptor();
std::shared_ptr<const RuntimeDescriptor> ReadRuntimeDescriptor();
RuntimeDescriptor ReadEmbeddedRuntimeDescriptor();
/* Trust is mutable coordinator evidence, not descriptor data. Updating it
 * requires the exact selected provider/configuration/policy/state binding. */
bool SetRuntimeDescriptorTrustValid(const RuntimeDescriptorBinding &binding, bool valid);
// After opening a new cache, the coordinator independently recaptures the
// registered environment and matches its package-state token to the session.
// Only that verified token may change; provider paths/policy remain immutable.
bool UpdateRuntimeDescriptorPackageState(const RuntimeDescriptorBinding &expected, const std::string &verifiedState);
/* Process-local overrides only: no other frontend's apt.conf is modified.
 * Call the setter under Database's serialization boundary, outside an active
 * acquisition, since APT's configuration is process-global. Distribution
 * restores the independent settings captured from this runtime's clean
 * initialization, including absent values and the provider's defaults. */
bool SetRepositorySecurityMode(RepositorySecurityMode mode);
RepositorySecurityMode GetRepositorySecurityMode();
/* Only a completed metadata refresh may establish the current process's
 * trust proof. Reloading caches or changing policy must not renew it. */
bool SetCachedRepositoryTrustValid(bool valid);
bool CachedRepositoryTrustValid();
/* Selected native architecture. APT's startup fallback remains available
 * for read-only use if initial dpkg discovery fails. */
const std::string &Architecture();
/* APT's effective index-acquisition policy, including its native default.
 * This list is not evidence that dpkg permits installing an architecture. */
const std::vector<std::string> &Architectures();
/* Verified dpkg native architecture first, followed by registered foreign
 * architectures. Empty until both architecture probes have succeeded. */
const std::vector<std::string> &RegisteredArchitectures();
/* Requery the selected dpkg and refresh APT's generated acquisition default.
 * Explicit APT::Architectures policy is preserved. Call only after closing
 * caches, under Database serialization, outside an active acquisition. Both
 * probes must succeed before publishing; failure retains the last verified
 * values and disables mutations. The return value reports query success,
 * not overall MutationEnvironmentValid(). Success clears only the query
 * failure, not any unrelated environment error. It may invalidate Architecture()'s
 * c_str(), so callers must not retain that pointer across refreshes. */
bool RefreshArchitectures();
/* Paths resolved from the distro/bootstrap APT configuration.  Cydia never
 * replaces these with a private source context. */
const std::string &SourceListPath();
const std::string &SourcePartsDirectory();
/* Optional maintainer-declared Cydia-owned .list path.  An empty value means
 * Cydia leaves source editing read-only. */
const std::string &ManagedSourceListPath();
const std::string &DpkgExecutablePath();
const std::string &DpkgQueryExecutablePath();
const std::string &DpkgDebExecutablePath();
/* Effective configured GnuPG executable, including protected overrides.
 * A caller executing it must independently validate its protected path. */
std::string GpgExecutablePath();
const std::string &AptConfigOverride();
const std::string &PrivilegedHelperPath();
const std::string &DpkgAdminDirectory();
const std::string &DpkgRootDirectory();
/* Expected prefix inside archives, relative to dpkg's installation root.
 * An administrator may declare Cydia::Package-Install-Prefix in apt.conf. */
const std::string &PackageInstallPrefix();
const std::string &DpkgChrootDirectory();
const std::vector<std::string> &DpkgOptions();
bool MutationEnvironmentValid();
const std::string &RuntimeError();
const std::string &RuntimeErrorCode();
const std::string &ExtendedStatesPath();
const std::string &MethodsDirectory();
const std::string &ListsDirectory();
/* Dir::Etc::trusted is the legacy keyring file; trustedparts is a directory. */
const std::string &TrustedKeyringDirectory();
const std::string &TrustedKeyringPartsDirectory();
/* Installation architecture policy: registered dpkg architectures and all. */
bool IsArchitectureSupported(const std::string &architecture);
std::string SourceArchitectureOption();

} // namespace CydiaAPT

#endif // Cydia_AptRuntime_HPP
