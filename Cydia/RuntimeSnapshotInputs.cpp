/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeSnapshotInputs.hpp"
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
}
bool CaptureSnapshotInputs(const Environment &environment, SnapshotScope scope,
                          std::vector<Evidence> *inputs, Error *error, SnapshotCapture capture) {
    if (inputs == NULL || capture == NULL) return false;
    *inputs = environment.evidence;
    std::set<std::pair<std::string, bool> > seen;
    for (const auto &input : *inputs) if (!input.identityOnly) seen.insert({input.path, input.directory});
    const auto add = [&](const std::string &path, bool directory, bool absent) {
        if (path.empty() || path == "/dev/null" || !seen.insert({path, directory}).second) return true;
        Evidence input;
        if (!capture(path, directory, absent, &input, error)) return false;
        inputs->push_back(input); return true;
    };
    if (scope == SnapshotScope::PackageState &&
        (!add(environment.dpkgAdmin + "/status", false, false) ||
         !add(environment.dpkgAdmin + "/updates", true, true) ||
         !add(environment.extendedStates, false, true) ||
         !add(environment.preferences, false, true) ||
         !add(environment.preferencesParts, true, true))) return false;
    if (!add(environment.sourceList, false, true) || !add(environment.sourceParts, true, true) ||
        !add(environment.trusted, false, true) || !add(environment.trustedParts, true, true)) return false;
    // Directory evidence includes membership, so additions, deletions and
    // renames invalidate review even when existing documents stay unchanged.
    for (const auto &input : std::vector<Evidence>(*inputs)) {
        if (!input.directory || input.absent || input.identityOnly) continue;
        const bool journal = scope == SnapshotScope::PackageState && input.path == environment.dpkgAdmin + "/updates";
        const bool pins = scope == SnapshotScope::PackageState && input.path == environment.preferencesParts;
        const bool keys = input.path == environment.trustedParts;
        for (const auto &entry : input.entries)
            if ((journal || (pins && PinName(entry)) || (keys && (Suffix(entry, ".gpg") || Suffix(entry, ".asc")))) &&
                !add(input.path + '/' + entry, false, false)) return false;
    }
    const auto sources(CydiaSources::ReadEffectiveDocuments({environment.sourceList, environment.sourceParts}));
    if (!sources.ready()) return Fail(error, "source_snapshot_failed", "Cannot read the actual APT source configuration.");
    std::set<std::string> scopedKeys;
    for (const auto &stored : sources.documents) {
        if (!add(stored.document.path, false, false)) return false;
        const auto captured = std::find_if(inputs->begin(), inputs->end(), [&](const Evidence &input) {
            return !input.directory && input.path == stored.document.path;
        });
        if (captured == inputs->end() || captured->bytes != stored.document.bytes)
            return Fail(error, "stale_environment", "The source configuration changed while being read.");
        for (const auto &definition : stored.document.definitions) SignedByFiles(definition, stored.document.format, &scopedKeys);
    }
    for (const auto &path : scopedKeys) if (!add(path, false, true)) return false;
    return true;
}
std::string SerializeSnapshotEvidence(const Evidence &evidence) {
    const auto &st(evidence.identity);
    std::ostringstream identity;
    identity << evidence.absent << ' ' << evidence.directory << ' ' << st.st_dev << ' ' << st.st_ino << ' '
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
    return SerializeFields({evidence.path, identity.str(), evidence.bytes, SerializeFields(evidence.entries)});
}
} }
