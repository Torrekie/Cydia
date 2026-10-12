/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryInstalledAuthority.hpp"
#include "Cydia/AptRecoveryDependencyInspector.hpp"
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <pwd.h>
#include <set>
#include <sys/stat.h>
#include <utility>

namespace CydiaAPT { namespace Recovery {
namespace {
namespace P = CydiaRuntime::Privileged;
bool Fail(P::Error *error, const char *code) {
    if (error) { error->code = code; error->message.clear(); } return false;
}
class ExplicitConfiguration {
    bool present_;
    std::string previous_;
public:
    bool valid;
    ExplicitConfiguration() : present_(std::getenv("APT_CONFIG") != nullptr),
        previous_(present_ ? std::getenv("APT_CONFIG") : ""), valid(unsetenv("APT_CONFIG") == 0) {}
    ~ExplicitConfiguration() {
        if (present_) setenv("APT_CONFIG", previous_.c_str(), 1);
        else unsetenv("APT_CONFIG");
    }
};
bool Path(const std::string &s) {
    if (s.empty() || s.front() != '/' || s.size() > 4096 || (s.size() > 1 && s.back() == '/')) return false;
    for (unsigned char c : s) if (c < 32 || c == 127) return false;
    std::size_t start = 1;
    while (start < s.size()) {
        const auto slash = s.find('/', start), n = slash == std::string::npos ? slash : slash - start;
        const auto part = s.substr(start, n);
        if (part.empty() || part == "." || part == "..") return false;
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return true;
}
bool List(const std::string &bytes, std::vector<std::string> *result, std::size_t maximum) {
    if (bytes.size() > 128 * 1024) return false;
    std::size_t cursor = 0; std::set<std::string> unique;
    while (cursor < bytes.size()) {
        std::size_t size = 0, digits = 0;
        while (cursor < bytes.size() && bytes[cursor] >= '0' && bytes[cursor] <= '9') {
            const unsigned digit = bytes[cursor++] - '0';
            if (++digits > 6 || size > (4096 - digit) / 10) return false;
            size = size * 10 + digit;
        }
        if (!digits || cursor == bytes.size() || bytes[cursor++] != ':' || size >= bytes.size() - cursor || size == 0) return false;
        const auto value = bytes.substr(cursor, size); cursor += size;
        if (bytes[cursor++] != ',' || !unique.insert(value).second || result->size() >= maximum) return false;
        result->push_back(value);
    }
    return true;
}
}
bool ParsePayloadInventory(const std::string &bytes, const std::string &worker, BundleInputs *result, P::Error *error) {
    std::vector<std::string> fields; BundleInputs value; value.executable = worker;
    if (!result || bytes.size() > 128 * 1024 || !Path(worker) || !P::ParseFields(bytes, 4, &fields, error) ||
        fields[0] != "CYDIA-RECOVERY-PAYLOAD-1" || !List(fields[1], &value.libraries, 256) ||
        !List(fields[2], &value.dataFiles, 255) || !List(fields[3], &value.requiredMethods, 128) || value.requiredMethods.empty())
        return Fail(error, "recovery_inventory_invalid");
    std::set<std::string> all{worker};
    for (const auto *list : {&value.libraries, &value.dataFiles}) for (const auto &path : *list)
        if (!Path(path) || !all.insert(path).second) return Fail(error, "recovery_inventory_invalid");
    for (const auto &method : value.requiredMethods)
        if (method.size() > 128 || method == "." || method == ".." ||
            method.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._") != std::string::npos)
            return Fail(error, "recovery_inventory_invalid");
    *result = std::move(value); if (error) *error = P::Error(); return true;
}
bool ResolveInstalledAuthority(const CydiaRuntime::PackageDatabasePaths &paths, uid_t uid, const Preferences &preferences,
    const Identity *expected, Authority *result, P::Error *error, const DependencyInspector &inspect,
    unsigned timeout, const std::function<bool()> &cancelled) {
    if (!result) return Fail(error, "recovery_invalid_request");
    *result = Authority();
    if (!ValidatePreferences(preferences) || (expected && SerializeIdentity(*expected).empty()) ||
        timeout == 0 || timeout > 10000 || (cancelled && cancelled())) return Fail(error, "recovery_invalid_request");
    const std::string worker = paths.CydiaHelperPath("cydia-recovery"), manifest = paths.CydiaHelperPath("cydia-recovery.payload");
    struct stat st;
    if (lstat(manifest.c_str(), &st) != 0) return Fail(error, errno == ENOENT ? "recovery_inventory_missing" : "recovery_inventory_unavailable");
    if (st.st_size < 0 || st.st_size > 128 * 1024) return Fail(error, "recovery_inventory_invalid");
    if (!P::ValidateRootOwnedPath(manifest, false, false, error)) return false;
    P::Evidence inventory; BundleInputs bundle;
    if (!P::CaptureEvidence(manifest, false, false, &inventory, error) ||
        !ParsePayloadInventory(inventory.bytes, worker, &bundle, error)) return false;
    if (std::find(bundle.libraries.begin(), bundle.libraries.end(), manifest) != bundle.libraries.end() ||
        std::find(bundle.dataFiles.begin(), bundle.dataFiles.end(), manifest) != bundle.dataFiles.end()) return Fail(error, "recovery_inventory_invalid");
    bundle.dataFiles.push_back(manifest);
    // passwd is read in the authenticated helper; a worker cannot choose a
    // different user's writable cache or fabricate a mobile home directory.
    struct passwd entry, *found = nullptr; std::vector<char> storage(32768);
    if (getpwuid_r(uid, &entry, storage.data(), storage.size(), &found) != 0 || !found || !entry.pw_dir || !Path(entry.pw_dir))
        return Fail(error, "recovery_home_unavailable");
    const std::string home(entry.pw_dir), cache = home + "/Library/Caches/com.saurik.Cydia";
    InitializationOptions startup;
    startup.architecture = paths.AptArchitecture(); startup.aptConfigDirectory = paths.AptConfigDirectory();
    startup.methodsDirectory = paths.CydiaHelperPath("recovery-methods"); startup.cacheDirectory = cache; startup.stateDirectory = cache;
    startup.listsDirectory = cache + "/lists"; startup.logDirectory = home + "/Library/Logs/Cydia";
    startup.dpkgStatusPath = paths.DpkgStatusPath(); startup.bootstrapExtendedStatesPath = paths.AptExtendedStatesPath();
    startup.dpkgPath = paths.CydoPath(); startup.nativeDpkgPath = paths.DpkgBinaryPath(); startup.helperPath = paths.CydoPath();
    startup.packageInstallPrefix = paths.layout() == CydiaRuntime::PackageDatabaseLayout::Rootless ? "/var/jb" : "/";
    startup.privateRuntimeConfigurationPath = P::ExecutableOverridesPath(paths); startup.dpkgDataDirectory = paths.DpkgDataDirectory();
    startup.dpkgExecutableSearchPath = paths.DpkgExecutableSearchPath(); startup.translation = preferences.translation;
    startup.languages = preferences.languages; startup.maxParallel = preferences.maxParallel; startup.forceEssential = preferences.forceEssential;
    // This entry is used only in the serialized authenticated helper. Ambient
    // APT_CONFIG is never allowed to bypass its explicit protected input.
    ExplicitConfiguration configurationEnvironment;
    if (!configurationEnvironment.valid) return Fail(error, "recovery_environment_unavailable");
    const DependencyInspector inspector(inspect ? inspect : DependencyInspector(InspectInstalledDependencies));
    const bool resolved = ResolveAuthority(paths, startup, preferences.aptConfigOverride, preferences.securityPreference,
        bundle, expected, result, error, inspector, timeout, cancelled);
    // ResolveAuthority fingerprints the manifest with the other data. Retain
    // the independently parsed bytes as evidence too, closing a parse/hash race.
    P::Error check;
    if (!P::RecheckEvidence(std::vector<P::Evidence>{inventory}, &check)) { *result = Authority(); if (error) *error = check; return false; }
    if (resolved || !result->unresolvedFields.empty()) result->environment.evidence.push_back(std::move(inventory));
    return resolved;
}
}} // namespace CydiaAPT::Recovery
