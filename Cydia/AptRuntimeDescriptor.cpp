/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRuntimeDescriptor.hpp"
#include <set>

namespace CydiaAPT {
namespace {
bool Failure(std::string *error, const char *code) { if (error != nullptr) *error = code; return false; }
bool Token(const std::string &value) {
    if (value.empty() || value.size() > 512) return false;
    for (unsigned char c : value)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '-' || c == '.' || c == '_' || c == ':' || c == '/' || c == '+' || c == '@' || c == '=')) return false;
    return true;
}
bool Session(const std::string &value) {
    if (value.size() < 32 || value.size() > 128 || value.size() % 2 != 0) return false;
    for (unsigned char c : value)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
    return true;
}
bool Text(const std::string &value, std::size_t maximum) {
    if (value.size() > maximum) return false;
    for (unsigned char c : value) if (c == 0 || c == 127 || (c < 32 && c != '\n' && c != '\t')) return false;
    return true;
}
bool Path(const std::string &value, bool optional = false) {
    if (value.empty()) return optional;
    if (value.size() > 4096 || value[0] != '/' || !Text(value, 4096) ||
        value.find_first_of("\n\t") != std::string::npos) return false;
    std::size_t start(1);
    while (start < value.size()) {
        const std::size_t slash(value.find('/', start));
        const std::string component(value.substr(start, slash == std::string::npos ? slash : slash - start));
        if (component.empty() || component == "." || component == "..") return false;
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return value.size() == 1 || value.back() != '/';
}
bool Architecture(const std::string &value) {
    if (value.empty() || value.size() > 128 || value[0] == '-' || value == "all" || value == "any" || value == "native") return false;
    for (unsigned char c : value)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    return true;
}
bool Architectures(const std::vector<std::string> &values, const std::string &native, bool nativeFirst) {
    if (values.empty() || values.size() > 128 || (nativeFirst && values.front() != native)) return false;
    std::set<std::string> unique;
    for (const auto &value : values)
        if ((!Architecture(value) && (nativeFirst || value != "all")) || !unique.insert(value).second) return false;
    return unique.count(native) != 0;
}
bool ErrorCode(const std::string &value) {
    if (value.empty() || value.size() > 96 || value[0] < 'a' || value[0] > 'z') return false;
    for (char c : value) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return false;
    return true;
}
bool Digest(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
}

bool SameRuntimeDescriptorBinding(const RuntimeDescriptorBinding &a, const RuntimeDescriptorBinding &b) {
    return a.providerIdentifier == b.providerIdentifier && a.session == b.session && a.libraryIdentity == b.libraryIdentity &&
        a.frontendIdentity == b.frontendIdentity && a.configurationIdentity == b.configurationIdentity &&
        a.policyIdentity == b.policyIdentity && a.methodsIdentity == b.methodsIdentity && a.packageStateIdentity == b.packageStateIdentity;
}

bool ValidateRuntimeDescriptor(const RuntimeDescriptor &d, const RuntimeDescriptorBinding &verified, std::string *error) {
    if (d.origin != RuntimeDescriptorOrigin::External && d.origin != RuntimeDescriptorOrigin::RecoveryWorker)
        return Failure(error, "runtime_descriptor_not_remote");
    const auto &b(d.binding);
    if ((d.origin == RuntimeDescriptorOrigin::RecoveryWorker) != (b.providerIdentifier == RecoveryRuntimeProviderIdentifier))
        return Failure(error, "runtime_descriptor_origin_mismatch");
    if (!Token(b.providerIdentifier) || !Session(b.session) || !Token(b.libraryIdentity) || !Token(b.frontendIdentity) ||
        !Token(b.configurationIdentity) || !Token(b.policyIdentity) || !Token(b.methodsIdentity) || !Token(b.packageStateIdentity))
        return Failure(error, "runtime_descriptor_invalid_binding");
    if (d.origin == RuntimeDescriptorOrigin::RecoveryWorker &&
        (!Digest(b.libraryIdentity) || !Digest(b.frontendIdentity) || !Digest(b.configurationIdentity) ||
         !Digest(b.policyIdentity) || !Digest(b.methodsIdentity) || !Digest(b.packageStateIdentity)))
        return Failure(error, "runtime_descriptor_invalid_binding");
    if (!SameRuntimeDescriptorBinding(b, verified)) return Failure(error, "runtime_descriptor_binding_mismatch");
    if (!Architecture(d.architecture) || !Architectures(d.registeredArchitectures, d.architecture, true) ||
        !Architectures(d.acquisitionArchitectures, d.architecture, false)) return Failure(error, "runtime_descriptor_invalid_architectures");
    for (const std::string *path : {&d.dpkgExecutablePath, &d.dpkgQueryExecutablePath, &d.dpkgDebExecutablePath,
            &d.privilegedHelperPath, &d.dpkgAdminDirectory, &d.dpkgRootDirectory, &d.packageInstallPrefix,
            &d.dpkgChrootDirectory, &d.extendedStatesPath, &d.methodsDirectory, &d.listsDirectory})
        if (!Path(*path)) return Failure(error, "runtime_descriptor_invalid_path");
    for (const std::string *path : {&d.sourceListPath, &d.sourcePartsDirectory, &d.managedSourceListPath,
            &d.gpgExecutablePath, &d.aptConfigOverride, &d.trustedKeyringPath, &d.trustedKeyringPartsDirectory})
        if (!Path(*path, true)) return Failure(error, "runtime_descriptor_invalid_path");
    if (!d.managedSourceListPath.empty()) {
        const auto slash(d.managedSourceListPath.rfind('/'));
        const std::string leaf(d.managedSourceListPath.substr(slash + 1));
        const std::string parent(slash == 0 ? "/" : d.managedSourceListPath.substr(0, slash));
        if (d.sourcePartsDirectory.empty() || parent != d.sourcePartsDirectory ||
            leaf.size() <= 5 || leaf.compare(leaf.size() - 5, 5, ".list") != 0 ||
            leaf.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.") != std::string::npos)
            return Failure(error, "runtime_descriptor_invalid_managed_source");
    }
    if (d.dpkgOptions.size() > 4096) return Failure(error, "runtime_descriptor_invalid_options");
    for (const auto &option : d.dpkgOptions)
        if (option.empty() || !Text(option, 16384)) return Failure(error, "runtime_descriptor_invalid_options");
    if (d.repositorySecurityMode != RepositorySecurityMode::Allow && d.repositorySecurityMode != RepositorySecurityMode::Warning &&
        d.repositorySecurityMode != RepositorySecurityMode::Error && d.repositorySecurityMode != RepositorySecurityMode::Distribution)
        return Failure(error, "runtime_descriptor_invalid_policy");
    if (!Text(d.runtimeError, 16384) || (!d.runtimeErrorCode.empty() && !ErrorCode(d.runtimeErrorCode)) ||
        (d.mutationEnvironmentValid && (!d.runtimeError.empty() || !d.runtimeErrorCode.empty())) ||
        (!d.mutationEnvironmentValid && d.runtimeErrorCode.empty())) return Failure(error, "runtime_descriptor_invalid_status");
    if (error != nullptr) error->clear();
    return true;
}
} // namespace CydiaAPT
