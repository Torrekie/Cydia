/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/AptProviderTriggerEvidence.hpp"
#include "Cydia/SourceDocumentStore.hpp"
#include <algorithm>
#include <set>
#include <sstream>

namespace CydiaRuntime { namespace Privileged {
namespace {
bool Fail(Error *error, const char *code, const char *message) {
    if (error != NULL) { error->code = code; error->message = message; }
    return false;
}
bool Suffix(const std::string &value, const std::string &ending) {
    return value.size() >= ending.size() && value.compare(value.size() - ending.size(), ending.size(), ending) == 0;
}
bool PinName(const std::string &name) {
    // APT ReadPinDir accepts run-parts names with .pref or no extension.
    if (name.empty() || name[0] == '.' || name.back() == '.') return false;
    for (char c : name)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '_' || c == '-' || c == ':' || c == '.')) return false;
    return name.find('.') == std::string::npos || Suffix(name, ".pref");
}
std::string Lower(std::string value) {
    for (char &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}
void SignedByFiles(const CydiaSources::Definition &definition, CydiaSources::Format format, std::set<std::string> *paths) {
    if (!definition.enabled) return;
    for (const auto &field : definition.fields) {
        if ((format == CydiaSources::Format::Deb822 ? Lower(field.name) : field.name) != "signed-by" ||
            field.value.find("-----BEGIN PGP PUBLIC KEY BLOCK-----") != std::string::npos) continue;
        // APT normalizes ASCII whitespace to commas before extracting absolute
        // keyring paths. Other tokens are fingerprints, never relative files.
        std::string value(field.value);
        for (char &c : value) if (c == ',' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v') c = ' ';
        std::istringstream tokens(value); std::string token;
        while (tokens >> token) if (!token.empty() && token[0] == '/') paths->insert(token);
    }
}
bool TriggerInputs(const Environment &environment, SnapshotCapture capture,
                   std::vector<Evidence> *inputs, Error *error) {
    namespace T = CydiaAPT::Provider;
    if (capture == CaptureEvidence) {
        std::string reason; bool synchronized = false;
        if (T::CaptureProtectedTriggerFiles(environment, inputs, &synchronized, &reason)) return true;
        if (error) { error->code = reason; error->message = "Cannot capture the native dpkg trigger state."; }
        return false;
    }
    // The existing injected reader is data-only fixture coverage, never a way
    // for production callers to claim a native lock or authorize trigger work.
    const std::string path = environment.dpkgAdmin + "/triggers";
    Evidence directory;
    if (!capture(path, true, true, &directory, error)) return false;
    directory.adminAccess = true; inputs->push_back(directory);
    if (directory.absent) return true;
    if (directory.entries.size() > T::MaximumTriggerRegistryFiles)
        return Fail(error, "provider_trigger_evidence_limit", "The native trigger registry exceeds the reader limits.");
    std::size_t remaining = T::MaximumTriggerEvidenceBytes;
    std::set<std::string> names;
    for (const auto &name : directory.entries) {
        if (name.empty() || name.size() > 256 || name == "." || name == ".." ||
            name.find('/') != std::string::npos || !names.insert(name).second)
            return Fail(error, "provider_trigger_input_invalid", "Invalid native trigger registry membership.");
        Evidence file;
        if (!capture(path + '/' + name, false, false, &file, error)) return false;
        if (file.bytes.size() > remaining || (name == "Unincorp" && file.bytes.size() > T::MaximumDeferredTriggerBytes))
            return Fail(error, "provider_trigger_evidence_limit", "The native trigger registry exceeds the reader limits.");
        remaining -= file.bytes.size(); file.adminAccess = true; inputs->push_back(file);
    }
    for (const char *name : {"File", "Unincorp", "Lock"}) {
        if (names.count(name)) continue;
        Evidence file;
        if (!capture(path + '/' + name, false, true, &file, error)) return false;
        if (!file.absent) return Fail(error, "provider_trigger_state_changed", "The native trigger registry changed.");
        file.adminAccess = true; inputs->push_back(file);
    }
    return true;
}
}
bool CaptureSnapshotInputs(const Environment &environment, SnapshotScope scope,
                          std::vector<Evidence> *inputs, Error *error, SnapshotCapture capture, SnapshotCapture sharedCapture, SnapshotCapture sourceCapture) {
    if (inputs == NULL || capture == NULL || sharedCapture == NULL || sourceCapture == NULL) return false;
    *inputs = environment.evidence;
    std::set<std::pair<std::string, bool> > seen;
    for (const auto &input : *inputs) if (!input.identityOnly) seen.insert({input.path, input.directory});
    const auto add = [&](const std::string &path, bool directory, bool absent, bool sharedState = false, bool sourceInput = false, bool adminAccess = false) {
        if (path.empty() || path == "/dev/null") return true;
        if (!seen.insert({path, directory}).second) {
            // Overlapping configured roles retain the stricter policy. A pin
            // path must never downgrade a keyring or hook configuration input.
            for (auto &existing : *inputs)
                if (existing.path == path && existing.directory == directory && (existing.sharedState || existing.sourceInput || existing.adminAccess) &&
                    (existing.sharedState != sharedState || existing.sourceInput != sourceInput || existing.adminAccess != adminAccess))
                    return capture(path, directory, absent, &existing, error);
            return true;
        }
        Evidence input;
        if (sourceInput && sourceCapture == CaptureSourceEvidence) {
            if (!CaptureSourceEvidenceForReader(path, directory, absent, &input, error,
                                               environment.sourceReaderUID, environment.sourceReaderGID, environment.sourceReaderGroups)) return false;
        } else if (!(sourceInput ? sourceCapture : sharedState ? sharedCapture :
                     adminAccess && capture == CaptureEvidence ? CaptureAdminEvidence : capture)(path, directory, absent, &input, error)) return false;
        input.sharedState = sharedState; input.sourceInput = sourceInput; input.adminAccess = adminAccess;
        inputs->push_back(input); return true;
    };
    if (scope == SnapshotScope::PackageState &&
        (!add(environment.dpkgAdmin + "/status", false, false, true) ||
         !add(environment.dpkgAdmin + "/arch", false, true, false, false, true) ||
         !add(environment.dpkgAdmin + "/updates", true, true, false, false, true) ||
         !add(environment.extendedStates, false, true, true) ||
         !add(environment.preferences, false, true, true) ||
         !add(environment.preferencesParts, true, true))) return false;
    if (scope == SnapshotScope::PackageState) {
        std::vector<Evidence> triggers;
        if (!TriggerInputs(environment, capture, &triggers, error)) return false;
        for (const auto &input : triggers) {
            // Lock is synchronization, not registry data. Generic evidence
            // rechecks reopen files; closing that inode could drop another
            // thread's POSIX capture lock. Membership still binds its presence.
            if (input.path == environment.dpkgAdmin + "/triggers/Lock") continue;
            if (seen.insert({input.path, input.directory}).second) inputs->push_back(input);
            else if (!add(input.path, input.directory, input.absent, false, false, true)) return false;
        }
    }
    if (!add(environment.sourceList, false, true, false, true) || !add(environment.sourceParts, true, true) ||
        !add(environment.trusted, false, true) || !add(environment.trustedParts, true, true)) return false;
    // Directory evidence includes membership, so additions, deletions and
    // renames invalidate review even when existing documents stay unchanged.
    for (const auto &input : std::vector<Evidence>(*inputs)) {
        if (!input.directory || input.absent || input.identityOnly) continue;
        const bool journal = scope == SnapshotScope::PackageState && input.path == environment.dpkgAdmin + "/updates";
        const bool pins = scope == SnapshotScope::PackageState && input.path == environment.preferencesParts;
        const bool keys = input.path == environment.trustedParts;
        const bool sources = input.path == environment.sourceParts;
        for (const auto &entry : input.entries) {
            const bool key = keys && (Suffix(entry, ".gpg") || Suffix(entry, ".asc"));
            const bool pin = pins && PinName(entry);
            const bool source = sources && CydiaSources::IsEffectiveDestination({environment.sourceList, environment.sourceParts}, input.path + '/' + entry);
            if ((journal || pin || key || source) &&
                !add(input.path + '/' + entry, false, false, (journal || pin) && !key && !source, source && !key && !journal && !pin)) return false;
        }
    }
    std::set<std::string> scopedKeys;
    std::size_t count = 0;
    for (const auto &input : *inputs) {
        if (input.directory || input.absent || !CydiaSources::IsEffectiveDestination({environment.sourceList, environment.sourceParts}, input.path)) continue;
        if (++count > 4096 || input.bytes.size() > 4 * 1024 * 1024)
            return Fail(error, "source_snapshot_failed", "The source configuration exceeds the reader limits.");
        const auto format(Suffix(input.path, ".sources") ? CydiaSources::Format::Deb822 : CydiaSources::Format::OneLine);
        const auto document(CydiaSources::ParseDocument(input.path, format, input.bytes));
        if (!document.valid()) return Fail(error, "source_snapshot_failed", "The source configuration is malformed or ambiguous.");
        for (const auto &definition : document.definitions) SignedByFiles(definition, format, &scopedKeys);
    }
    for (const auto &path : scopedKeys) if (!add(path, false, true)) return false;
    return true;
}
std::string SerializeSnapshotEvidence(const Evidence &evidence) {
    const auto &st(evidence.identity);
    std::ostringstream identity;
    identity << evidence.absent << ' ' << evidence.directory << ' ' << evidence.sharedState << ' ' << evidence.sourceInput << ' ' << evidence.adminAccess << ' ' << st.st_dev << ' ' << st.st_ino << ' '
        << st.st_uid << ' ' << st.st_gid << ' ' << st.st_mode << ' ';
    // Lock-file creation changes admin/root directory metadata without changing
    // their canonical identity. Mutable state is captured separately.
    if (!(evidence.directory && evidence.identityOnly)) {
        identity << st.st_size << ' ';
#ifdef __APPLE__
        identity << st.st_mtimespec.tv_sec << ' ' << st.st_mtimespec.tv_nsec << ' '
            << st.st_ctimespec.tv_sec << ' ' << st.st_ctimespec.tv_nsec;
#else
        identity << st.st_mtim.tv_sec << ' ' << st.st_mtim.tv_nsec << ' '
            << st.st_ctim.tv_sec << ' ' << st.st_ctim.tv_nsec;
#endif
    }
    std::vector<std::string> groups;
    for (const auto group : evidence.sourceReaderGroups.values) groups.push_back(std::to_string(group));
    return SerializeFields({evidence.path, identity.str(), evidence.bytes, SerializeFields(evidence.entries),
                            evidence.sourceDelegation, std::to_string(evidence.sourceReaderUID), std::to_string(evidence.sourceReaderGID),
                            evidence.sourceReaderGroups.valid ? "1" : "0", SerializeFields(groups)});
}
} }
