/* Canonical native approval identity; no native I/O or query execution.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerCapture.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <apt-pkg/hashes.h>
#include <map>
#include <set>

namespace CydiaAPT { namespace Provider {
namespace {
bool Digest(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
bool Path(const std::string &path) {
    if (path.size() < 2 || path.size() > 4096 || path.front() != '/' || path.back() == '/') return false;
    for (unsigned char byte : path) if (byte < 32 || byte == 127) return false;
    std::size_t start = 1;
    while (start < path.size()) {
        const auto end = path.find('/', start);
        const auto part = path.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return true;
}
void Field(std::string *bytes, const std::string &value) {
    *bytes += std::to_string(value.size()) + ':' + value + ',';
}
}
std::string TriggerNativeAuthorityIdentity(const NativeDpkgAuthority &native,
    const std::vector<InstalledComponentEvidence> &components) {
    if (!native.launchEnvironment.initialized() || !Digest(native.configurationIdentity) || !Digest(native.platformIdentity) || components.empty() ||
        components.size() > MaximumTransactionComponents || native.componentPaths.size() != components.size()) return "";
    const std::set<std::string> expected(native.componentPaths.begin(), native.componentPaths.end());
    if (expected.size() != components.size()) return "";
    std::map<std::string, const InstalledComponentEvidence *> sorted;
    for (const auto &component : components) {
        const auto &file = component.file; const auto &metadata = file.metadata;
        if (!Path(metadata.path) || !expected.count(metadata.path) || !Digest(file.sha256) ||
            !Digest(component.parentsIdentity) || component.kind != ComponentFileKind::Regular ||
            !component.inode || component.links != 1 || metadata.uid != 0 ||
            metadata.mode > 07777 || (metadata.mode & 0022) || metadata.size > CydiaPackages::ArchiveLimits().maxStreamBytes ||
            !sorted.emplace(metadata.path, &component).second) return "";
    }
    std::string bytes("CYDIA-TRIGGER-NATIVE-APPROVAL-2");
    Field(&bytes, native.configurationIdentity); Field(&bytes, native.platformIdentity);
    Field(&bytes, CydiaRuntime::Privileged::SerializeFields(native.launchEnvironment.entries()));
    Field(&bytes, std::to_string(sorted.size()));
    for (const auto &entry : sorted) {
        const auto &component = *entry.second; const auto &metadata = component.file.metadata;
        Field(&bytes, metadata.path); Field(&bytes, component.file.sha256); Field(&bytes, component.parentsIdentity);
        for (const std::uint64_t number : {std::uint64_t(component.kind), metadata.size,
                std::uint64_t(metadata.mode), std::uint64_t(metadata.uid), std::uint64_t(metadata.gid),
                component.device, component.inode, component.links}) Field(&bytes, std::to_string(number));
    }
    Hashes hash(Hashes::SHA256SUM);
    return hash.Add(bytes.data(), bytes.size()) ? hash.GetHashString(Hashes::SHA256SUM).HashValue() : "";
}
std::string TriggerNativeGenerationIdentity(const NativeDpkgAuthority &native,
    const std::vector<InstalledComponentEvidence> &components, const std::string &origin) {
    if (!Digest(origin)) return "";
    NativeDpkgAuthority identityOnly;
    identityOnly.configurationIdentity = native.configurationIdentity;
    identityOnly.platformIdentity = native.platformIdentity;
    identityOnly.launchEnvironment = native.launchEnvironment;
    for (const auto &component : components)
        identityOnly.componentPaths.push_back(component.file.metadata.path);
    const auto current = TriggerNativeAuthorityIdentity(identityOnly, components);
    if (current.empty()) return "";
    const auto bytes = "CYDIA-NATIVE-GENERATION-1" + CydiaRuntime::Privileged::SerializeFields({origin, current});
    Hashes hash(Hashes::SHA256SUM);
    return hash.Add(bytes.data(), bytes.size()) ? hash.GetHashString(Hashes::SHA256SUM).HashValue() : "";
}
}}
