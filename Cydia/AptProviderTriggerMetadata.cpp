/* Native installed declaration/control evidence, without executing dpkg.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEffects.hpp"
#include "Cydia/ExtendedState.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/RuntimeState.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <fcntl.h>
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
bool NativeTrigger(const std::string &name) {
    if (name.empty() || name.size() > 2046) return false;
    for (unsigned char c : name) if (c <= 32 || c >= 127) return false;
    // Unknown activation kinds are ignored by dpkg; they are deliberately not
    // accepted as evidence of a bounded native effect here.
    TriggerRegistryInput input; input.directoryPresent = true;
    if (name[0] == '/') input.files["File"] = name + " cydia\n";
    else input.files[name] = "cydia\n";
    TriggerRegistryState parsed; std::string ignored;
    return ParseTriggerRegistry(input, &parsed, &ignored) && parsed.interests.size() == 1;
}
bool LockHeld(const P::Environment &environment, const TriggerCaptureLock &proof) {
    P::Error ignored;
    if (proof.parent > 1 && proof.descriptor < 0) {
        pid_t owner = 0;
        return getppid() == proof.parent && P::FrontendLockOwner(environment.dpkgAdmin, &owner, &ignored) && owner == proof.parent;
    }
    if (proof.descriptor < 3 || proof.parent != 0) return false;
    const std::string path = environment.dpkgAdmin + "/lock-frontend";
    struct stat opened, named;
    if (!P::ValidateDpkgAdminPath(path, false, &ignored) || fstat(proof.descriptor, &opened) != 0 ||
        lstat(path.c_str(), &named) != 0 || !S_ISREG(named.st_mode) || named.st_nlink != 1 ||
        opened.st_dev != named.st_dev || opened.st_ino != named.st_ino ||
        opened.st_uid != named.st_uid || opened.st_mode != named.st_mode) return false;
    struct flock lock = {}; lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
    return fcntl(proof.descriptor, F_SETLK, &lock) == 0;
}
bool Cancelled(const std::function<bool()> &cancelled, std::string *error) {
    if (!cancelled || !cancelled()) return false;
    Fail(error, "provider_trigger_capture_cancelled"); return true;
}
std::string MetadataIdentity(const TriggerPackageMetadata &metadata, const P::Evidence &declaration) {
    std::string bytes("CYDIA-INSTALLED-TRIGGER-PACKAGE-1");
    for (const auto &value : {metadata.package.package, metadata.package.version, metadata.package.architecture}) Frame(&bytes, value);
    for (const auto &control : metadata.controls) { Frame(&bytes, control.first); Frame(&bytes, control.second); }
    Frame(&bytes, P::SerializeSnapshotEvidence(declaration)); return Hash(bytes);
}
}
bool ParseTriggerDeclarations(const std::string &bytes, std::vector<TriggerDeclaration> *declarations, std::string *error) {
    if (!declarations) return Fail(error, "provider_trigger_declarations_invalid");
    declarations->clear(); if (error) error->clear();
    if (bytes.size() > 1024 * 1024 || bytes.find('\0') != std::string::npos)
        return Fail(error, "provider_trigger_declarations_invalid");
    std::map<std::pair<TriggerDeclarationKind, std::string>, bool> records;
    std::size_t cursor = 0, count = 0;
    while (cursor < bytes.size()) {
        const auto end = bytes.find('\n', cursor);
        if (end == std::string::npos || end - cursor > 2046) return Fail(error, "provider_trigger_declarations_invalid");
        const std::string line = Trim(bytes.substr(cursor, end - cursor)); cursor = end + 1;
        if (line.empty() || line[0] == '#') continue;
        if (++count > MaximumTriggerRelations) return Fail(error, "provider_trigger_evidence_limit");
        const auto split = line.find_first_of(" \t\r\v\f");
        if (split == std::string::npos) return Fail(error, "provider_trigger_declarations_invalid");
        const std::string directive = line.substr(0, split), trigger = Trim(line.substr(split));
        if (!NativeTrigger(trigger)) return Fail(error, "provider_trigger_declarations_unsupported");
        const bool interest = directive == "interest" || directive == "interest-await" || directive == "interest-noawait";
        const bool activate = directive == "activate" || directive == "activate-await" || directive == "activate-noawait";
        if (!interest && !activate) return Fail(error, "provider_trigger_declarations_unsupported");
        const bool await = directive != "interest-noawait" && directive != "activate-noawait";
        const auto key = std::make_pair(interest ? TriggerDeclarationKind::Interest : TriggerDeclarationKind::Activate, trigger);
        // Native interest updates are last-wins. Repeated activations combine:
        // any awaited activation retains the possible waiter relation.
        if (interest || !records.count(key)) records[key] = await;
        else records[key] = records[key] || await;
    }
    for (const auto &record : records) {
        TriggerDeclaration declaration; declaration.kind = record.first.first;
        declaration.trigger = record.first.second; declaration.await = record.second;
        declarations->push_back(declaration);
    }
    return true;
}
bool ParseInstalledTriggerControl(const std::string &status, const DpkgState &state,
    std::map<std::string, TriggerPackageMetadata> *packages, std::string *error) {
    if (!packages) return Fail(error, "provider_trigger_control_invalid");
    packages->clear(); if (error) error->clear();
    if (status.size() > MaximumTriggerEvidenceBytes || status.find('\0') != std::string::npos ||
        state.packages.size() > MaximumTriggerEffectPackages) return Fail(error, "provider_trigger_evidence_limit");
    std::map<std::string, TriggerPackageMetadata> result;
    std::map<std::string, std::string> fields; std::string previous;
    const auto record = [&]() {
        if (fields.empty()) return true;
        const auto name = fields.find("package"), architecture = fields.find("architecture"), version = fields.find("version");
        if (name == fields.end()) return false;
        // Forgotten selections can have no installed binary metadata.
        if (architecture == fields.end() || version == fields.end()) {
            const auto found = state.packages.find(name->second + ':');
            return found != state.packages.end() && found->second.status == DpkgPackageStatus::NotInstalled;
        }
        const auto key = name->second + ':' + architecture->second;
        const auto found = state.packages.find(key);
        if (found == state.packages.end() || found->second.package.version != version->second ||
            !CydiaRuntime::ValidPackageName(name->second) || !CydiaRuntime::ValidArchitectureName(architecture->second)) return false;
        // Read-only dpkg-query can incorporate deferred triggers in memory,
        // changing its trigger status/lists but never selection/error flags.
        const char *selections[] = {"unknown", "install", "hold", "deinstall", "purge"};
        const auto statusField = fields.find("status");
        if (static_cast<unsigned>(found->second.selection) >= 5 || statusField == fields.end()) return false;
        const std::string prefix = std::string(selections[static_cast<unsigned>(found->second.selection)]) +
            (found->second.reinstallRequired ? " reinstreq " : " ok ");
        if (statusField->second.compare(0, prefix.size(), prefix) != 0) return false;
        TriggerPackageMetadata metadata; metadata.package = found->second.package;
        std::string ignored;
        if (!CydiaPackages::CanonicalPackageEffectControlFields(fields, &metadata.controls, &ignored)) return false;
        const auto &multi = metadata.controls["multi-arch"];
        if (multi != (found->second.multiArch.empty() ? "no" : found->second.multiArch)) return false;
        for (const char *field : {"essential", "protected"})
            if (metadata.controls[field] != "no" && metadata.controls[field] != "yes") return false;
        return result.emplace(key, std::move(metadata)).second;
    };
    std::size_t cursor = 0;
    while (cursor < status.size()) {
        const auto end = status.find('\n', cursor);
        if (end == std::string::npos || end - cursor > 1024 * 1024) return Fail(error, "provider_trigger_control_invalid");
        std::string line = status.substr(cursor, end - cursor); cursor = end + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) { if (!record()) return Fail(error, "provider_trigger_control_changed"); fields.clear(); previous.clear(); continue; }
        if (line[0] == ' ' || line[0] == '\t') {
            if (previous.empty()) return Fail(error, "provider_trigger_control_invalid");
            fields[previous] += ' ' + Trim(line); continue;
        }
        const auto colon = line.find(':');
        if (colon == std::string::npos || colon == 0) return Fail(error, "provider_trigger_control_invalid");
        previous = line.substr(0, colon);
        for (char &c : previous) { if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return Fail(error, "provider_trigger_control_invalid"); }
        if (!fields.emplace(previous, Trim(line.substr(colon + 1))).second) return Fail(error, "provider_trigger_control_invalid");
    }
    if (!record()) return Fail(error, "provider_trigger_control_changed");
    for (const auto &package : state.packages)
        if (!package.second.package.version.empty() && !result.count(package.first)) return Fail(error, "provider_trigger_control_changed");
    *packages = std::move(result); return true;
}
bool CaptureInstalledTriggerMetadata(const P::Environment &environment, const DpkgState &state,
    const TriggerCaptureLock &lock, InstalledTriggerMetadata *metadata, std::string *error,
    const std::function<bool()> &cancelled, const TriggerStateSnapshot &snapshot) {
    if (!metadata) return Fail(error, "provider_trigger_control_invalid");
    *metadata = InstalledTriggerMetadata();
    P::Error ignored; std::string before, after;
    const auto readState = [&](std::string *value) {
        return snapshot ? snapshot(value, error) : P::RuntimeSnapshot(environment, value, &ignored);
    };
    if (!LockHeld(environment, lock)) return Fail(error, "provider_frontend_lock_missing");
    if (Cancelled(cancelled, error)) return false;
    if (!readState(&before) || before != state.packageStateIdentity)
        return Fail(error, "provider_trigger_state_changed");
    InstalledTriggerMetadata result; P::Evidence status, info, format, upgrading;
    const std::string directory = environment.dpkgAdmin + "/info";
    if (!P::CaptureAdminEvidence(environment.dpkgAdmin + "/status", false, false, &status, &ignored) ||
        !P::CapturePathIdentity(directory, true, false, &info, &ignored, true) ||
        !P::CaptureAdminEvidence(directory + "/format", false, true, &format, &ignored) ||
        !P::CaptureAdminEvidence(directory + "/format-new", false, true, &upgrading, &ignored) || !upgrading.absent)
        return Fail(error, "provider_trigger_control_unavailable");
    const auto version = format.absent ? "0" : Trim(format.bytes);
    if (version != "0" && version != "1") return Fail(error, "provider_trigger_control_format_unsupported");
    if (!ParseInstalledTriggerControl(status.bytes, state, &result.packages, error)) return false;
    result.files = {status, info, format, upgrading};
    std::set<std::string> selected; std::size_t bytes = status.bytes.size();
    for (auto &package : result.packages) {
        if (Cancelled(cancelled, error)) return false;
        const auto &identity = package.second.package;
        const std::string plain = directory + '/' + identity.package + ".triggers";
        const std::string qualified = directory + '/' + Key(identity) + ".triggers";
        P::Evidence a, b;
        if (!P::CaptureAdminEvidence(plain, false, true, &a, &ignored) ||
            !P::CaptureAdminEvidence(qualified, false, true, &b, &ignored) || (!a.absent && !b.absent))
            return Fail(error, "provider_trigger_control_ambiguous");
        const bool useArchitecture = version == "1" && package.second.controls.at("multi-arch") == "same";
        const auto &chosen = useArchitecture ? b : a;
        const auto &other = useArchitecture ? a : b;
        if (!other.absent || !selected.insert(chosen.path).second) return Fail(error, "provider_trigger_control_ambiguous");
        if (chosen.bytes.size() > MaximumTriggerEvidenceBytes - bytes) return Fail(error, "provider_trigger_evidence_limit");
        bytes += chosen.bytes.size();
        if (!ParseTriggerDeclarations(chosen.bytes, &package.second.declarations, error)) return false;
        package.second.evidenceIdentity = MetadataIdentity(package.second, chosen);
        if (package.second.evidenceIdentity.size() != 64) return Fail(error, "provider_trigger_hash_failed");
        result.files.push_back(a); result.files.push_back(b);
    }
    if (Cancelled(cancelled, error)) return false;
    if (!LockHeld(environment, lock) || !P::RecheckEvidence(result.files, &ignored) ||
        !readState(&after) || before != after)
        return Fail(error, "provider_trigger_state_changed");
    std::string bytesToHash("CYDIA-INSTALLED-TRIGGER-METADATA-1");
    for (const auto &file : result.files) Frame(&bytesToHash, P::SerializeSnapshotEvidence(file));
    result.packageStateIdentity = after; result.evidenceIdentity = Hash(bytesToHash);
    if (result.evidenceIdentity.size() != 64) return Fail(error, "provider_trigger_hash_failed");
    *metadata = std::move(result); if (error) error->clear(); return true;
}
bool CaptureTriggerEffectCheckpoint(const P::Environment &environment, const DpkgState &state,
    const TriggerCaptureLock &lock, TriggerEffectCheckpoint *checkpoint, std::string *error,
    const std::function<bool()> &cancelled, const TriggerStateSnapshot &snapshot) {
    if (!checkpoint) return Fail(error, "provider_trigger_checkpoint_invalid");
    *checkpoint = TriggerEffectCheckpoint(); TriggerEffectCheckpoint result; result.packages = state;
    if (!LockHeld(environment, lock)) return Fail(error, "provider_frontend_lock_missing");
    if (!CaptureProtectedTriggerEvidence(environment, &result.registry, error, cancelled) || !result.registry.synchronized)
        return Fail(error, "provider_trigger_evidence_unadmitted");
    if (!CaptureInstalledTriggerMetadata(environment, state, lock, &result.metadata, error, cancelled, snapshot) ||
        !RecheckProtectedTriggerEvidence(environment, result.registry, error, cancelled) || !LockHeld(environment, lock)) return false;
    result.identity = TriggerEffectCheckpointIdentity(result);
    if (result.identity.empty()) return Fail(error, "provider_trigger_checkpoint_invalid");
    *checkpoint = std::move(result); return true;
}
}} // namespace CydiaAPT::Provider
