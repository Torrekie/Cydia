/* Cydia - iPhone UIKit Front-End for Debian APT
 * Stable startup configuration boundary for the embedded APT runtime.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_AptRuntime_HPP
#define Cydia_AptRuntime_HPP

#include "Cydia/RepositorySecurityPolicy.hpp"

#include <string>
#include <vector>

namespace CydiaAPT {

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
    /* Root-selected private authority, not a native preference. */
    std::string privateRuntimeConfigurationPath;
    std::string helperPath;
    std::string dpkgDataDirectory;
    std::string dpkgExecutableSearchPath;
    std::string translation;
    std::string languages;
    int maxParallel;
    RepositorySecurityMode repositorySecurityMode;
    bool checkValidUntil;
    bool forceEssential;

    InitializationOptions();
};

/* Initializes the process-wide APT configuration and returns its selected
 * architecture.  The implementation is the only place that calls the APT
 * init/configuration API. */
bool Initialize(const InitializationOptions &options, std::string *architecture);
/* Process-local overrides only: no other frontend's apt.conf is modified.
 * Call the setter under Database's serialization boundary, outside an active
 * acquisition, since APT's configuration is process-global. */
void SetRepositorySecurityMode(RepositorySecurityMode mode);
RepositorySecurityMode GetRepositorySecurityMode();
/* Only a completed metadata refresh may establish the current process's
 * trust proof. Reloading caches or changing policy must not renew it. */
void SetCachedRepositoryTrustValid(bool valid);
bool CachedRepositoryTrustValid();
const std::string &Architecture();
const std::vector<std::string> &Architectures();
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
const std::string &AptConfigOverride();
const std::string &PrivilegedHelperPath();
const std::string &DpkgAdminDirectory();
const std::string &DpkgRootDirectory();
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
bool IsArchitectureSupported(const std::string &architecture);
std::string SourceArchitectureOption();

} // namespace CydiaAPT

#endif // Cydia_AptRuntime_HPP
