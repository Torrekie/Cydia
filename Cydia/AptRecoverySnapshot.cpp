/* Bounded, value-only recovery launch capsule. No APT or helper execution.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoverySnapshot.hpp"
#include <set>
#include <sstream>
#include <utility>

namespace CydiaAPT { namespace Recovery {
namespace {
namespace Wire = CydiaAPT::Provider;
bool Digest(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
bool IdentityValid(const Identity &v) {
    return Digest(v.configuration) && Digest(v.policy) && Digest(v.methods) &&
        Digest(v.libraries) && Digest(v.frontend) && Digest(v.dependencies);
}
bool Text(const std::string &value, std::size_t limit, bool multiline = false) {
    if (value.size() > limit) return false;
    for (unsigned char c : value) if (c == 127 || (c < 32 && (!multiline || (c != '\n' && c != '\t')))) return false;
    return true;
}
bool Path(const std::string &value, bool optional = false) {
    if (value.empty()) return optional;
    if (value.front() != '/' || !Text(value, 4096) || (value.size() > 1 && value.back() == '/')) return false;
    std::size_t start = 1;
    while (start < value.size()) {
        const auto end = value.find('/', start), length = end == std::string::npos ? end : end - start;
        const auto part = value.substr(start, length);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return true;
}
bool SearchPath(const std::string &value, unsigned maximumEntries = 128) {
    if (value.empty() || value.back() == ':' || value.size() > maximumEntries * 4097) return false;
    std::istringstream fields(value); std::string field; unsigned count = 0;
    while (std::getline(fields, field, ':')) if (++count > maximumEntries || !Path(field)) return false;
    return count != 0;
}
template<class Archive, class Value> bool IdentityFields(Archive &a, Value &v) {
    return a(v.configuration, v.policy, v.methods, v.libraries, v.frontend, v.dependencies);
}
template<class Archive, class Value> bool PreferenceFields(Archive &a, Value &v) {
    return a(v.aptConfigOverride, v.securityPreference, v.translation, v.languages, v.maxParallel, v.forceEssential);
}
template<class Archive, class Value> bool RuntimeFields(Archive &a, Value &v) {
    return a(v.architecture, v.registeredArchitectures, v.acquisitionArchitectures,
        v.sourceListPath, v.sourcePartsDirectory, v.managedSourceListPath,
        v.dpkgExecutablePath, v.dpkgQueryExecutablePath, v.dpkgDebExecutablePath,
        v.gpgExecutablePath, v.aptConfigOverride, v.privilegedHelperPath, v.dpkgAdminDirectory,
        v.dpkgRootDirectory, v.packageInstallPrefix, v.dpkgChrootDirectory, v.dpkgOptions,
        v.extendedStatesPath, v.methodsDirectory, v.listsDirectory, v.trustedKeyringPath,
        v.trustedKeyringPartsDirectory, v.repositorySecurityMode, v.mutationEnvironmentValid,
        v.runtimeErrorCode, v.runtimeError);
}
template<class Archive, class Value> bool SnapshotFields(Archive &a, Value &v) {
    return IdentityFields(a, v.identity) && RuntimeFields(a, v.runtime) &&
        a(v.startup, v.executable, v.executableSearchPath, v.acquisitionSearchPath, v.cacheDirectory, v.archivesDirectory,
          v.logDirectory, v.configuration, v.packageStateIdentity, v.securityPreferenceExplicit, v.configuredSecurity);
}
bool RuntimeShape(const Snapshot &v) {
    if (v.runtime.origin != RuntimeDescriptorOrigin::Embedded || !v.runtime.mutationEnvironmentValid ||
        !SameRuntimeDescriptorBinding(v.runtime.binding, RuntimeDescriptorBinding())) return false;
    // Reuse the descriptor's path/architecture validation without publishing a
    // fabricated live binding or calling the runtime adoption interface.
    RuntimeDescriptor shape(v.runtime); shape.origin = RuntimeDescriptorOrigin::RecoveryWorker;
    auto &b = shape.binding;
    b.providerIdentifier = ProviderIdentifier(); b.session.assign(64, '0');
    b.configurationIdentity = v.identity.configuration; b.policyIdentity = v.identity.policy;
    b.methodsIdentity = v.identity.methods; b.libraryIdentity = v.identity.libraries;
    b.frontendIdentity = v.identity.frontend; b.packageStateIdentity = v.packageStateIdentity;
    return ValidateRuntimeDescriptor(shape, b);
}
bool StartupShape(const Snapshot &v) {
    const auto &s = v.startup;
    for (const auto *path : {&s.aptConfigDirectory, &s.methodsDirectory, &s.cacheDirectory, &s.stateDirectory,
        &s.listsDirectory, &s.logDirectory, &s.dpkgStatusPath, &s.bootstrapExtendedStatesPath, &s.dpkgPath,
        &s.nativeDpkgPath, &s.packageInstallPrefix, &s.privateRuntimeConfigurationPath, &s.helperPath, &s.dpkgDataDirectory})
        if (!Path(*path)) return false;
    return Wire::ValidIdentityToken(s.architecture) && SearchPath(s.dpkgExecutableSearchPath) &&
        s.helperPath == v.runtime.privilegedHelperPath && s.dpkgPath == s.helperPath &&
        s.repositorySecurityMode == v.runtime.repositorySecurityMode && ValidatePreferences(AuthorityRequest(v).preferences);
}
} // namespace

const char *ProviderIdentifier() { return RecoveryRuntimeProviderIdentifier; }
bool ValidatePreferences(const Preferences &v) {
    return Path(v.aptConfigOverride, true) && (v.securityPreference.empty() || IsRepositorySecurityModeName(v.securityPreference)) &&
        Text(v.translation, 4096) && Text(v.languages, 4096) && v.maxParallel >= 0 && v.maxParallel <= 1024;
}
std::string SerializePreferences(const Preferences &v) {
    Wire::Writer w;
    return ValidatePreferences(v) && w(std::string("CYDIA-RECOVERY-PREFERENCES-1")) && PreferenceFields(w, v) ? w.result() : std::string();
}
bool ParsePreferences(const std::string &bytes, Preferences *result) {
    if (!result || bytes.size() > 16384) return false;
    Wire::Reader r(bytes); std::string tag; Preferences v;
    if (!r(tag) || tag != "CYDIA-RECOVERY-PREFERENCES-1" || !PreferenceFields(r, v) || !r.complete() || !ValidatePreferences(v)) return false;
    *result = std::move(v); return true;
}
std::string SerializeIdentity(const Identity &v) {
    Wire::Writer w; return IdentityValid(v) && w(std::string("CYDIA-RECOVERY-IDENTITY-1")) && IdentityFields(w, v) ? w.result() : std::string();
}
bool ParseIdentity(const std::string &bytes, Identity *result) {
    if (!result || bytes.size() > 1024) return false;
    Wire::Reader r(bytes); std::string tag; Identity v;
    if (!r(tag) || tag != "CYDIA-RECOVERY-IDENTITY-1" || !IdentityFields(r, v) || !r.complete() || !IdentityValid(v)) return false;
    *result = std::move(v); return true;
}
std::string SerializeRequestAuthority(const RequestAuthority &v) {
    const auto identity = SerializeIdentity(v.identity), preferences = SerializePreferences(v.preferences);
    std::string result;
    return !identity.empty() && !preferences.empty() &&
        Wire::Encode(std::vector<std::string>{"CYDIA-RECOVERY-AUTHORITY-1", identity, preferences}, &result) ? result : std::string();
}
bool ParseRequestAuthority(const std::string &bytes, RequestAuthority *result) {
    if (!result || bytes.size() > 32768) return false;
    std::vector<std::string> f; RequestAuthority v;
    if (!Wire::Decode(bytes, &f) || f.size() != 3 || f[0] != "CYDIA-RECOVERY-AUTHORITY-1" ||
        !ParseIdentity(f[1], &v.identity) || !ParsePreferences(f[2], &v.preferences)) return false;
    *result = std::move(v); return true;
}
RequestAuthority AuthorityRequest(const Snapshot &v) {
    RequestAuthority result; result.identity = v.identity;
    result.preferences.aptConfigOverride = v.runtime.aptConfigOverride;
    if (v.securityPreferenceExplicit) result.preferences.securityPreference = RepositorySecurityModeName(v.runtime.repositorySecurityMode);
    result.preferences.translation = v.startup.translation; result.preferences.languages = v.startup.languages;
    result.preferences.maxParallel = v.startup.maxParallel; result.preferences.forceEssential = v.startup.forceEssential;
    return result;
}
Provider::Environment SnapshotEnvironment(const Snapshot &v) {
    Provider::Environment e; const auto &d = v.runtime;
    e.paths.aptConfigOverride = d.aptConfigOverride; e.paths.dpkgRoot = d.dpkgRootDirectory; e.paths.dpkgAdmin = d.dpkgAdminDirectory;
    e.paths.dpkg = d.dpkgExecutablePath; e.paths.dpkgQuery = d.dpkgQueryExecutablePath; e.paths.dpkgDeb = d.dpkgDebExecutablePath;
    e.paths.sourceList = d.sourceListPath; e.paths.sourceParts = d.sourcePartsDirectory;
    e.configurationIdentity = v.identity.configuration; e.policyIdentity = v.identity.policy; e.methodsIdentity = v.identity.methods;
    e.packageStateIdentity = v.packageStateIdentity; e.nativeArchitecture = d.architecture;
    e.registeredArchitectures = d.registeredArchitectures; e.acquisitionArchitectures = d.acquisitionArchitectures; return e;
}
bool ValidateSnapshot(const Snapshot &v) {
    if (!IdentityValid(v.identity) || !Digest(v.packageStateIdentity) || !RuntimeShape(v) || !StartupShape(v) ||
        !Path(v.executable) || !SearchPath(v.executableSearchPath) || !Path(v.cacheDirectory) ||
        !SearchPath(v.acquisitionSearchPath, 129) ||
        v.acquisitionSearchPath != v.executable.substr(0, v.executable.rfind('/') + 1) + "recovery-bin:" + v.executableSearchPath ||
        !Path(v.archivesDirectory) || !Path(v.logDirectory) || v.configuration.empty() ||
        !Text(v.configuration, MaximumConfigurationBytes, true) ||
        (!v.securityPreferenceExplicit && v.runtime.repositorySecurityMode != DefaultRepositorySecurityMode()) ||
        v.components.empty() || v.components.size() > 512 || v.configuredSecurity.size() > 5) return false;
    const std::set<std::string> keys{"Acquire::AllowInsecureRepositories", "Acquire::AllowWeakRepositories",
        "Acquire::AllowDowngradeToInsecureRepositories", "Acquire::Check-Valid-Until", "APT::Get::AllowUnauthenticated"};
    for (const auto &setting : v.configuredSecurity)
        if (!keys.count(setting.first) || !Text(setting.second, 16384)) return false;
    std::map<std::string, bool> files; std::size_t total = 0;
    for (const auto &file : v.components) {
        total += file.path.size() + file.sha256.size() + 1;
        if (!Path(file.path) || !Digest(file.sha256) || !files.emplace(file.path, file.executable).second || total > 1024 * 1024) return false;
    }
    for (const auto *path : {&v.executable, &v.runtime.privilegedHelperPath, &v.runtime.dpkgExecutablePath,
        &v.runtime.dpkgQueryExecutablePath, &v.runtime.dpkgDebExecutablePath}) {
        const auto found = files.find(*path); if (found == files.end() || !found->second) return false;
    }
    return true;
}
bool MakeSnapshot(const Authority &authority, const std::string &state, Snapshot *result) {
    if (!result || !authority.unresolvedFields.empty()) return false;
    Snapshot v; v.identity = authority.identity; v.runtime = authority.runtime; v.startup = authority.startup;
    v.executable = authority.executable; v.executableSearchPath = authority.executableSearchPath;
    v.acquisitionSearchPath = authority.acquisitionSearchPath;
    v.cacheDirectory = authority.cacheDirectory; v.archivesDirectory = authority.archivesDirectory; v.logDirectory = authority.logDirectory;
    v.configuration = authority.configuration; v.packageStateIdentity = state;
    v.securityPreferenceExplicit = authority.securityPreferenceExplicit; v.configuredSecurity = authority.configuredSecurity; v.components = authority.components;
    if (!ValidateSnapshot(v)) return false;
    *result = std::move(v); return true;
}
std::string SerializeSnapshot(const Snapshot &v) {
    Wire::Writer w;
    if (!ValidateSnapshot(v) || !w(std::string("CYDIA-RECOVERY-SNAPSHOT-1")) || !SnapshotFields(w, v) ||
        !w(static_cast<std::uint64_t>(v.components.size()))) return {};
    for (const auto &file : v.components) if (!w(file.path, file.sha256, file.executable)) return {};
    return w.result().size() <= MaximumSnapshotBytes ? w.result() : std::string();
}
bool ParseSnapshot(const std::string &bytes, Snapshot *result) {
    if (!result || bytes.empty() || bytes.size() > MaximumSnapshotBytes) return false;
    Snapshot v; v.runtime.origin = RuntimeDescriptorOrigin::Embedded;
    Wire::Reader r(bytes); std::string tag; std::uint64_t count = 0;
    if (!r(tag) || tag != "CYDIA-RECOVERY-SNAPSHOT-1" || !SnapshotFields(r, v) || !r(count) || count > 512) return false;
    for (std::uint64_t i = 0; i < count; ++i) {
        Component file; if (!r(file.path, file.sha256, file.executable)) return false;
        v.components.push_back(std::move(file));
    }
    if (!r.complete() || !ValidateSnapshot(v)) return false;
    *result = std::move(v); return true;
}
}} // namespace CydiaAPT::Recovery
