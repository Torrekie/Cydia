/* No query, script execution or provider authority is created here.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderInstalledScripts.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/RuntimeState.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cerrno>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
std::string Key(const ExecutionPackage &package) { return package.package + ':' + package.architecture; }
void Frame(std::string *bytes, const std::string &value) { *bytes += std::to_string(value.size()) + ':' + value + ','; }
std::string Hash(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM);
    return hash.Add(bytes.data(), bytes.size()) ? hash.GetHashString(Hashes::SHA256SUM).HashValue() : "";
}
std::string Trim(const std::string &text) {
    const auto start = text.find_first_not_of(" \t\r\n\v\f");
    return start == std::string::npos ? "" : text.substr(start, text.find_last_not_of(" \t\r\n\v\f") - start + 1);
}
bool Cancelled(const std::function<bool()> &cancelled, std::string *error) {
    if (!cancelled || !cancelled()) return false;
    Fail(error, "provider_installed_scripts_cancelled"); return true;
}
// Bound allocation before the shared protected-file reader. It independently
// opens/rechecks ownership; the post-read limit also covers a growing file.
bool Script(const std::string &path, P::Evidence *result, std::string *error) {
    struct stat named;
    if (lstat(path.c_str(), &named) == 0) {
        if (!S_ISREG(named.st_mode) || named.st_nlink != 1 || named.st_size < 0 ||
            static_cast<std::uint64_t>(named.st_size) > MaximumInstalledScriptBytes)
            return Fail(error, "provider_installed_script_unsupported");
    } else if (errno != ENOENT) return Fail(error, "provider_installed_script_unavailable");
    P::Error ignored;
    if (!P::CaptureAdminEvidence(path, false, true, result, &ignored))
        return Fail(error, "provider_installed_script_unavailable");
    if (!result->absent && (result->bytes.size() > MaximumInstalledScriptBytes ||
        result->identity.st_nlink != 1 || lstat(path.c_str(), &named) != 0 || !S_ISREG(named.st_mode) ||
        named.st_dev != result->identity.st_dev || named.st_ino != result->identity.st_ino))
        return Fail(error, "provider_installed_script_changed");
    return true;
}
bool ScriptStillNamed(const P::Evidence &file) {
    struct stat named;
    if (lstat(file.path.c_str(), &named) != 0) return file.absent && errno == ENOENT;
    return !file.absent && S_ISREG(named.st_mode) && named.st_nlink == 1 &&
        named.st_dev == file.identity.st_dev && named.st_ino == file.identity.st_ino;
}
}
bool CaptureInstalledScripts(const P::Environment &environment, const DpkgState &state,
    const TriggerCaptureLock &lock, const std::vector<ExecutionPackage> &targets,
    InstalledScriptMetadata *metadata, std::string *error, const std::function<bool()> &cancelled,
    const TriggerStateSnapshot &snapshot) {
    if (!metadata) return Fail(error, "provider_installed_scripts_invalid");
    *metadata = InstalledScriptMetadata(); if (error) error->clear();
    if (targets.empty()) return true;
    if (geteuid() != 0 || !TriggerCaptureLockHeld(environment, lock)) return Fail(error, "provider_frontend_lock_missing");
    if (targets.size() > MaximumTriggerEffectPackages) return Fail(error, "provider_installed_scripts_limit");
    if (Cancelled(cancelled, error)) return false;
    P::Error ignored; std::string before, after;
    const auto readState = [&](std::string *value) {
        return snapshot ? snapshot(value, error) : P::RuntimeSnapshot(environment, value, &ignored);
    };
    if (state.packageStateIdentity.empty() || !readState(&before) || before != state.packageStateIdentity)
        return Fail(error, "provider_installed_scripts_changed");
    InstalledScriptMetadata result; P::Evidence status, info, format, upgrading;
    const std::string directory = environment.dpkgAdmin + "/info";
    if (!P::CaptureAdminEvidence(environment.dpkgAdmin + "/status", false, false, &status, &ignored) ||
        !P::CapturePathIdentity(directory, true, false, &info, &ignored, true) ||
        !P::CaptureAdminEvidence(directory + "/format", false, true, &format, &ignored) ||
        !P::CaptureAdminEvidence(directory + "/format-new", false, true, &upgrading, &ignored) || !upgrading.absent)
        return Fail(error, "provider_installed_scripts_unavailable");
    const std::string version = format.absent ? "0" : Trim(format.bytes);
    if (version != "0" && version != "1") return Fail(error, "provider_installed_scripts_format_unsupported");
    std::map<std::string, TriggerPackageMetadata> controls;
    if (!ParseInstalledTriggerControl(status.bytes, state, &controls, error)) return false;
    result.files = {status, info, format, upgrading};
    std::set<std::string> selected; std::size_t total = 0;
    std::vector<ExecutionPackage> ordered(targets);
    std::sort(ordered.begin(), ordered.end(), [](const ExecutionPackage &a, const ExecutionPackage &b) { return Key(a) < Key(b); });
    for (const auto &target : ordered) {
        if (Cancelled(cancelled, error)) return false;
        const auto key = Key(target);
        const auto found = controls.find(key);
        const auto current = state.packages.find(key);
        if (found == controls.end() || current == state.packages.end() ||
            current->second.status == DpkgPackageStatus::NotInstalled || target.version.empty() ||
            found->second.package.version != target.version || result.packages.count(key))
            return Fail(error, "provider_installed_scripts_target_changed");
        InstalledPackageScripts package; package.package = found->second.package; package.configVersion = found->second.configVersion;
        package.diskStatus = found->second.diskStatus;
        const bool qualified = version == "1" && found->second.controls.at("multi-arch") == "same";
        std::string bytes("CYDIA-INSTALLED-PACKAGE-SCRIPTS-1");
        for (const auto &value : {package.package.package, package.package.version, package.package.architecture, package.configVersion}) Frame(&bytes, value);
        Frame(&bytes, version);
        Frame(&bytes, std::to_string(static_cast<unsigned>(package.diskStatus)));
        for (const char *name : {"prerm", "postinst"}) {
            P::Evidence plain, arch;
            if (!Script(directory + '/' + target.package + '.' + name, &plain, error) ||
                !Script(directory + '/' + key + '.' + name, &arch, error)) return false;
            const auto &chosen = qualified ? arch : plain, &other = qualified ? plain : arch;
            if (!other.absent || !selected.insert(chosen.path).second) return Fail(error, "provider_installed_scripts_ambiguous");
            if (chosen.bytes.size() > MaximumInstalledScriptsBytes - total) return Fail(error, "provider_installed_scripts_limit");
            total += chosen.bytes.size();
            if (std::string(name) == "prerm") package.prerm = chosen; else package.postinst = chosen;
            Frame(&bytes, chosen.path);
            Frame(&bytes, P::SerializeSnapshotEvidence(plain)); Frame(&bytes, P::SerializeSnapshotEvidence(arch));
            result.files.push_back(std::move(plain)); result.files.push_back(std::move(arch));
        }
        package.evidenceIdentity = Hash(bytes);
        if (package.evidenceIdentity.size() != 64) return Fail(error, "provider_installed_scripts_hash_failed");
        result.packages.emplace(key, std::move(package));
    }
    if (Cancelled(cancelled, error)) return false;
    if (!readState(&after) || before != after || !P::RecheckEvidence(result.files, &ignored) ||
        !TriggerCaptureLockHeld(environment, lock)) return Fail(error, "provider_installed_scripts_changed");
    for (std::size_t i = 4; i < result.files.size(); ++i)
        if (!ScriptStillNamed(result.files[i])) return Fail(error, "provider_installed_scripts_changed");
    std::string bytes("CYDIA-INSTALLED-SCRIPTS-1"); Frame(&bytes, after);
    for (const auto &file : result.files) Frame(&bytes, P::SerializeSnapshotEvidence(file));
    for (const auto &package : result.packages) { Frame(&bytes, package.first); Frame(&bytes, package.second.evidenceIdentity); }
    result.packageStateIdentity = after; result.evidenceIdentity = Hash(bytes);
    if (result.evidenceIdentity.size() != 64) return Fail(error, "provider_installed_scripts_hash_failed");
    if (Cancelled(cancelled, error)) return false;
    *metadata = std::move(result); if (error) error->clear(); return true;
}
}} // namespace CydiaAPT::Provider
