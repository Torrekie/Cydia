/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderSelection.hpp"
#include "Cydia/DpkgAdminAccess.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
const std::size_t RegistrationLimit = 1024 * 1024;
const char *const RegistrationVersion = "CYDIA-APT-PROVIDER-1";
bool Fail(P::Error *error, const char *code, const char *message) {
    if (error) { error->code = code; error->message = message; } return false;
}
std::string StableCode(const std::string &code, const char *fallback) {
    if (code.empty() || code.size() > 96 || code.front() < 'a' || code.front() > 'z') return fallback;
    for (char c : code) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return fallback;
    return code;
}
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
bool Architecture(const std::string &value) {
    if (value.empty() || value.size() > 128 || value.front() == '-' || value == "all" || value == "any" || value == "native") return false;
    for (char c : value) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    return true;
}
std::string Digest(const char *domain, const std::vector<std::string> &fields) {
    Hashes hashes(Hashes::SHA256SUM);
    const std::string bytes(P::SerializeFields(fields));
    if (!hashes.Add(domain, std::strlen(domain)) || !hashes.Add(bytes.data(), bytes.size())) return {};
    return hashes.GetHashString(Hashes::SHA256SUM).HashValue();
}
std::string ProviderEvidenceBytes(const P::Evidence &evidence) {
    // These are protected provider/configuration inputs, never delegated
    // source data. Their fingerprint must not depend on the caller's groups.
    P::Evidence value(evidence);
    value.sourceReaderUID = 0; value.sourceReaderGID = 0;
    value.sourceReaderGroups.valid = false; value.sourceReaderGroups.values.clear();
    return P::SerializeSnapshotEvidence(value);
}
struct ComponentEvidence { P::Evidence identity; bool executable; };
bool FileFingerprint(const std::string &path, bool executable, std::string *fingerprint, P::Error *error,
    const std::function<bool()> &stopped, std::size_t *totalBytes, std::vector<ComponentEvidence> *components) {
    if (stopped()) return Fail(error, "provider_capture_cancelled", "Provider verification was cancelled or timed out.");
    if (!P::ValidateRootOwnedPath(path, false, executable, error)) return false;
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return Fail(error, "provider_component_unreadable", "Cannot read a registered provider component.");
    struct stat before = {}, after = {}, current = {}; Hashes hash(Hashes::SHA256SUM);
    bool good = fstat(fd, &before) == 0 && S_ISREG(before.st_mode) && before.st_uid == 0 &&
        (before.st_mode & (S_IWGRP | S_IWOTH)) == 0 && before.st_size >= 0 && before.st_size <= 128 * 1024 * 1024;
    char buffer[32768]; std::size_t count = 0;
    while (good) {
        if (stopped()) { close(fd); return Fail(error, "provider_capture_cancelled", "Provider verification was cancelled or timed out."); }
        const ssize_t size = read(fd, buffer, sizeof(buffer));
        if (size < 0 && errno == EINTR) continue;
        if (size < 0) { good = false; break; }
        if (size == 0) break;
        count += size; *totalBytes += size;
        if (count > 128 * 1024 * 1024 || *totalBytes > 256 * 1024 * 1024 || !hash.Add(buffer, size)) { good = false; break; }
    }
    good = good && fstat(fd, &after) == 0 && stat(path.c_str(), &current) == 0 && count == static_cast<std::size_t>(before.st_size);
    close(fd);
    P::Evidence a{}, b{}, c{}; a.path = b.path = c.path = path; a.identity = before; b.identity = after; c.identity = current;
    if (!good || ProviderEvidenceBytes(a) != ProviderEvidenceBytes(b) ||
        ProviderEvidenceBytes(a) != ProviderEvidenceBytes(c) || !P::ValidateRootOwnedPath(path, false, executable, error))
        return Fail(error, "provider_component_changed", "A registered provider component changed while being read.");
    *fingerprint = P::SerializeFields({path, ProviderEvidenceBytes(a), hash.GetHashString(Hashes::SHA256SUM).HashValue()});
    components->push_back({a, executable});
    return true;
}
struct Registration {
    std::string identifier, executable, executableSearchPath, preferences, preferencesParts;
    RuntimeDescriptor runtime;
    std::vector<std::string> libraries, frontends, configFiles, configDirectories, optionalConfigFiles, optionalConfigDirectories, policyFiles, policyDirectories;
};
bool ParseRegistration(const std::string &bytes, Registration *registration, P::Error *error) {
    std::vector<std::string> fields;
    if (!Fields(bytes, &fields, 128) || fields.empty() || fields[0] != RegistrationVersion || fields.size() % 2 != 1)
        return Fail(error, "provider_registration_invalid", "The provider registration format is unsupported.");
    std::map<std::string, std::string> values;
    for (std::size_t i = 1; i < fields.size(); i += 2)
        if (!values.insert({fields[i], fields[i + 1]}).second) return Fail(error, "provider_registration_invalid", "The provider registration contains duplicate fields.");
    Registration &r(*registration); RuntimeDescriptor &d(r.runtime);
    const auto take = [&](const char *key, std::string *value) { auto found = values.find(key); if (found == values.end()) return false;
        *value = found->second; values.erase(found); return true; };
    const auto list = [&](const char *key, std::vector<std::string> *value) { std::string data; return take(key, &data) && Fields(data, value); };
    bool good = take("Identifier", &r.identifier) && take("Adapter", &r.executable) && take("ExecutableSearchPath", &r.executableSearchPath) &&
        take("SourceList", &d.sourceListPath) && take("SourceParts", &d.sourcePartsDirectory) && take("ManagedSourceList", &d.managedSourceListPath) &&
        take("Dpkg", &d.dpkgExecutablePath) && take("DpkgQuery", &d.dpkgQueryExecutablePath) && take("DpkgDeb", &d.dpkgDebExecutablePath) &&
        take("Gpg", &d.gpgExecutablePath) && take("AptConfigOverride", &d.aptConfigOverride) && take("DpkgRoot", &d.dpkgRootDirectory) &&
        take("DpkgAdmin", &d.dpkgAdminDirectory) && take("PackageInstallPrefix", &d.packageInstallPrefix) && take("DpkgChroot", &d.dpkgChrootDirectory) &&
        take("ExtendedStates", &d.extendedStatesPath) && take("Methods", &d.methodsDirectory) && take("Lists", &d.listsDirectory) &&
        take("Trusted", &d.trustedKeyringPath) && take("TrustedParts", &d.trustedKeyringPartsDirectory) && take("Preferences", &r.preferences) &&
        take("PreferencesParts", &r.preferencesParts) && list("DpkgOptions", &d.dpkgOptions) && list("AcquisitionArchitectures", &d.acquisitionArchitectures) &&
        list("Libraries", &r.libraries) && list("Frontends", &r.frontends) && list("ConfigurationFiles", &r.configFiles) &&
        list("ConfigurationDirectories", &r.configDirectories) && list("OptionalConfigurationFiles", &r.optionalConfigFiles) &&
        list("OptionalConfigurationDirectories", &r.optionalConfigDirectories) && list("PolicyFiles", &r.policyFiles) && list("PolicyDirectories", &r.policyDirectories);
    if (!good || !values.empty() || !ValidIdentityToken(r.identifier) || !Path(r.executable) || !SearchPath(r.executableSearchPath) ||
        !Path(r.preferences, true) || !Path(r.preferencesParts, true) || r.libraries.empty() || r.frontends.empty())
        return Fail(error, "provider_registration_invalid", "The provider registration is incomplete or invalid.");
    for (const auto *paths : {&r.libraries, &r.frontends, &r.configFiles, &r.configDirectories, &r.optionalConfigFiles,
        &r.optionalConfigDirectories, &r.policyFiles, &r.policyDirectories}) {
        std::set<std::string> unique;
        for (const auto &path : *paths) if (!Path(path) || !unique.insert(path).second)
            return Fail(error, "provider_registration_invalid", "The provider input paths are invalid or duplicated.");
    }
    return true;
}
struct GraphCapture {
    std::vector<P::Evidence> evidence;
    std::set<std::string> seen;
    std::size_t bytes = 0;
    std::function<bool()> stopped;
    bool add(const std::string &path, bool directory, bool optional, P::Error *error, unsigned depth = 0) {
        if (stopped && stopped()) return Fail(error, "provider_capture_cancelled", "Provider verification was cancelled or timed out.");
        if (depth > 16 || evidence.size() >= 4096) return Fail(error, "provider_inputs_too_large", "Provider inputs exceed the supported limits.");
        char *canonical = realpath(path.c_str(), nullptr);
        const std::string identity(canonical == nullptr ? path : canonical); std::free(canonical);
        const bool expand = seen.insert(identity).second;
        P::Evidence input;
        if (!P::CaptureEvidence(path, directory, optional, &input, error)) return false;
        bytes += input.bytes.size();
        if (bytes > 32 * 1024 * 1024) return Fail(error, "provider_inputs_too_large", "Provider configuration is too large.");
        evidence.push_back(input);
        if (directory && !input.absent && expand) for (const auto &entry : input.entries) {
            const std::string child(path + (path == "/" ? "" : "/") + entry); struct stat st;
            if (stat(child.c_str(), &st) != 0 || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) ||
                !add(child, S_ISDIR(st.st_mode), false, error, depth + 1)) return false;
        }
        return true;
    }
};
bool CaptureGraph(const std::vector<std::string> &files, const std::vector<std::string> &directories,
    bool optional, GraphCapture *graph, P::Error *error) {
    for (const auto &path : files) if (!graph->add(path, false, optional, error)) return false;
    for (const auto &path : directories) if (!graph->add(path, true, optional, error)) return false;
    return true;
}
std::string GraphIdentity(const char *domain, const GraphCapture &graph, const std::vector<std::string> &prefix = {}) {
    std::vector<std::string> fields(prefix);
    for (const auto &input : graph.evidence) fields.push_back(ProviderEvidenceBytes(input));
    return Digest(domain, fields);
}
bool ComponentsIdentity(const char *domain, const std::vector<std::string> &paths, bool executable,
    std::string *identity, P::Error *error, const std::function<bool()> &stopped, std::size_t *totalBytes,
    std::vector<ComponentEvidence> *components) {
    if (paths.size() > 256) return Fail(error, "provider_inputs_too_large", "Too many provider components were declared.");
    std::vector<std::string> fields;
    for (const auto &path : paths) { std::string bytes;
        if (!FileFingerprint(path, executable, &bytes, error, stopped, totalBytes, components)) return false;
        fields.push_back(bytes); }
    *identity = Digest(domain, fields); return !identity->empty();
}
bool QueryArchitectures(RuntimeDescriptor *runtime, unsigned timeout, const std::function<bool()> &cancelled, P::Error *error) {
    CydiaRuntime::Dpkg::Runner runner(runtime->dpkgExecutablePath); std::string bytes;
    std::vector<std::string> args{"--root=" + runtime->dpkgRootDirectory, "--admindir=" + runtime->dpkgAdminDirectory, "--print-architecture"};
    if (!runner.RunAndCaptureBounded(args, &bytes, 32768, timeout, cancelled).succeeded())
        return Fail(error, "provider_architecture_query_failed", "Cannot query the registered dpkg architecture.");
    while (!bytes.empty() && (bytes.back() == '\n' || bytes.back() == '\r')) bytes.pop_back();
    if (!Architecture(bytes)) return Fail(error, "provider_architecture_query_failed", "The registered dpkg returned an invalid architecture.");
    runtime->architecture = bytes; runtime->registeredArchitectures = {bytes}; args.back() = "--print-foreign-architectures";
    if (!runner.RunAndCaptureBounded(args, &bytes, 32768, timeout, cancelled).succeeded())
        return Fail(error, "provider_architecture_query_failed", "Cannot query the registered dpkg foreign architectures.");
    std::istringstream lines(bytes); std::string architecture; std::set<std::string> seen{runtime->architecture};
    while (std::getline(lines, architecture)) {
        if (!architecture.empty() && architecture.back() == '\r') architecture.pop_back();
        if (!Architecture(architecture) || !seen.insert(architecture).second || seen.size() > 128)
            return Fail(error, "provider_architecture_query_failed", "The registered dpkg returned invalid foreign architectures.");
        runtime->registeredArchitectures.push_back(architecture);
    }
    if (runtime->acquisitionArchitectures.empty()) runtime->acquisitionArchitectures = runtime->registeredArchitectures;
    else if (std::find(runtime->acquisitionArchitectures.begin(), runtime->acquisitionArchitectures.end(), runtime->architecture) == runtime->acquisitionArchitectures.end())
        runtime->acquisitionArchitectures.insert(runtime->acquisitionArchitectures.begin(), runtime->architecture);
    return true;
}
Environment ProviderEnvironment(const RegisteredProviderSnapshot &snapshot) {
    Environment environment; const auto &d(snapshot.runtime);
    environment.paths = {d.aptConfigOverride, d.dpkgRootDirectory, d.dpkgAdminDirectory, d.dpkgExecutablePath,
        d.dpkgQueryExecutablePath, d.dpkgDebExecutablePath, d.sourceListPath, d.sourcePartsDirectory};
    environment.configurationIdentity = snapshot.identity.configurationIdentity; environment.policyIdentity = snapshot.identity.policyIdentity;
    environment.methodsIdentity = snapshot.identity.methodsIdentity; environment.packageStateIdentity = snapshot.packageStateIdentity;
    environment.nativeArchitecture = d.architecture; environment.registeredArchitectures = d.registeredArchitectures;
    environment.acquisitionArchitectures = d.acquisitionArchitectures; return environment;
}
} // namespace

bool ResolveRegisteredProviderEnvironment(const CydiaRuntime::PackageDatabasePaths &paths,
    const std::string &registrationPath, const RegistrationIdentity *expected, RegisteredProviderEnvironment *result,
    P::Error *error, unsigned timeoutMilliseconds, const std::function<bool()> &cancelled) {
    if (!result || !Path(registrationPath)) return Fail(error, "provider_registration_invalid", "Invalid provider registration path.");
    const unsigned timeout = timeoutMilliseconds == 0 || timeoutMilliseconds > 10000 ? 4000 : timeoutMilliseconds;
    const auto deadline(std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout));
    const std::function<bool()> stopped = [&]() { return (cancelled && cancelled()) || std::chrono::steady_clock::now() >= deadline; };
    struct stat registrationStat;
    if (lstat(registrationPath.c_str(), &registrationStat) != 0 && (errno == ENOENT || errno == ENOTDIR)) {
        std::string ancestor(registrationPath);
        do {
            ancestor.erase(ancestor.rfind('/'));
            if (ancestor.empty()) ancestor = "/";
        } while (lstat(ancestor.c_str(), &registrationStat) != 0 && (errno == ENOENT || errno == ENOTDIR) && ancestor != "/");
        if (!P::ValidateRootOwnedPath(ancestor, true, false, error)) return false;
        return Fail(error, "provider_registration_missing", "No provider registration is installed.");
    }
    P::Evidence registrationEvidence;
    if (!P::CaptureEvidence(registrationPath, false, true, &registrationEvidence, error)) return false;
    if (registrationEvidence.absent) return Fail(error, "provider_registration_missing", "No provider registration is installed.");
    if (registrationEvidence.bytes.size() > RegistrationLimit || registrationEvidence.identity.st_nlink != 1)
        return Fail(error, "provider_registration_invalid", "The provider registration is unsafe or too large.");
    Registration registration;
    if (!ParseRegistration(registrationEvidence.bytes, &registration, error)) return false;
    RegisteredProviderEnvironment value;
    value.identity.registrationPath = registrationPath; value.identity.providerIdentifier = registration.identifier;
    value.executable = registration.executable; value.executableSearchPath = registration.executableSearchPath;
    value.runtime = registration.runtime; value.runtime.privilegedHelperPath = paths.CydoPath();
    value.runtime.repositorySecurityMode = RepositorySecurityMode::Distribution; value.runtime.mutationEnvironmentValid = true;
    auto &d(value.runtime); auto &environment(value.environment);
    GraphCapture configuration, policy;
    configuration.stopped = stopped; policy.stopped = stopped;
    configuration.evidence.push_back(registrationEvidence);
    if (!CaptureGraph(registration.configFiles, registration.configDirectories, false, &configuration, error) ||
        !CaptureGraph(registration.optionalConfigFiles, registration.optionalConfigDirectories, true, &configuration, error) ||
        !CaptureGraph(registration.policyFiles, registration.policyDirectories, false, &policy, error)) return false;
    P::Evidence overrides, accessPolicy;
    if (!P::ReadExecutableOverrides(paths, &environment.executableOverrides, &overrides, error) ||
        !P::CaptureEvidence(paths.CydiaStateDirectory() + "/admin-access.conf", false, true, &accessPolicy, error) ||
        (!accessPolicy.absent && (accessPolicy.identity.st_nlink != 1 || accessPolicy.bytes.size() > 32768))) return false;
    configuration.evidence.push_back(overrides); configuration.evidence.push_back(accessPolicy);
    CydiaRuntime::AdminAccess::Reset(accessPolicy.bytes); CydiaRuntime::AdminAccess::Activate(d.dpkgAdminDirectory);
    const auto apply = [&](const char *purpose, std::string *path) { const auto found = environment.executableOverrides.find(purpose);
        if (found != environment.executableOverrides.end()) *path = found->second; };
    apply("dpkg", &d.dpkgExecutablePath); apply("dpkg-query", &d.dpkgQueryExecutablePath);
    apply("dpkg-deb", &d.dpkgDebExecutablePath); apply("gpg", &d.gpgExecutablePath);
    environment.aptConfigOverride = d.aptConfigOverride; environment.dpkgRoot = d.dpkgRootDirectory; environment.dpkgAdmin = d.dpkgAdminDirectory;
    environment.dpkg = d.dpkgExecutablePath; environment.dpkgQuery = d.dpkgQueryExecutablePath; environment.dpkgDeb = d.dpkgDebExecutablePath;
    environment.sourceList = d.sourceListPath; environment.sourceParts = d.sourcePartsDirectory; environment.extendedStates = d.extendedStatesPath;
    environment.trusted = d.trustedKeyringPath; environment.trustedParts = d.trustedKeyringPartsDirectory; environment.gpg = d.gpgExecutablePath;
    environment.preferences = registration.preferences; environment.preferencesParts = registration.preferencesParts;
    if (d.dpkgChrootDirectory != "/") return Fail(error, "unsupported_dpkg_chroot", "This registered dpkg chroot needs a supported executor.");
    for (std::size_t i = 0; i < d.dpkgOptions.size(); ++i) for (const char *name : {"--pre-invoke", "--post-invoke"}) {
        const std::string key(name);
        if (d.dpkgOptions[i] == key) {
            if (++i == d.dpkgOptions.size() || d.dpkgOptions[i].empty()) return Fail(error, "invalid_dpkg_options", "A registered dpkg hook is incomplete.");
            environment.trustedDpkgHooks.push_back(key + '=' + d.dpkgOptions[i]); break;
        }
        if (d.dpkgOptions[i].compare(0, key.size() + 1, key + '=') == 0) { environment.trustedDpkgHooks.push_back(d.dpkgOptions[i]); break; }
    }
    if (!P::ValidateDpkgArguments(environment, d.dpkgOptions, error)) return false;
    for (const auto &path : {d.dpkgRootDirectory, d.dpkgAdminDirectory}) {
        P::Evidence evidence;
        if (!P::CapturePathIdentity(path, true, false, &evidence, error, path == d.dpkgAdminDirectory)) return false;
        environment.evidence.push_back(evidence);
    }
    for (const auto &path : {d.dpkgExecutablePath, d.dpkgQueryExecutablePath, d.dpkgDebExecutablePath, d.privilegedHelperPath, value.executable}) {
        P::Evidence evidence;
        if (!P::CapturePathIdentity(path, false, true, &evidence, error)) return false;
        environment.evidence.push_back(evidence);
    }
    P::Evidence methods;
    if (!P::CaptureEvidence(d.methodsDirectory, true, false, &methods, error) || methods.entries.size() > 256) return false;
    std::vector<std::string> methodFiles;
    for (const auto &entry : methods.entries) methodFiles.push_back(d.methodsDirectory + '/' + entry);
    std::string methodsFiles;
    std::size_t componentBytes = 0;
    std::vector<ComponentEvidence> components;
    std::vector<std::string> frontends{value.executable}; frontends.insert(frontends.end(), registration.frontends.begin(), registration.frontends.end());
    if (!ComponentsIdentity("CYDIA-PROVIDER-LIBRARIES-1", registration.libraries, false, &value.identity.libraryIdentity, error, stopped, &componentBytes, &components) ||
        !ComponentsIdentity("CYDIA-PROVIDER-FRONTENDS-1", frontends, true, &value.identity.frontendIdentity, error, stopped, &componentBytes, &components) ||
        !ComponentsIdentity("CYDIA-PROVIDER-METHOD-FILES-1", methodFiles, true, &methodsFiles, error, stopped, &componentBytes, &components)) return false;
    value.identity.methodsIdentity = Digest("CYDIA-PROVIDER-METHODS-1", {ProviderEvidenceBytes(methods), methodsFiles});
    value.identity.configurationIdentity = GraphIdentity("CYDIA-PROVIDER-CONFIGURATION-1", configuration);
    value.identity.policyIdentity = GraphIdentity("CYDIA-PROVIDER-POLICY-1", policy,
        {value.identity.libraryIdentity, value.identity.frontendIdentity, value.identity.configurationIdentity});
    environment.evidence.insert(environment.evidence.end(), configuration.evidence.begin(), configuration.evidence.end());
    environment.evidence.insert(environment.evidence.end(), policy.evidence.begin(), policy.evidence.end());
    environment.evidence.push_back(methods);
    if (expected && !SameRegistrationIdentity(value.identity, *expected))
        return Fail(error, "provider_registration_changed", "The registered provider or its configuration changed.");
    if (!QueryArchitectures(&d, timeout, stopped, error) ||
        !P::RecheckEvidence(environment.evidence, error)) return false;
    for (const auto &component : components) {
        P::Evidence current{}; current.path = component.identity.path;
        if (!P::ValidateRootOwnedPath(current.path, false, component.executable, error) || stat(current.path.c_str(), &current.identity) != 0 ||
            ProviderEvidenceBytes(current) != ProviderEvidenceBytes(component.identity))
            return Fail(error, "provider_component_changed", "A registered provider component changed during verification.");
        if (component.executable) { current.identityOnly = true; environment.evidence.push_back(current); }
    }
    if (stopped()) return Fail(error, "provider_capture_cancelled", "Provider verification was cancelled or timed out.");
    // Validate complete descriptor shape before any caller may use a path.
    RegisteredProviderSnapshot shape(MakeRegisteredProviderSnapshot(value, std::string(64, '0')));
    if (!ValidateRegisteredProviderSnapshot(shape)) return Fail(error, "provider_registration_invalid", "The registered runtime descriptor is incoherent.");
    *result = std::move(value); return true;
}

std::vector<std::string> ProviderRegistrationCandidates(const CydiaRuntime::PackageDatabasePaths &paths) {
    const std::string data(paths.DpkgDataDirectory()); const auto slash(data.rfind('/'));
    if (slash == std::string::npos) return {};
    return {paths.CydiaStateDirectory() + "/apt-provider.conf", data.substr(0, slash) + "/cydia/apt-provider.conf"};
}

SelectionResult DiscoverProvider(const CydiaRuntime::PackageDatabasePaths &paths, const InitializationOptions &options,
    const std::string &savedSecurityPreference, const RegistrationSnapshotReader &reader, unsigned timeoutMilliseconds,
    const std::function<bool()> &cancelled) {
    SelectionResult result;
    if (!reader) { result.availability = Availability::Broken; result.errorCode = "provider_authority_unavailable"; return result; }
    const unsigned timeout = timeoutMilliseconds == 0 || timeoutMilliseconds > 10000 ? 4000 : timeoutMilliseconds;
    for (const auto &path : ProviderRegistrationCandidates(paths)) {
        if (cancelled && cancelled()) { result.availability = Availability::Broken; result.errorCode = "provider_cancelled"; return result; }
        P::Error error; RegisteredProviderSnapshot snapshot;
        if (!reader(path, nullptr, &snapshot, &error, timeout, cancelled)) {
            if (error.code == "provider_registration_missing") continue;
            result.availability = Availability::Broken; result.errorCode = StableCode(error.code, "provider_registration_failed"); return result;
        }
        if (!ValidateRegisteredProviderSnapshot(snapshot) || snapshot.identity.registrationPath != path) {
            result.availability = Availability::Broken; result.errorCode = "provider_registration_invalid"; return result;
        }
        result.snapshot = snapshot;
        result.hello.options = options; result.hello.expected = ProviderEnvironment(snapshot);
        result.hello.options.repositorySecurityMode = EffectiveRepositorySecurityMode(savedSecurityPreference, true);
        // This embedded cache-generation shortcut is not a distribution
        // policy override; the external provider owns its essential set.
        result.hello.options.forceEssential = false;
        result.hello.options.dpkgExecutableSearchPath = snapshot.executableSearchPath;
        result.hello.options.nativeDpkgPath = snapshot.runtime.dpkgExecutablePath;
        result.hello.options.dpkgPath = snapshot.runtime.privilegedHelperPath;
        result.hello.options.helperPath = snapshot.runtime.privilegedHelperPath;
        result.hello.options.packageInstallPrefix = snapshot.runtime.packageInstallPrefix;
        result.hello.options.methodsDirectory = snapshot.runtime.methodsDirectory;
        result.hello.options.listsDirectory = snapshot.runtime.listsDirectory;
        result.hello.options.dpkgStatusPath = snapshot.runtime.dpkgAdminDirectory + "/status";
        result.hello.options.bootstrapExtendedStatesPath = snapshot.runtime.extendedStatesPath;
        result.hello.options.architecture = snapshot.runtime.architecture;
        result.hello.registrationPath = path;
        if (result.hello.options.repositorySecurityMode != RepositorySecurityMode::Distribution)
            result.hello.requiredCapabilities |= ExplicitSecurityOverrides;
        result.probe = Probe(snapshot.executable, result.hello.expected, timeout, cancelled, path);
        result.availability = result.probe.availability;
        result.errorCode = result.probe.compatible() ? std::string() : StableCode(result.probe.errorCode, "provider_probe_failed");
        if (!result.probe.compatible()) return result;
        if (result.probe.info.identifier != snapshot.identity.providerIdentifier ||
            result.probe.info.libraryIdentity != snapshot.identity.libraryIdentity || result.probe.info.frontendIdentity != snapshot.identity.frontendIdentity) {
            result.availability = Availability::Unsupported; result.errorCode = "provider_registration_mismatch"; return result;
        }
        if ((result.probe.info.capabilities & result.hello.requiredCapabilities) != result.hello.requiredCapabilities) {
            result.availability = Availability::Unsupported; result.errorCode = "provider_override_unsupported"; return result;
        }
        RegisteredProviderSnapshot after;
        if (!reader(path, &snapshot.identity, &after, &error, timeout, cancelled) ||
            SerializeRegisteredProviderSnapshot(after) != SerializeRegisteredProviderSnapshot(snapshot)) {
            result.availability = Availability::Broken; result.errorCode = "provider_changed_during_probe"; return result;
        }
        result.snapshot.runtime.repositorySecurityMode = result.hello.options.repositorySecurityMode;
        return result;
    }
    result.errorCode = "provider_registration_missing"; return result;
}
}} // namespace CydiaAPT::Provider
