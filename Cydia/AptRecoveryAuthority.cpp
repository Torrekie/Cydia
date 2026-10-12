/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryAuthority.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/init.h>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <set>
#include <sstream>
#include <unistd.h>

namespace CydiaAPT { namespace Recovery {
namespace {
namespace P = CydiaRuntime::Privileged;
using Resolver = std::function<bool(const CydiaRuntime::PackageDatabasePaths &, const std::string &, P::Environment *, P::Error *)>;
const char *const securityKeys[] = {"Acquire::AllowInsecureRepositories", "Acquire::AllowWeakRepositories",
    "Acquire::AllowDowngradeToInsecureRepositories", "Acquire::Check-Valid-Until", "APT::Get::AllowUnauthenticated"};
bool Fail(P::Error *error, const char *code, const char *message) {
    if (error) { error->code = code; error->message = message; } return false;
}
std::string Trim(std::string value) { while (value.size() > 1 && value.back() == '/') value.pop_back(); return value; }
bool Path(const std::string &value, bool optional = false) {
    if (value.empty()) return optional;
    if (value.front() != '/' || value.size() > 4096 || (value.size() > 1 && value.back() == '/')) return false;
    for (unsigned char c : value) if (c <= 31 || c == 127) return false;
    std::size_t start = 1;
    while (start < value.size()) {
        const auto end = value.find('/', start); const auto part = value.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return true;
}
bool Under(const std::string &path, const std::string &root) {
    return root != "/" && !root.empty() && (path == root ||
        (path.size() > root.size() && path.compare(0, root.size(), root) == 0 && path[root.size()] == '/'));
}
bool SamePath(const std::string &a, const std::string &b) {
    if (a == b) return true;
    char *left = realpath(a.c_str(), nullptr), *right = realpath(b.c_str(), nullptr);
    const bool same = left && right && std::strcmp(left, right) == 0;
    std::free(left); std::free(right); return same;
}
bool Disabled(const std::string &value) { return value.empty() || value == "-" || Trim(value) == "/dev/null"; }
std::string ConfigPath(const Configuration &config, const char *key, bool directory, bool optional = false) {
    if (optional && Disabled(config.Find(key))) return {};
    const std::string value(Trim(directory ? config.FindDir(key) : config.FindFile(key)));
    return optional && (value == "/dev/null" || (value.size() >= 9 && value.compare(value.size() - 9, 9, "/dev/null") == 0)) ? "" : value;
}
bool Arch(const std::string &value, bool all = false) {
    if (value.empty() || value.size() > 128 || value.front() == '-' || value == "any" || value == "native" || (!all && value == "all")) return false;
    return value.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-") == std::string::npos;
}
bool Token(const std::string &value) {
    return !value.empty() && value.size() <= 128 && value.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:") == std::string::npos;
}
std::string Hash(const char *domain, const std::vector<std::string> &fields) {
    const std::string bytes(P::SerializeFields(fields)); Hashes hash(Hashes::SHA256SUM);
    if (!hash.Add(domain, std::strlen(domain)) || !hash.Add(bytes.data(), bytes.size())) return {};
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
std::string EvidenceBytes(P::Evidence value) {
    value.sourceReaderUID = value.sourceReaderGID = 0;
    value.sourceReaderGroups.valid = false; value.sourceReaderGroups.values.clear();
    return P::SerializeSnapshotEvidence(value);
}
struct Capture {
    std::vector<P::Evidence> evidence;
    std::function<bool()> stopped;
    P::Error *error;
    std::size_t bytes = 0;
    bool denied = false;
    bool Add(const std::string &raw, bool directory, bool optional) {
        const std::string path(Trim(raw));
        if (stopped()) return Fail(error, "recovery_capture_cancelled", "Recovery verification was cancelled or timed out.");
        if (!Path(path) || evidence.size() >= 4096) return Fail(error, "recovery_configuration_invalid", "Recovery configuration exceeds its limits.");
        P::Evidence input;
        if (!P::CaptureEvidence(path, directory, optional, &input, error)) return false;
        bytes += input.bytes.size();
        if (bytes > 32 * 1024 * 1024) return Fail(error, "recovery_configuration_invalid", "Recovery configuration exceeds its limits.");
        evidence.push_back(std::move(input)); return true;
    }
};
bool ValidateRead(const std::string &path, bool directory, void *context) {
    auto &capture(*static_cast<Capture *>(context));
    const bool result(capture.Add(path, directory, false)); capture.denied |= !result; return result;
}
class ConfigurationGuard {
public:
    explicit ConfigurationGuard(Capture *capture) { _error->PushToStack(); SetConfigurationReadValidator(ValidateRead, capture); }
    ~ConfigurationGuard() { SetConfigurationReadValidator(nullptr, nullptr); _error->RevertToStack(); }
};
bool ReadOptional(Configuration &config, const std::string &path, bool directory, Capture &capture) {
    if (Disabled(path)) return true;
    if (!capture.Add(path, directory, true)) return false;
    if (capture.evidence.back().absent) return true;
    return directory ? ReadConfigDir(config, path) : ReadConfigFile(config, path);
}
bool ReadConfiguration(const InitializationOptions &s, const std::string &overridePath,
    Configuration &config, Capture &capture) {
    // Obtain this linked APT's compiled defaults without reading ambient or
    // host configuration. Then perform its documented override/parts/main read
    // order explicitly, so absent inputs also participate in the fingerprint.
    const char *ambient(std::getenv("APT_CONFIG"));
    if (ambient && *ambient) return Fail(capture.error, "recovery_ambient_configuration", "Recovery authority requires an explicit configuration input.");
    ConfigurationGuard guard(&capture);
    config.Set("Dir::Etc::parts", "/dev/null"); config.Set("Dir::Etc::main", "/dev/null");
    if (!pkgInitConfig(config) || capture.denied)
        return capture.denied ? false : Fail(capture.error, "recovery_configuration_invalid", "Cannot initialize recovery configuration defaults.");
    config.Set("Dir::Etc::parts", "apt.conf.d"); config.Set("Dir::Etc::main", "apt.conf");
    config.Set("APT::Architecture", s.architecture); config.Set("Dir::Etc", s.aptConfigDirectory);
    config.Set("Dir::Bin::Methods", s.methodsDirectory); config.Set("Dir::Cache", s.cacheDirectory);
    config.Set("Dir::State", s.stateDirectory); config.Set("Dir::State::Lists", s.listsDirectory);
    config.Set("Dir::State::status", s.dpkgStatusPath); config.Set("Dir::State::extended_states", s.bootstrapExtendedStatesPath);
    config.Set("Dir::Log", s.logDirectory); config.Set("Dir::Bin::dpkg", s.dpkgPath);
    config.Set("Cydia::Package-Install-Prefix", s.packageInstallPrefix); config.Set("DPkg::Path", s.dpkgExecutableSearchPath);
    for (const char *table : {"cputable", "tupletable", "triplettable"})
        config.Set((std::string("Dir::dpkg::") + table).c_str(), s.dpkgDataDirectory + '/' + table);
    const auto bin(s.nativeDpkgPath.substr(0, s.nativeDpkgPath.rfind('/') + 1));
    for (const char *tool : {"apt-key", "gpgv", "gpg"}) config.Set((std::string("Dir::Bin::") + tool).c_str(), bin + tool);
    if (!overridePath.empty() && (!capture.Add(overridePath, false, false) || !ReadConfigFile(config, overridePath)))
        return capture.denied ? false : Fail(capture.error, "recovery_configuration_invalid", "Cannot read the protected recovery configuration.");
    if (!ReadOptional(config, ConfigPath(config, "Dir::Etc::parts", true, true), true, capture) ||
        !ReadOptional(config, ConfigPath(config, "Dir::Etc::main", false, true), false, capture) || capture.denied)
        return capture.denied ? false : Fail(capture.error, "recovery_configuration_invalid", "Cannot read the protected recovery configuration.");
    return true;
}
bool StartupValid(const InitializationOptions &s, const std::string &overridePath, const BundleInputs &bundle) {
    for (const auto *path : {&s.aptConfigDirectory, &s.methodsDirectory, &s.cacheDirectory, &s.stateDirectory,
        &s.listsDirectory, &s.logDirectory, &s.dpkgStatusPath, &s.bootstrapExtendedStatesPath, &s.dpkgPath,
        &s.nativeDpkgPath, &s.packageInstallPrefix, &s.privateRuntimeConfigurationPath, &s.helperPath, &s.dpkgDataDirectory,
        &bundle.executable}) if (!Path(*path)) return false;
    if (!Path(overridePath, true) || !Arch(s.architecture) || bundle.requiredMethods.empty() ||
        bundle.requiredMethods.size() > 128 || bundle.libraries.size() > 256 || bundle.dataFiles.size() > 256) return false;
    std::set<std::string> names;
    for (const auto &name : bundle.requiredMethods) if (!Token(name) || name == "." || name == ".." ||
        !names.insert(name).second) return false;
    for (const auto *files : {&bundle.libraries, &bundle.dataFiles}) {
        std::set<std::string> unique;
        for (const auto &path : *files) if (!Path(path) || !unique.insert(path).second) return false;
    }
    return true;
}
bool Architectures(RuntimeDescriptor &d, Configuration &config, const std::function<bool()> &stopped,
    const std::function<unsigned()> &remaining, P::Error *error) {
    CydiaRuntime::Dpkg::Runner runner(d.dpkgExecutablePath); std::string output;
    std::vector<std::string> args{"--root=" + d.dpkgRootDirectory, "--admindir=" + d.dpkgAdminDirectory, "--print-architecture"};
    if (stopped() || !runner.RunAndCaptureBounded(args, &output, 32768, remaining(), stopped).succeeded() ||
        output.empty() || output.back() != '\n') return Fail(error, "recovery_architecture_query_failed", "Cannot verify the selected dpkg architecture.");
    output.pop_back();
    if (!Arch(output)) return Fail(error, "recovery_architecture_query_failed", "dpkg returned an invalid architecture.");
    d.architecture = output; d.registeredArchitectures = {output}; args.back() = "--print-foreign-architectures";
    if (stopped() || !runner.RunAndCaptureBounded(args, &output, 32768, remaining(), stopped).succeeded() ||
        (!output.empty() && output.back() != '\n')) return Fail(error, "recovery_architecture_query_failed", "Cannot verify dpkg foreign architectures.");
    std::istringstream stream(output); std::string arch; std::set<std::string> seen{d.architecture};
    while (std::getline(stream, arch)) {
        if (!Arch(arch) || !seen.insert(arch).second || seen.size() > 128)
            return Fail(error, "recovery_architecture_query_failed", "dpkg returned invalid foreign architectures.");
        d.registeredArchitectures.push_back(arch);
    }
    d.acquisitionArchitectures = config.FindVector("APT::Architectures");
    if (d.acquisitionArchitectures.empty()) d.acquisitionArchitectures = d.registeredArchitectures;
    else {
        std::vector<std::string> values{d.architecture}; seen = {d.architecture};
        for (const auto &value : d.acquisitionArchitectures) {
            if (!Arch(value, true)) return Fail(error, "recovery_acquisition_architectures_invalid", "Invalid acquisition architecture policy.");
            if (seen.insert(value).second) values.push_back(value);
        }
        d.acquisitionArchitectures.swap(values);
    }
    config.Set("APT::Architecture", d.architecture); return true;
}
bool Derive(Authority &value, Configuration &config, P::Error *error) {
    auto &d(value.runtime); const auto &e(value.environment);
    d.origin = RuntimeDescriptorOrigin::Embedded; d.aptConfigOverride = e.aptConfigOverride;
    d.privilegedHelperPath = value.startup.helperPath;
    const std::string root(Trim(config.Find("RootDir")));
    if (!Path(root, true)) return Fail(error, "recovery_path_invalid", "Recovery has an invalid configured root.");
    for (const char *key : {"Dir::Etc", "Dir::Etc::sourcelist", "Dir::Etc::sourceparts", "Dir::Bin::Methods",
        "Dir::Cache", "Dir::State", "Dir::State::Lists", "Dir::Log", "Dir::State::status",
        "Dir::dpkg::cputable", "Dir::dpkg::tupletable", "Dir::dpkg::triplettable"})
        if (Under(config.Find(key), root))
            return Fail(error, "recovery_double_root", "Recovery configuration applies its root twice.");
    d.dpkgExecutablePath = e.dpkg; d.dpkgQueryExecutablePath = e.dpkgQuery; d.dpkgDebExecutablePath = e.dpkgDeb;
    d.dpkgRootDirectory = e.dpkgRoot; d.dpkgAdminDirectory = e.dpkgAdmin;
    d.sourceListPath = ConfigPath(config, "Dir::Etc::sourcelist", false, true);
    d.sourcePartsDirectory = ConfigPath(config, "Dir::Etc::sourceparts", true, true);
    d.extendedStatesPath = ConfigPath(config, "Dir::State::extended_states", false);
    d.trustedKeyringPath = ConfigPath(config, "Dir::Etc::trusted", false, true);
    d.trustedKeyringPartsDirectory = ConfigPath(config, "Dir::Etc::trustedparts", true, true);
    d.methodsDirectory = ConfigPath(config, "Dir::Bin::Methods", true);
    d.listsDirectory = ConfigPath(config, "Dir::State::Lists", true);
    d.dpkgChrootDirectory = Trim(config.FindDir("DPkg::Chroot-Directory", "/"));
    d.packageInstallPrefix = Trim(config.Find("Cydia::Package-Install-Prefix"));
    d.dpkgOptions = config.FindVector("DPkg::Options");
    d.dpkgOptions.erase(std::remove(d.dpkgOptions.begin(), d.dpkgOptions.end(), std::string()), d.dpkgOptions.end());
    if (Under(d.packageInstallPrefix, d.dpkgRootDirectory)) {
        d.packageInstallPrefix.erase(0, d.dpkgRootDirectory.size());
        if (d.packageInstallPrefix.empty()) d.packageInstallPrefix = "/";
    }
    d.gpgExecutablePath = e.gpg;
    value.cacheDirectory = ConfigPath(config, "Dir::Cache", true);
    value.archivesDirectory = ConfigPath(config, "Dir::Cache::Archives", true);
    value.logDirectory = ConfigPath(config, "Dir::Log", true);
    value.executableSearchPath = config.Find("DPkg::Path");
    if (value.executableSearchPath.empty() || value.executableSearchPath.back() == ':')
        return Fail(error, "recovery_search_path_invalid", "The recovery executable search path is invalid.");
    std::istringstream search(value.executableSearchPath); std::string directory; unsigned count = 0;
    while (std::getline(search, directory, ':')) if (!Path(directory) || ++count > 128)
        return Fail(error, "recovery_search_path_invalid", "The recovery executable search path is invalid.");
    const std::string status(ConfigPath(config, "Dir::State::status", false));
    if (!SamePath(status, e.dpkgAdmin + "/status") || !SamePath(d.sourceListPath, e.sourceList) ||
        !SamePath(d.sourcePartsDirectory, e.sourceParts) || !SamePath(d.extendedStatesPath, e.extendedStates) ||
        !SamePath(d.trustedKeyringPath, e.trusted) || !SamePath(d.trustedKeyringPartsDirectory, e.trustedParts) ||
        !SamePath(ConfigPath(config, "Dir::Etc::preferences", false, true), e.preferences) ||
        !SamePath(ConfigPath(config, "Dir::Etc::preferencesparts", true, true), e.preferencesParts) ||
        !SamePath(config.Find("Apt::Key::gpgcommand"), e.gpg) ||
        d.dpkgChrootDirectory != "/" || !P::ValidateDpkgArguments(e, d.dpkgOptions, error))
        return Fail(error, "recovery_environment_mismatch", "Recovery configuration disagrees with the protected package environment.");
    const std::string managed(config.Find("Cydia::APT::ManagedSourceList"));
    if (!managed.empty()) {
        if (d.sourcePartsDirectory.empty()) return Fail(error, "recovery_managed_source_invalid", "A managed source needs an enabled source directory.");
        std::vector<std::string> candidates;
        if (managed.front() == '/') {
            const std::string root(Trim(config.Find("RootDir")));
            if (!root.empty() && root != "/") candidates.push_back(root + managed);
            candidates.push_back(managed);
        } else candidates.push_back(d.sourcePartsDirectory + '/' + managed);
        for (const auto &candidate : candidates) {
            const auto slash(candidate.rfind('/')); const std::string leaf(candidate.substr(slash + 1));
            if (Path(candidate) && candidate.substr(0, slash) == d.sourcePartsDirectory && leaf.size() > 5 &&
                leaf.compare(leaf.size() - 5, 5, ".list") == 0 &&
                leaf.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-") == std::string::npos) {
                d.managedSourceListPath = candidate; break;
            }
        }
        if (d.managedSourceListPath.empty()) return Fail(error, "recovery_managed_source_invalid", "The managed source is outside the selected source directory.");
    }
    for (const auto *path : {&d.dpkgExecutablePath, &d.dpkgQueryExecutablePath, &d.dpkgDebExecutablePath,
        &d.privilegedHelperPath, &d.dpkgRootDirectory, &d.dpkgAdminDirectory, &d.packageInstallPrefix,
        &d.extendedStatesPath, &d.methodsDirectory, &d.listsDirectory, &value.cacheDirectory,
        &value.archivesDirectory, &value.logDirectory}) if (!Path(*path)) return Fail(error, "recovery_path_invalid", "Recovery has an invalid effective path.");
    for (const auto *path : {&d.sourceListPath, &d.sourcePartsDirectory, &d.trustedKeyringPath,
        &d.trustedKeyringPartsDirectory, &d.gpgExecutablePath}) if (!Path(*path, true))
            return Fail(error, "recovery_path_invalid", "Recovery has an invalid effective path.");
    return true;
}
struct HashedComponent { Component value; P::Evidence identity; };
bool Fingerprint(const std::string &path, bool executable, const std::function<bool()> &stopped,
    std::size_t &total, HashedComponent *result, P::Error *error) {
    if (stopped()) return Fail(error, "recovery_capture_cancelled", "Recovery verification was cancelled or timed out.");
    if (!P::ValidateRootOwnedPath(path, false, executable, error)) return false;
    const int fd(open(path.c_str(), O_RDONLY | O_CLOEXEC));
    if (fd < 0) return Fail(error, "recovery_component_unreadable", "A required recovery component is unreadable.");
    P::Evidence before{}, after{}, current{}; before.path = after.path = current.path = path;
    Hashes hashes(Hashes::SHA256SUM); std::size_t readBytes = 0;
    bool okay = fstat(fd, &before.identity) == 0 && S_ISREG(before.identity.st_mode) && before.identity.st_uid == 0 &&
        (before.identity.st_mode & (S_IWGRP | S_IWOTH)) == 0 && before.identity.st_size >= 0 && before.identity.st_size <= 128 * 1024 * 1024;
    char bytes[32768];
    while (okay) {
        if (stopped()) { okay = false; break; }
        const ssize_t size(read(fd, bytes, sizeof(bytes)));
        if (size < 0 && errno == EINTR) continue;
        if (size < 0) { okay = false; break; }
        if (!size) break;
        readBytes += size; total += size;
        okay = readBytes <= 128 * 1024 * 1024 && total <= 512 * 1024 * 1024 && hashes.Add(bytes, size);
    }
    okay = okay && fstat(fd, &after.identity) == 0 && stat(path.c_str(), &current.identity) == 0 &&
        readBytes == static_cast<std::size_t>(before.identity.st_size);
    close(fd);
    if (!okay || EvidenceBytes(before) != EvidenceBytes(after) || EvidenceBytes(before) != EvidenceBytes(current) ||
        !P::ValidateRootOwnedPath(path, false, executable, error))
        return Fail(error, "recovery_component_changed", "A recovery component changed during verification.");
    result->value.path = path; result->value.executable = executable;
    result->value.sha256 = hashes.GetHashString(Hashes::SHA256SUM).HashValue(); result->identity = before;
    return true;
}
std::string ComponentBytes(const HashedComponent &component) {
    return P::SerializeFields({component.value.path, component.value.executable ? "1" : "0",
        component.value.sha256, EvidenceBytes(component.identity)});
}
bool Resolve(const CydiaRuntime::PackageDatabasePaths &paths, const InitializationOptions &startup,
    const std::string &overridePath, const std::string &preference, const BundleInputs &bundle,
    const Identity *expected, Authority *result, P::Error *error, const Resolver &resolver,
    const DependencyInspector &inspect, unsigned timeout, const std::function<bool()> &cancelled) {
    if (!result) return Fail(error, "recovery_invalid_request", "No recovery authority output was supplied.");
    *result = Authority(); if (error) *error = P::Error();
    if (!resolver || !StartupValid(startup, overridePath, bundle) || timeout == 0 || timeout > 10000)
        return Fail(error, "recovery_invalid_request", "Invalid helper-owned recovery inputs.");
    const auto deadline(std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout));
    const std::function<bool()> stopped = [&]() { return (cancelled && cancelled()) || std::chrono::steady_clock::now() >= deadline; };
    const std::function<unsigned()> remaining = [&]() { const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count(); return ms <= 0 ? 1u : static_cast<unsigned>(ms); };
    if (stopped()) return Fail(error, "recovery_capture_cancelled", "Recovery verification was cancelled or timed out.");
    Authority value; value.startup = startup; value.executable = bundle.executable;
    if (!resolver(paths, overridePath, &value.environment, error)) return false;
    if (value.environment.aptConfigOverride != overridePath) return Fail(error, "recovery_environment_mismatch", "The protected resolver changed the configuration override.");
    Capture capture; capture.stopped = stopped; capture.error = error;
    Configuration config;
    if (!ReadConfiguration(startup, overridePath, config, capture)) return false;
    for (const char *tool : {"gpg", "gpgv"})
        config.CndSet((std::string("Apt::Key::") + tool + "command").c_str(),
            config.Find((std::string("Dir::Bin::") + tool).c_str()).c_str());
    for (const auto &overrideValue : value.environment.executableOverrides) {
        // The independently protected resolver has already parsed the accepted
        // executable purposes. Retain the same effective command policy for
        // dependency inspection without replacing dpkg's broker entry point.
        if (overrideValue.first == "dpkg") continue;
        config.Set(("Dir::Bin::" + overrideValue.first).c_str(), overrideValue.second);
        if (overrideValue.first == "gpg" || overrideValue.first == "gpgv")
            config.Set(("Apt::Key::" + overrideValue.first + "command").c_str(), overrideValue.second);
    }
    if (!Derive(value, config, error)) return false;
    value.environment.evidence.insert(value.environment.evidence.end(), capture.evidence.begin(), capture.evidence.end());
    if (!Architectures(value.runtime, config, stopped, remaining, error)) return false;
    value.securityPreferenceExplicit = IsRepositorySecurityModeName(preference);
    value.runtime.repositorySecurityMode = EffectiveRepositorySecurityMode(preference, false);
    value.startup.repositorySecurityMode = value.runtime.repositorySecurityMode;
    for (const auto *key : securityKeys) if (config.Exists(key)) value.configuredSecurity[key] = config.Find(key);
    std::ostringstream effective; config.Dump(effective); value.configuration = effective.str();
    if (value.configuration.size() > 32 * 1024 * 1024) return Fail(error, "recovery_configuration_invalid", "The effective recovery configuration exceeds its limits.");
    std::vector<std::string> configFields{value.configuration, overridePath, startup.translation, startup.languages,
        std::to_string(startup.maxParallel), startup.forceEssential ? "1" : "0",
        P::SerializeFields(value.runtime.registeredArchitectures), P::SerializeFields(value.runtime.acquisitionArchitectures)};
    for (const auto &input : value.environment.evidence) configFields.push_back(EvidenceBytes(input));
    P::Evidence methods;
    if (!P::CaptureEvidence(value.runtime.methodsDirectory, true, false, &methods, error)) return false;
    if (methods.entries.size() > 4096) return Fail(error, "recovery_components_too_large", "Too many recovery method entries were selected.");
    value.environment.evidence.push_back(methods);
    std::map<std::string, bool> requested;
    requested[bundle.executable] = true; requested[value.runtime.privilegedHelperPath] = true;
    for (const auto *tool : {&value.runtime.dpkgExecutablePath, &value.runtime.dpkgQueryExecutablePath,
        &value.runtime.dpkgDebExecutablePath}) requested[*tool] = true;
    for (const auto &path : bundle.libraries) requested.emplace(path, false);
    for (const auto &path : bundle.dataFiles) requested.emplace(path, false);
    // libapt's architecture policy consumes the CPU table and either tuple
    // table, even when its native/foreign names came from selected dpkg.
    // Bind the absence of the preferred tuple table as well as the fallback.
    for (const char *key : {"Dir::dpkg::cputable", "Dir::dpkg::tupletable", "Dir::dpkg::triplettable"}) {
        const std::string path(ConfigPath(config, key, false)); P::Evidence table;
        if (!Path(path) || !P::CaptureEvidence(path, false, std::strcmp(key, "Dir::dpkg::cputable") != 0, &table, error))
            return Fail(error, "recovery_architecture_tables_unavailable", "Recovery architecture policy data is unavailable.");
        value.environment.evidence.push_back(table); configFields.push_back(EvidenceBytes(table));
        if (!table.absent) requested.emplace(path, false);
    }
    if (value.environment.evidence[value.environment.evidence.size() - 1].absent &&
        value.environment.evidence[value.environment.evidence.size() - 2].absent)
        return Fail(error, "recovery_architecture_tables_unavailable", "Recovery architecture policy data is unavailable.");
    std::set<std::string> methodPaths;
    for (const auto &name : bundle.requiredMethods) {
        if (!std::binary_search(methods.entries.begin(), methods.entries.end(), name))
            return Fail(error, "recovery_method_missing", "A required recovery acquisition method is missing.");
        const std::string path(value.runtime.methodsDirectory + '/' + name); requested[path] = true; methodPaths.insert(path);
    }
    // Capture every executable method entry, including protected symlinks.
    // App bundle resource directories are not executable acquisition methods.
    for (const auto &name : methods.entries) {
        if (stopped()) return Fail(error, "recovery_capture_cancelled", "Recovery verification was cancelled or timed out.");
        const std::string path(value.runtime.methodsDirectory + '/' + name); struct stat st;
        if (stat(path.c_str(), &st) != 0) return Fail(error, "recovery_method_changed", "The recovery methods directory changed.");
        if (S_ISREG(st.st_mode) && (st.st_mode & 0111)) { requested[path] = true; methodPaths.insert(path); }
    }
    if (requested.size() > 512) return Fail(error, "recovery_components_too_large", "Too many recovery components were selected.");
    std::vector<HashedComponent> components; std::size_t total = 0;
    std::vector<std::string> inventory, libraries, frontends, methodFields{EvidenceBytes(methods)};
    for (const auto &request : requested) {
        HashedComponent component;
        if (!Fingerprint(request.first, request.second, stopped, total, &component, error)) return false;
        const std::string bytes(ComponentBytes(component)); inventory.push_back(bytes);
        // The executable contains statically linked private APT code as well
        // as frontend policy. Empty dynamic-library lists are not proof of a
        // static closure; the inspector below still has to establish that.
        if (request.first == bundle.executable || std::find(bundle.libraries.begin(), bundle.libraries.end(), request.first) != bundle.libraries.end()) libraries.push_back(bytes);
        if (request.first == bundle.executable || request.first == value.runtime.privilegedHelperPath) frontends.push_back(bytes);
        if (methodPaths.count(request.first)) methodFields.push_back(bytes);
        if (request.first == value.runtime.dpkgExecutablePath || request.first == value.runtime.dpkgQueryExecutablePath ||
            request.first == value.runtime.dpkgDebExecutablePath) configFields.push_back(bytes);
        value.components.push_back(component.value); components.push_back(std::move(component));
    }
    const std::string inventoryIdentity(Hash("CYDIA-RECOVERY-INVENTORY-1", inventory));
    value.identity.libraries = Hash("CYDIA-RECOVERY-LIBRARIES-1", libraries);
    value.identity.frontend = Hash("CYDIA-RECOVERY-FRONTEND-1", frontends);
    value.identity.methods = Hash("CYDIA-RECOVERY-METHODS-1", methodFields);
    value.identity.configuration = Hash("CYDIA-RECOVERY-CONFIGURATION-1", configFields);
    DependencyProof proof;
    if (inspect) proof = inspect(value, inventoryIdentity, stopped);
    else proof.unresolvedFields = {"dependencyClosure", "componentLoadability", "configuredCommandClosure"};
    value.unresolvedFields = proof.unresolvedFields;
    if (inspect && (proof.inventoryIdentity != inventoryIdentity || !Token(proof.loaderIdentity)))
        return Fail(error, "recovery_dependency_proof_invalid", "Recovery dependency evidence does not bind the captured components.");
    std::set<std::string> dependencies;
    for (const auto &path : proof.nonPlatformDependencies) {
        if (!Path(path) || !requested.count(path) || !dependencies.insert(path).second)
            return Fail(error, "recovery_dependency_proof_invalid", "A recovery dependency is missing from the verified component set.");
    }
    if (value.unresolvedFields.size() > 128 || std::any_of(value.unresolvedFields.begin(), value.unresolvedFields.end(),
        [](const std::string &field) { return !Token(field); })) return Fail(error, "recovery_dependency_proof_invalid", "Invalid unresolved recovery dependency fields.");
    if (inspect) value.identity.dependencies = Hash("CYDIA-RECOVERY-DEPENDENCIES-1",
        {inventoryIdentity, proof.loaderIdentity, P::SerializeFields(proof.nonPlatformDependencies), P::SerializeFields(proof.unresolvedFields)});
    std::vector<std::string> policyFields{value.identity.configuration, value.identity.libraries, value.identity.frontend,
        value.identity.methods, value.identity.dependencies, value.securityPreferenceExplicit ? "explicit" : "absent",
        RepositorySecurityModeName(value.runtime.repositorySecurityMode)};
    for (const auto &setting : value.configuredSecurity) { policyFields.push_back(setting.first); policyFields.push_back(setting.second); }
    value.identity.policy = Hash("CYDIA-RECOVERY-POLICY-1", policyFields);
    if (stopped()) return Fail(error, "recovery_capture_cancelled", "Recovery verification was cancelled or timed out.");
    if (!P::RecheckEvidence(value.environment.evidence, error)) return false;
    for (const auto &component : components) {
        P::Evidence current{}; current.path = component.value.path;
        if (!P::ValidateRootOwnedPath(current.path, false, component.value.executable, error) || stat(current.path.c_str(), &current.identity) != 0 ||
            EvidenceBytes(current) != EvidenceBytes(component.identity)) return Fail(error, "recovery_component_changed", "A recovery component changed during verification.");
    }
    if (expected && !SameIdentity(value.identity, *expected)) return Fail(error, "recovery_authority_changed", "The recovery runtime or its policy changed.");
    if (!value.unresolvedFields.empty()) {
        value.runtime.runtimeErrorCode = "recovery_dependency_closure_unverified";
        *result = std::move(value);
        return Fail(error, "recovery_dependency_closure_unverified", "Recovery dependency closure and loadability are not fully verified.");
    }
    value.runtime.mutationEnvironmentValid = true;
    *result = std::move(value); return true;
}
} // namespace

bool SameIdentity(const Identity &a, const Identity &b) {
    return a.configuration == b.configuration && a.policy == b.policy && a.methods == b.methods &&
        a.libraries == b.libraries && a.frontend == b.frontend && a.dependencies == b.dependencies;
}
bool ResolveAuthority(const CydiaRuntime::PackageDatabasePaths &paths, const InitializationOptions &startup,
    const std::string &overridePath, const std::string &preference, const BundleInputs &bundle,
    const Identity *expected, Authority *result, P::Error *error, const DependencyInspector &inspect,
    unsigned timeout, const std::function<bool()> &cancelled) {
    // The public production entry cannot repoint the existing authenticated
    // helper or its private override authority. The isolated fixture resolver
    // below is compiled only into the native test driver.
    if (startup.helperPath != paths.CydoPath() || startup.dpkgPath != paths.CydoPath() ||
        startup.privateRuntimeConfigurationPath != P::ExecutableOverridesPath(paths)) {
        if (result) *result = Authority();
        return Fail(error, "recovery_invalid_request", "Recovery inputs disagree with the installed protected helper.");
    }
    const Resolver resolver = [](const CydiaRuntime::PackageDatabasePaths &p, const std::string &overrideValue, P::Environment *e, P::Error *failure) {
        return P::ResolveCurrentEnvironment(p, overrideValue, e, failure);
    };
    return Resolve(paths, startup, overridePath, preference, bundle, expected, result, error, resolver, inspect, timeout, cancelled);
}
bool RecheckAuthority(const CydiaRuntime::PackageDatabasePaths &paths, const Authority &previous,
    const std::string &preference, const BundleInputs &bundle, P::Error *error, const DependencyInspector &inspect,
    unsigned timeout, const std::function<bool()> &cancelled) {
    Authority current;
    return ResolveAuthority(paths, previous.startup, previous.runtime.aptConfigOverride, preference, bundle,
        &previous.identity, &current, error, inspect, timeout, cancelled);
}
#if defined(CYDIA_RECOVERY_AUTHORITY_TESTING)
bool ResolveAuthorityForTesting(const CydiaRuntime::PackageDatabasePaths &paths, const InitializationOptions &startup,
    const std::string &overridePath, const std::string &preference, const BundleInputs &bundle,
    const Identity *expected, Authority *result, P::Error *error, const FixtureResolver &resolver,
    const DependencyInspector &inspect, unsigned timeout, const std::function<bool()> &cancelled) {
    return Resolve(paths, startup, overridePath, preference, bundle, expected, result, error, resolver, inspect, timeout, cancelled);
}
#endif
}} // namespace CydiaAPT::Recovery
