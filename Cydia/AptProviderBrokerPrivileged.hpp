/* Private authenticated Cydia/cydo contract, never a provider capability.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderBrokerPrivileged_HPP
#define Cydia_AptProviderBrokerPrivileged_HPP
#include "Cydia/AptProviderSelection.hpp"
#include "Cydia/AptProviderDpkgState.hpp"
#include "Cydia/AptRecoveryInstalledAuthority.hpp"

namespace CydiaAPT { namespace Provider {
// Wrapped inside the existing bounded Privileged::Request. Registration
// identities are expectations; the helper reads root-owned authority itself.
bool BrokerRequestPayload(const RegistrationIdentity &authority, const std::string &payload, std::string *bytes);
bool BrokerRequestPayload(const Recovery::RequestAuthority &authority, const std::string &payload, std::string *bytes);
struct BrokerEnvironment {
    RuntimeDescriptor runtime;
    CydiaRuntime::Privileged::Environment environment;
    // Native dpkg policy; never prepend private recovery commands here.
    std::string executableSearchPath;
    // Independently captured decoder policy. This is derived locally from a
    // verified registration/recovery authority, never decoded from a request.
    std::string archiveDecoderSearchPath;
    BrokerEnvironment() = default;
    explicit BrokerEnvironment(const RegisteredProviderEnvironment &);
    explicit BrokerEnvironment(const Recovery::Authority &);
};
// Call only after independently resolving this exact wrapped request. Binds
// the already checked authority expectations; it never resolves authority.
bool BindResolvedBrokerRuntime(const CydiaRuntime::Privileged::Request &, BrokerEnvironment *);
// Recovery selection always uses the authenticated caller, local installed
// inventory, and a Cydia-owned inspector. None is supplied by the worker.
bool ResolveBrokerRequest(const CydiaRuntime::PackageDatabasePaths &paths,
    const CydiaRuntime::Privileged::Request &request, uid_t authenticatedUID,
    BrokerEnvironment *selected, std::string *payload, CydiaRuntime::Privileged::Error *error,
    const Recovery::DependencyInspector &inspect = Recovery::DependencyInspector());
bool ResolveBrokerRequest(const CydiaRuntime::PackageDatabasePaths &paths,
                          const CydiaRuntime::Privileged::Request &request,
                          RegisteredProviderEnvironment *selected, std::string *payload,
                          CydiaRuntime::Privileged::Error *error);
bool EncodeBrokerState(const DpkgState &state, std::string *bytes);
bool DecodeBrokerState(const std::string &bytes, DpkgState *state);
// Main Cydia process owns the fcntl lock; a direct authenticated cydo child
// observes that ownership while independently collecting protected evidence.
bool CaptureDpkgStateForParent(const CydiaRuntime::Privileged::Environment &environment,
                              pid_t authenticatedParent, DpkgState *state, std::string *error);

struct BrokerDpkgRequest {
    std::string stateIdentity;
    ExecutionAction action = ExecutionAction::Unpack;
    std::vector<std::string> arguments;
    std::vector<ArchiveManifest> archives;
    std::set<std::string> acceptedArchiveWarnings;
};
bool EncodeBrokerDpkg(const BrokerDpkgRequest &request, std::string *bytes);
bool DecodeBrokerDpkg(const std::string &bytes, BrokerDpkgRequest *request);
// Copies only the approved unpack files into a protected helper-owned
// transaction directory. The executor runs before this function cleans them.
bool ExecuteBrokerDpkg(const CydiaRuntime::PackageDatabasePaths &paths,
    const BrokerEnvironment &selected, pid_t parent, const BrokerDpkgRequest &request,
    const std::function<int(const std::string &, const std::vector<std::string> &)> &execute,
    int *exitCode, CydiaRuntime::Privileged::Error *error);
bool ExecuteBrokerDpkg(const CydiaRuntime::PackageDatabasePaths &paths,
    const RegisteredProviderEnvironment &selected, pid_t parent, const BrokerDpkgRequest &request,
    const std::function<int(const std::string &, const std::vector<std::string> &)> &execute,
    int *exitCode, CydiaRuntime::Privileged::Error *error);
}} // namespace CydiaAPT::Provider
#endif
