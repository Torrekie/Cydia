/* Bounded value encoding shared by Cydia and its existing privileged helper.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderBrokerPrivileged.hpp"
namespace CydiaAPT { namespace Provider {
bool BindResolvedBrokerRuntime(const CydiaRuntime::Privileged::Request &request, BrokerEnvironment *selected) {
    std::vector<std::string> fields;
    if (!selected || !Decode(request.payload, &fields) || fields.size() != 3) return false;
    auto &binding = selected->runtime.binding;
    if (fields[0] == "CYDIA-BROKER-1") {
        RegistrationIdentity authority;
        if (!ParseRegistrationIdentity(fields[1], &authority)) return false;
        binding.providerIdentifier = authority.providerIdentifier;
        binding.configurationIdentity = authority.configurationIdentity; binding.policyIdentity = authority.policyIdentity;
        binding.methodsIdentity = authority.methodsIdentity; binding.libraryIdentity = authority.libraryIdentity;
        binding.frontendIdentity = authority.frontendIdentity;
    } else if (fields[0] == "CYDIA-RECOVERY-BROKER-1") {
        Recovery::RequestAuthority authority;
        if (!Recovery::ParseRequestAuthority(fields[1], &authority)) return false;
        binding.providerIdentifier = Recovery::ProviderIdentifier();
        binding.configurationIdentity = authority.identity.configuration; binding.policyIdentity = authority.identity.policy;
        binding.methodsIdentity = authority.identity.methods; binding.libraryIdentity = authority.identity.libraries;
        binding.frontendIdentity = authority.identity.frontend;
    } else return false;
    return true;
}
namespace {
std::string Words(const std::vector<std::string> &values) {
    std::string result;
    for (const auto &value : values) { if (!result.empty()) result += ' '; result += value; }
    return result;
}
}
BrokerEnvironment::BrokerEnvironment(const RegisteredProviderEnvironment &selected) :
    runtime(selected.runtime), environment(selected.environment),
    executableSearchPath(selected.executableSearchPath), archiveDecoderSearchPath(selected.executableSearchPath) {}
BrokerEnvironment::BrokerEnvironment(const Recovery::Authority &selected) :
    runtime(selected.runtime), environment(selected.environment),
    executableSearchPath(selected.executableSearchPath), archiveDecoderSearchPath(selected.acquisitionSearchPath) {}
bool BrokerRequestPayload(const RegistrationIdentity &authority, const std::string &payload, std::string *bytes) {
    const auto identity = SerializeRegistrationIdentity(authority);
    return !identity.empty() && Encode(std::vector<std::string>{"CYDIA-BROKER-1", identity, payload}, bytes);
}
bool BrokerRequestPayload(const Recovery::RequestAuthority &authority, const std::string &payload, std::string *bytes) {
    const auto identity = Recovery::SerializeRequestAuthority(authority);
    return !identity.empty() && Encode(std::vector<std::string>{"CYDIA-RECOVERY-BROKER-1", identity, payload}, bytes);
}
bool EncodeBrokerState(const DpkgState &state, std::string *bytes) {
    static const char *selections[] = {"unknown", "install", "hold", "deinstall", "purge"};
    static const char *statuses[] = {"not-installed", "config-files", "half-installed", "unpacked", "half-configured",
                                   "triggers-awaited", "triggers-pending", "installed"};
    std::string records, foreign;
    for (const auto &item : state.packages) {
        const auto &record = item.second;
        const unsigned selection = static_cast<unsigned>(record.selection), status = static_cast<unsigned>(record.status);
        if (selection >= 5 || status >= 8) return false;
        records += record.package.package + '\t' + record.package.version + '\t' + record.package.architecture + '\t' +
            selections[selection] + (record.reinstallRequired ? " reinstreq " : " ok ") + statuses[status] + '\t' +
            record.multiArch + '\t' + Words(record.triggersPending) + '\t' + Words(record.triggersAwaited) + '\n';
    }
    for (const auto &arch : state.registeredArchitectures) if (arch != state.nativeArchitecture) foreign += arch + '\n';
    DpkgState checked; std::string error;
    if (!ParseDpkgState(records, state.nativeArchitecture + '\n', foreign, state.packageStateIdentity, &checked, &error)) return false;
    return Encode(std::vector<std::string>{"CYDIA-DPKG-STATE-1", records, state.nativeArchitecture + '\n', foreign,
                                         state.packageStateIdentity}, bytes);
}
bool DecodeBrokerState(const std::string &bytes, DpkgState *state) {
    std::vector<std::string> fields; std::string error;
    return Decode(bytes, &fields) && fields.size() == 5 && fields[0] == "CYDIA-DPKG-STATE-1" &&
        ParseDpkgState(fields[1], fields[2], fields[3], fields[4], state, &error);
}
bool EncodeBrokerDpkg(const BrokerDpkgRequest &request, std::string *bytes) {
    if (!bytes) return false;
    Writer writer;
    if (!writer(std::string("CYDIA-BROKER-DPKG-1"), request.stateIdentity, request.action,
        request.arguments, request.archives, request.acceptedArchiveWarnings)) return false;
    *bytes = writer.result(); return true;
}
bool DecodeBrokerDpkg(const std::string &bytes, BrokerDpkgRequest *request) {
    if (!request || bytes.size() > MaximumMessageBytes) return false;
    BrokerDpkgRequest result; std::string tag; Reader reader(bytes);
    if (!reader(tag, result.stateIdentity, result.action, result.arguments, result.archives,
        result.acceptedArchiveWarnings) || !reader.complete() || tag != "CYDIA-BROKER-DPKG-1") return false;
    *request = std::move(result); return true;
}
}} // namespace CydiaAPT::Provider
