/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRuntimeDescriptor_HPP
#define Cydia_AptRuntimeDescriptor_HPP
#include "Cydia/RepositorySecurityPolicy.hpp"
#include <string>
#include <vector>

namespace CydiaAPT {

// The coordinator supplies these identities after independent provider and
// protected-environment verification. They are not filesystem authority.
struct RuntimeDescriptorBinding {
    std::string providerIdentifier, session, libraryIdentity, frontendIdentity;
    std::string configurationIdentity, policyIdentity, methodsIdentity, packageStateIdentity;
};
bool SameRuntimeDescriptorBinding(const RuntimeDescriptorBinding &left, const RuntimeDescriptorBinding &right);

enum class RuntimeDescriptorOrigin { Embedded, External, RecoveryWorker };
constexpr const char RecoveryRuntimeProviderIdentifier[] = "cydia.bundled-recovery";

// Mutable only while being assembled. Adoption copies this entire value into
// a shared_ptr<const RuntimeDescriptor>; readers never see partially replaced
// paths/policy. A held snapshot survives later selection changes unchanged.
struct RuntimeDescriptor {
    RuntimeDescriptorOrigin origin = RuntimeDescriptorOrigin::External;
    RuntimeDescriptorBinding binding;
    std::string architecture;
    std::vector<std::string> registeredArchitectures, acquisitionArchitectures;
    std::string sourceListPath, sourcePartsDirectory, managedSourceListPath;
    std::string dpkgExecutablePath, dpkgQueryExecutablePath, dpkgDebExecutablePath;
    std::string gpgExecutablePath, aptConfigOverride, privilegedHelperPath;
    std::string dpkgAdminDirectory, dpkgRootDirectory, packageInstallPrefix, dpkgChrootDirectory;
    std::vector<std::string> dpkgOptions;
    std::string extendedStatesPath, methodsDirectory, listsDirectory;
    std::string trustedKeyringPath, trustedKeyringPartsDirectory;
    RepositorySecurityMode repositorySecurityMode = RepositorySecurityMode::Distribution;
    bool mutationEnvironmentValid = false;
    std::string runtimeErrorCode, runtimeError;
};

// Pure shape/coherence validation and exact comparison to the coordinator's
// independently verified binding. Does NOT probe executables, parse apt.conf,
// inspect ownership, establish policy equivalence, or authorize mutations.
// The caller must verify every path/option against the protected environment
// before adoption. Empty source locations intentionally disable that input.
bool ValidateRuntimeDescriptor(const RuntimeDescriptor &descriptor,
    const RuntimeDescriptorBinding &verifiedBinding, std::string *errorCode = nullptr);

} // namespace CydiaAPT
#endif
