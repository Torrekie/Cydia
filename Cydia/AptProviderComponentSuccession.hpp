/* Helper-owned transaction component evidence. No provider wire authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderComponentSuccession_HPP
#define Cydia_AptProviderComponentSuccession_HPP
#include "Cydia/AptProviderReview.hpp"
#include "Cydia/PackageArchiveReader.hpp"

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumTransactionComponents = 512;
constexpr std::size_t MaximumComponentDependencies = 4096;

enum class ComponentFileKind { Regular, Symlink, Other };
struct InstalledComponentEvidence {
    CydiaPackages::ArchivePayloadFileEvidence file;
    ComponentFileKind kind = ComponentFileKind::Other;
    std::uint64_t device = 0, inode = 0, links = 0;
    // Hash of the independently protected canonical parent/alias chain. This
    // must not change for an existing component, including across an upgrade.
    std::string parentsIdentity;
};
struct RetainedComponentArchive {
    VerifiedArchiveEvidence archive;
    CydiaPackages::ArchivePayloadEvidence payload;
};

enum class ComponentDependencyKind { Component, Platform };
struct ComponentDependencyEvidence {
    ComponentDependencyKind kind = ComponentDependencyKind::Component;
    std::string path;
};
struct ComponentClosureNode {
    InstalledComponentEvidence file;
    std::vector<ComponentDependencyEvidence> dependencies;
};
struct ComponentClosureEvidence {
    std::string executable, nativeConfigurationIdentity, platformIdentity;
    // Produced only by Cydia's installed loader inspector: every actual load
    // command must be resolved, checked against the target/compatibility/OS,
    // and represented here. Platform edges require the captured OS image
    // authority; nonplatform edges require another exact node. The pure model
    // checks generation binding and graph completeness, not Mach-O bytes.
    // This type is intentionally never accepted from a provider message.
    std::vector<ComponentClosureNode> nodes;
};

/* Pure ledger for a retained authenticated helper. Capture files, archive
 * hashes, protected parents and complete loader graphs independently before
 * calling it. It performs no I/O and cannot establish that evidence itself.
 * A failed observation permanently invalidates this ledger. Only an exact
 * newly completed approved unpack can introduce a replacement; a later
 * configure/script replacement cannot reuse an earlier unpack permission.
 * Existing filesystem aliases, hardlinks, removed components, native config
 * changes and script-generated replacements remain unsupported. */
class ComponentSuccession {
    struct Replacement {
        std::uint64_t action = 0;
        CydiaPackages::ArchivePayloadFileEvidence file;
    };
    std::map<std::string, InstalledComponentEvidence> current_;
    std::map<std::string, Replacement> replacements_;
    std::set<std::uint64_t> unpacks_, completed_;
    std::string configuration_, platform_;
    bool initialized_ = false, active_ = false;
public:
    bool Begin(const ReviewedTransaction &, const ReviewPolicy &,
        const std::vector<InstalledComponentEvidence> &initial,
        const std::vector<RetainedComponentArchive> &replacements,
        const std::string &nativeConfigurationIdentity, const std::string &platformIdentity,
        std::string *error);
    bool Observe(const std::set<std::uint64_t> &completedUnpacks,
        const std::vector<InstalledComponentEvidence> &installed, std::string *error);
    bool AuthorizeLaunch(const ComponentClosureEvidence &, std::string *error) const;
    bool active() const { return active_; }
    void Invalidate() { active_ = false; }
};
bool SameInstalledComponent(const InstalledComponentEvidence &, const InstalledComponentEvidence &);
}} // namespace CydiaAPT::Provider
#endif
