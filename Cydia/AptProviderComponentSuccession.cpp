/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderComponentSuccession.hpp"
#include <algorithm>

namespace CydiaAPT { namespace Provider {
namespace {
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Digest(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
bool Path(const std::string &path) {
    if (path.size() < 2 || path.size() > 4096 || path.front() != '/' || path.back() == '/') return false;
    std::size_t start = 1;
    for (unsigned char c : path) if (c < 32 || c == 127) return false;
    while (start < path.size()) {
        const auto end = path.find('/', start);
        const auto part = path.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return true;
}
bool Payload(const CydiaPackages::ArchivePayloadFileEvidence &file) {
    return Path(file.metadata.path) && Digest(file.sha256) && file.metadata.mode <= 07777 &&
        !(file.metadata.mode & 0022) && file.metadata.uid == 0 &&
        file.metadata.size <= CydiaPackages::ArchiveLimits().maxStreamBytes;
}
bool Installed(const InstalledComponentEvidence &file) {
    return Payload(file.file) && file.kind == ComponentFileKind::Regular && file.inode != 0 &&
        file.links == 1 && Digest(file.parentsIdentity);
}
bool SamePayload(const CydiaPackages::ArchivePayloadFileEvidence &a, const CydiaPackages::ArchivePayloadFileEvidence &b) {
    return a.sha256 == b.sha256 && a.metadata.path == b.metadata.path && a.metadata.size == b.metadata.size &&
        a.metadata.mode == b.metadata.mode && a.metadata.uid == b.metadata.uid && a.metadata.gid == b.metadata.gid;
}
bool SameArchive(const ArchiveManifest &a, const ArchiveManifest &b) {
    std::string left, right; return Encode(a, &left) && Encode(b, &right) && left == right;
}
bool Inspection(const CydiaPackages::ArchivePolicyResult &value, bool warningAccepted) {
    return value.complete && value.identityVerified &&
        (value.status == CydiaPackages::ArchivePolicyStatus::Accepted ||
         (value.status == CydiaPackages::ArchivePolicyStatus::Unverified && warningAccepted));
}
}
bool SameInstalledComponent(const InstalledComponentEvidence &a, const InstalledComponentEvidence &b) {
    return SamePayload(a.file, b.file) && a.kind == b.kind && a.device == b.device && a.inode == b.inode &&
        a.links == b.links && a.parentsIdentity == b.parentsIdentity;
}
bool ComponentSuccession::Begin(const ReviewedTransaction &review, const ReviewPolicy &policy,
    const std::vector<InstalledComponentEvidence> &initial, const std::vector<RetainedComponentArchive> &archives,
    const std::string &configuration, const std::string &platform, std::string *error) {
    if (initialized_) { active_ = false; return Fail(error, "provider_component_ledger_reused"); }
    initialized_ = true;
    ReviewAuthorization checked;
    if (!checked.Accept(review, policy, error) || !Encode(review, &originReviewBytes_) ||
        originReviewBytes_.size() > MaximumMessageBytes || !Digest(configuration) || !Digest(platform) || initial.empty() ||
        initial.size() > MaximumTransactionComponents || archives.size() > MaximumTransactionComponents)
        return Fail(error, "provider_component_admission_invalid");
    for (const auto &file : initial)
        if (!Installed(file) || !current_.emplace(file.file.metadata.path, file).second)
            return Fail(error, "provider_component_origin_invalid");
    std::map<std::string, std::uint64_t> actions;
    for (const auto &action : review.execution.actions) if (action.action == ExecutionAction::Unpack) {
        if (!actions.emplace(action.archive, action.identifier).second)
            return Fail(error, "provider_component_unpack_ambiguous");
        unpacks_.insert(action.identifier);
    }
    std::set<std::string> seen;
    for (const auto &archive : archives) {
        const auto &source = archive.archive.archive;
        const auto expected = std::find_if(review.execution.archives.begin(), review.execution.archives.end(),
            [&](const ArchiveManifest &item) { return item.identifier == source.identifier; });
        const bool warning = policy.unverifiedArchiveWarningsAccepted.count(source.identifier) != 0;
        if (expected == review.execution.archives.end() || !SameArchive(*expected, source) || !actions.count(source.identifier) ||
            !seen.insert(source.identifier).second || !ValidIdentityToken(archive.archive.fileIdentity) ||
            !Inspection(archive.archive.inspection, warning) || !Inspection(archive.payload.archive, warning) ||
            !archive.payload.payload.complete || !archive.payload.payload.reason.empty() || archive.payload.files.empty() ||
            archive.payload.files.size() > MaximumTransactionComponents)
            return Fail(error, "provider_component_payload_unverified");
        for (const auto &file : archive.payload.files) {
            if (file.first != file.second.metadata.path || !Payload(file.second) || replacements_.size() == MaximumTransactionComponents)
                return Fail(error, "provider_component_payload_invalid");
            Replacement replacement; replacement.action = actions.at(source.identifier); replacement.file = file.second;
            if (!replacements_.emplace(file.first, replacement).second)
                return Fail(error, "provider_component_successor_ambiguous");
        }
    }
    std::set<std::string> all;
    for (const auto &file : current_) all.insert(file.first);
    for (const auto &file : replacements_) all.insert(file.first);
    if (all.size() > MaximumTransactionComponents) return Fail(error, "provider_component_limit");
    initial_ = current_; configuration_ = configuration; platform_ = platform; active_ = true;
    if (error) error->clear();
    return true;
}
bool ComponentSuccession::Observe(const std::set<std::uint64_t> &completed,
    const std::vector<InstalledComponentEvidence> &installed, std::string *error) {
    const auto reject = [&](const char *code) { active_ = false; return Fail(error, code); };
    if (!active_ || installed.size() > MaximumTransactionComponents ||
        !std::includes(completed.begin(), completed.end(), completed_.begin(), completed_.end()) ||
        !std::includes(unpacks_.begin(), unpacks_.end(), completed.begin(), completed.end()))
        return reject("provider_component_checkpoint_invalid");
    std::set<std::string> required;
    for (const auto &file : current_) required.insert(file.first);
    for (const auto &file : replacements_) if (completed.count(file.second.action)) required.insert(file.first);
    std::map<std::string, InstalledComponentEvidence> observed;
    for (const auto &file : installed) {
        const auto &path = file.file.metadata.path;
        if (!Installed(file) || !required.count(path) || !observed.emplace(path, file).second)
            return reject("provider_component_state_invalid");
        const auto previous = current_.find(path);
        const auto replacement = replacements_.find(path);
        const bool newlyAuthorized = replacement != replacements_.end() && completed.count(replacement->second.action) &&
            !completed_.count(replacement->second.action);
        if (previous != current_.end() && previous->second.parentsIdentity != file.parentsIdentity)
            return reject("provider_component_parent_changed");
        if (newlyAuthorized) {
            if (!SamePayload(file.file, replacement->second.file)) return reject("provider_component_successor_mismatch");
        } else if (previous == current_.end() || !SameInstalledComponent(previous->second, file))
            return reject("provider_component_unapproved_change");
    }
    if (observed.size() != required.size()) return reject("provider_component_missing");
    current_.swap(observed); completed_ = completed;
    if (error) error->clear();
    return true;
}
bool ComponentSuccession::AuthorizeOrigin(const ReviewedTransaction &review, const std::string &configuration,
    const std::string &platform, std::vector<InstalledComponentEvidence> *initial, std::string *error) const {
    if (!initial) return Fail(error, "provider_component_origin_invalid");
    initial->clear();
    std::string bytes;
    if (!active_ || initial_.empty() || configuration != configuration_ || platform != platform_ ||
        !Encode(review, &bytes) || bytes.size() > MaximumMessageBytes || bytes != originReviewBytes_)
        return Fail(error, "provider_component_origin_changed");
    for (const auto &file : initial_) initial->push_back(file.second);
    if (error) error->clear();
    return true;
}
bool ComponentSuccession::AuthorizeComponents(const std::vector<InstalledComponentEvidence> &installed,
    std::string *error) const {
    if (!active_ || installed.size() != current_.size()) return Fail(error, "provider_component_checkpoint_invalid");
    std::set<std::string> seen;
    for (const auto &file : installed) {
        const auto &path = file.file.metadata.path;
        const auto current = current_.find(path);
        if (!Installed(file) || current == current_.end() || !seen.insert(path).second ||
            !SameInstalledComponent(current->second, file)) return Fail(error, "provider_component_state_invalid");
    }
    if (error) error->clear();
    return true;
}
bool ComponentSuccession::AuthorizeLaunch(const ComponentClosureEvidence &proof, std::string *error) const {
    if (!active_ || proof.nativeConfigurationIdentity != configuration_ || proof.platformIdentity != platform_ ||
        !Path(proof.executable) || proof.nodes.empty() || proof.nodes.size() > MaximumTransactionComponents)
        return Fail(error, "provider_component_closure_unverified");
    std::map<std::string, const ComponentClosureNode *> nodes; std::size_t edges = 0;
    for (const auto &node : proof.nodes) {
        const auto &path = node.file.file.metadata.path;
        const auto current = current_.find(path);
        if (current == current_.end() || !SameInstalledComponent(current->second, node.file) ||
            !nodes.emplace(path, &node).second || node.dependencies.size() > MaximumComponentDependencies - edges)
            return Fail(error, "provider_component_closure_changed");
        edges += node.dependencies.size();
        for (const auto &dependency : node.dependencies)
            if (!Path(dependency.path) || (dependency.kind != ComponentDependencyKind::Component && dependency.kind != ComponentDependencyKind::Platform))
                return Fail(error, "provider_component_dependency_invalid");
    }
    const auto executable = nodes.find(proof.executable);
    if (executable == nodes.end() || !(executable->second->file.file.metadata.mode & 0111))
        return Fail(error, "provider_component_executable_missing");
    std::set<std::string> reached; std::vector<std::string> pending{proof.executable};
    while (!pending.empty()) {
        const std::string path = pending.back(); pending.pop_back();
        if (!reached.insert(path).second) continue;
        const auto node = nodes.find(path);
        if (node == nodes.end()) return Fail(error, "provider_component_dependency_missing");
        for (const auto &dependency : node->second->dependencies) {
            if (dependency.kind == ComponentDependencyKind::Component) pending.push_back(dependency.path);
            // A captured nonplatform component must never be relabelled as an
            // OS dependency to evade its exact generation check.
            else if (current_.count(dependency.path) || replacements_.count(dependency.path))
                return Fail(error, "provider_component_platform_substitution");
        }
    }
    if (reached.size() != nodes.size()) return Fail(error, "provider_component_closure_extraneous");
    if (error) error->clear();
    return true;
}
}} // namespace CydiaAPT::Provider
