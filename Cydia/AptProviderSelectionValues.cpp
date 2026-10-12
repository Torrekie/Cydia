/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderSelection.hpp"
#include <sstream>
#include <utility>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
const std::size_t RegistrationLimit = 1024 * 1024;
bool Fields(const std::string &bytes, std::vector<std::string> *fields, std::size_t maximum = 4096) {
    if (!fields || bytes.size() > RegistrationLimit) return false;
    fields->clear(); std::size_t cursor = 0;
    while (cursor < bytes.size()) {
        std::size_t length = 0, digits = 0;
        while (cursor < bytes.size() && bytes[cursor] >= '0' && bytes[cursor] <= '9') {
            const unsigned digit = bytes[cursor++] - '0';
            if (++digits > 8 || length > (RegistrationLimit - digit) / 10) return false;
            length = length * 10 + digit;
        }
        if (!digits || cursor == bytes.size() || bytes[cursor++] != ':' || length >= bytes.size() - cursor) return false;
        fields->push_back(bytes.substr(cursor, length)); cursor += length;
        if (bytes[cursor++] != ',' || fields->size() > maximum) return false;
    }
    return true;
}
bool Path(const std::string &path, bool optional = false) {
    if (path.empty()) return optional;
    if (path.front() != '/' || path.size() > 4096 || (path.size() > 1 && path.back() == '/')) return false;
    for (unsigned char c : path) if (c < 32 || c == 127) return false;
    std::size_t start = 1;
    while (start < path.size()) {
        const auto slash = path.find('/', start);
        const auto part = path.substr(start, slash == std::string::npos ? slash : slash - start);
        if (part.empty() || part == "." || part == "..") return false;
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return true;
}
bool SearchPath(const std::string &path) {
    std::istringstream fields(path); std::string field; unsigned count = 0;
    if (path.empty() || path.back() == ':') return false;
    while (std::getline(fields, field, ':')) if (++count > 128 || !Path(field)) return false;
    return count != 0;
}
bool IdentityValid(const RegistrationIdentity &identity) {
    return Path(identity.registrationPath) && ValidIdentityToken(identity.providerIdentifier) &&
        ValidIdentityToken(identity.configurationIdentity) && ValidIdentityToken(identity.policyIdentity) &&
        ValidIdentityToken(identity.methodsIdentity) && ValidIdentityToken(identity.libraryIdentity) && ValidIdentityToken(identity.frontendIdentity);
}
RuntimeDescriptorBinding BindingFor(const RegistrationIdentity &identity, const std::string &state) {
    RuntimeDescriptorBinding binding;
    binding.providerIdentifier = identity.providerIdentifier; binding.libraryIdentity = identity.libraryIdentity;
    binding.frontendIdentity = identity.frontendIdentity; binding.configurationIdentity = identity.configurationIdentity;
    binding.policyIdentity = identity.policyIdentity; binding.methodsIdentity = identity.methodsIdentity;
    binding.packageStateIdentity = state; return binding;
}
std::string RuntimeBytes(const RuntimeDescriptor &d) {
    return P::SerializeFields({d.architecture, P::SerializeFields(d.registeredArchitectures), P::SerializeFields(d.acquisitionArchitectures),
        d.sourceListPath, d.sourcePartsDirectory, d.managedSourceListPath, d.dpkgExecutablePath, d.dpkgQueryExecutablePath,
        d.dpkgDebExecutablePath, d.gpgExecutablePath, d.aptConfigOverride, d.privilegedHelperPath, d.dpkgAdminDirectory,
        d.dpkgRootDirectory, d.packageInstallPrefix, d.dpkgChrootDirectory, P::SerializeFields(d.dpkgOptions), d.extendedStatesPath,
        d.methodsDirectory, d.listsDirectory, d.trustedKeyringPath, d.trustedKeyringPartsDirectory,
        RepositorySecurityModeName(d.repositorySecurityMode), d.mutationEnvironmentValid ? "1" : "0", d.runtimeErrorCode, d.runtimeError});
}
bool RuntimeFromBytes(const std::string &bytes, RuntimeDescriptor *d) {
    std::vector<std::string> f; P::Error ignored;
    if (!d || !P::ParseFields(bytes, 26, &f, &ignored) || !Fields(f[1], &d->registeredArchitectures, 128) ||
        !Fields(f[2], &d->acquisitionArchitectures, 128) || !Fields(f[16], &d->dpkgOptions) ||
        !IsRepositorySecurityModeName(f[22]) || (f[23] != "1" && f[23] != "0")) return false;
    d->architecture = f[0]; d->sourceListPath = f[3]; d->sourcePartsDirectory = f[4]; d->managedSourceListPath = f[5];
    d->dpkgExecutablePath = f[6]; d->dpkgQueryExecutablePath = f[7]; d->dpkgDebExecutablePath = f[8]; d->gpgExecutablePath = f[9];
    d->aptConfigOverride = f[10]; d->privilegedHelperPath = f[11]; d->dpkgAdminDirectory = f[12]; d->dpkgRootDirectory = f[13];
    d->packageInstallPrefix = f[14]; d->dpkgChrootDirectory = f[15]; d->extendedStatesPath = f[17]; d->methodsDirectory = f[18];
    d->listsDirectory = f[19]; d->trustedKeyringPath = f[20]; d->trustedKeyringPartsDirectory = f[21];
    d->repositorySecurityMode = RepositorySecurityModeFromString(f[22]); d->mutationEnvironmentValid = f[23] == "1";
    d->runtimeErrorCode = f[24]; d->runtimeError = f[25]; return true;
}
bool SnapshotShapeValid(const RegisteredProviderSnapshot &snapshot) {
    if (!IdentityValid(snapshot.identity) || !Path(snapshot.executable) || !SearchPath(snapshot.executableSearchPath) ||
        !ValidIdentityToken(snapshot.packageStateIdentity)) return false;
    RuntimeDescriptor candidate(snapshot.runtime);
    candidate.binding = BindingFor(snapshot.identity, snapshot.packageStateIdentity);
    // Shape validation before a live session exists, never an adopted nonce.
    candidate.binding.session.assign(64, '0');
    return ValidateRuntimeDescriptor(candidate, candidate.binding);
}
} // namespace

bool ValidateRegisteredProviderSnapshot(const RegisteredProviderSnapshot &snapshot) {
    return SnapshotShapeValid(snapshot);
}
bool SameRegistrationIdentity(const RegistrationIdentity &a, const RegistrationIdentity &b) {
    return SerializeRegistrationIdentity(a) == SerializeRegistrationIdentity(b);
}
std::string SerializeRegistrationIdentity(const RegistrationIdentity &i) {
    return P::SerializeFields({i.registrationPath, i.providerIdentifier, i.configurationIdentity, i.policyIdentity,
        i.methodsIdentity, i.libraryIdentity, i.frontendIdentity});
}
bool ParseRegistrationIdentity(const std::string &bytes, RegistrationIdentity *identity) {
    std::vector<std::string> f; P::Error error;
    if (!identity || !P::ParseFields(bytes, 7, &f, &error)) return false;
    RegistrationIdentity i{f[0], f[1], f[2], f[3], f[4], f[5], f[6]};
    if (!IdentityValid(i)) return false;
    *identity = std::move(i); return true;
}
RegisteredProviderSnapshot MakeRegisteredProviderSnapshot(const RegisteredProviderEnvironment &resolved, const std::string &state) {
    RegisteredProviderSnapshot snapshot;
    snapshot.identity = resolved.identity; snapshot.executable = resolved.executable; snapshot.executableSearchPath = resolved.executableSearchPath;
    snapshot.packageStateIdentity = state; snapshot.runtime = resolved.runtime;
    snapshot.runtime.binding = BindingFor(snapshot.identity, state); return snapshot;
}
std::string SerializeRegisteredProviderSnapshot(const RegisteredProviderSnapshot &snapshot) {
    if (!ValidateRegisteredProviderSnapshot(snapshot)) return {};
    return P::SerializeFields({SerializeRegistrationIdentity(snapshot.identity), snapshot.executable, snapshot.executableSearchPath,
        snapshot.packageStateIdentity, RuntimeBytes(snapshot.runtime)});
}
bool ParseRegisteredProviderSnapshot(const std::string &bytes, RegisteredProviderSnapshot *snapshot) {
    if (!snapshot) return false;
    RegisteredProviderSnapshot value; std::vector<std::string> f; P::Error error;
    if (!P::ParseFields(bytes, 5, &f, &error) || !ParseRegistrationIdentity(f[0], &value.identity) || !RuntimeFromBytes(f[4], &value.runtime)) return false;
    value.executable = f[1]; value.executableSearchPath = f[2]; value.packageStateIdentity = f[3];
    value.runtime.binding = BindingFor(value.identity, value.packageStateIdentity);
    if (!ValidateRegisteredProviderSnapshot(value)) return false;
    *snapshot = std::move(value); return true;
}

}} // namespace CydiaAPT::Provider
