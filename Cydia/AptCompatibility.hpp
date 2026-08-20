/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_AptCompatibility_H
#define Cydia_AptCompatibility_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace CydiaAPT {

enum class PackageManagerResult {
    Failed,
    Incomplete,
    Completed,
};

/* An index into AptBackend's current cache epoch.  It is deliberately not an
 * APT map pointer or iterator: Database's era check is the lifetime token,
 * while AptBackend alone resolves this value to version-specific APT types. */
struct PackageHandle {
    std::uint32_t value;

    explicit PackageHandle(std::uint32_t value = 0) : value(value) {}
    bool valid() const { return value != 0; }
};

enum class MultiArchMode {
    None,
    Same,
    Foreign,
    Allowed,
};

/* Cydia keeps presentation, APT cache, and dpkg command identities separate.
 * A native package retains its historical unqualified route, while foreign
 * package instances are architecture-qualified and therefore cannot alias the
 * native row.  dpkgName follows dpkg's non-ambiguous binary-package naming
 * rules, including the qualifier required by native Multi-Arch: same records.
 */
struct PackageIdentity {
    std::string baseName;
    std::string packageArchitecture;
    std::string versionArchitecture;
    std::string aptName;
    std::string routingName;
    std::string dpkgName;
    MultiArchMode multiArch;
    bool architectureIndependent;

    PackageIdentity();
    bool valid() const;
};

PackageIdentity BuildPackageIdentity(const std::string &baseName,
                                     const std::string &packageArchitecture,
                                     const std::string &versionArchitecture,
                                     const std::string &nativeArchitecture,
                                     MultiArchMode multiArch);

/* Route names preserve explicit dependency proxy architectures such as :any,
 * while retaining historical unqualified native and Architecture: all URLs. */
std::string BuildPackageRouteName(const std::string &baseName,
                                  const std::string &packageArchitecture,
                                  const std::string &nativeArchitecture);

bool IsNativeOrArchitectureIndependent(const std::string &versionArchitecture,
                                       const std::string &nativeArchitecture);

struct SourceHandle {
    std::uint32_t value;

    explicit SourceHandle(std::uint32_t value = 0) : value(value) {}
    bool valid() const { return value != 0; }
};

struct SourceSnapshot {
    SourceHandle handle;
    std::string uri;
    std::string distribution;
    std::string type;
    std::string base;
    std::string defaultIcon;
    std::string depiction;
    std::string description;
    std::string label;
    std::string origin;
    std::string support;
    std::string version;
    std::set<std::string> files;
    bool trusted;

    SourceSnapshot();
};

struct AcquireItemData {
    std::string description;
    std::string uri;
};

struct ErrorData {
    std::string message;
    bool warning;
};

struct CacheStateSummary {
    std::uint64_t deletes;
    std::uint64_t installs;
    std::uint64_t broken;

    CacheStateSummary();
};

struct FetchFailureData {
    std::string uri;
    std::string error;
};

struct FetchResultData {
    std::vector<FetchFailureData> failures;
    bool completed;

    FetchResultData();
};

struct SourceListData {
    std::vector<std::string> uris;
    bool success;

    SourceListData();
};

struct UpdateResultData {
    bool prepared;
    bool success;

    UpdateResultData();
};

/* A copy owned by Cydia, detached from the lifetime and layout of an APT
 * record parser.  The backend creates this while its cache epoch is locked;
 * models may retain the returned values after that parser is gone. */
struct PackageRecordData {
    std::map<std::string, std::string> fields;
    std::vector<std::string> tags;
    std::string displayName;
    std::string maintainer;
    std::string shortDescription;
    std::string longDescription;
    std::string raw;

    std::string Field(const char *name) const;
};

/* Stable package state/action values.  APT enum layouts and cache ownership
 * stay inside AptBackend; package controllers consume these strings and
 * booleans instead of touching APT's state-cache representation. */
struct PackageStateData {
    std::string state;
    std::string selection;
    std::string mode;
    bool essential;
    bool ignored;
    bool broken;
    bool hasMode;
    bool half;
    bool halfConfigured;
    bool halfInstalled;
    bool hasCurrent;
    bool upgradable;
    bool candidateMatchesVersion;
    bool newInstall;
    bool deletePackage;
    bool reinstall;
    bool upgrade;
    bool downgrade;

    PackageStateData();
};

struct PackageSnapshot {
    PackageHandle handle;
    PackageIdentity identity;
    PackageIdentity installedIdentity;
    PackageRecordData record;
    PackageStateData state;
    std::string identifier;
    std::string version;
    std::string installedVersion;
    std::string section;
    std::string architecture;
    std::uint64_t installedSize;
    std::uint32_t sourceFileID;
    bool hasSourceFile;
    bool defaultPriority;

    PackageSnapshot();
};

struct RelationClauseData {
    std::string package;
    std::string comparison;
    std::string version;
};

struct RelationData {
    std::string relationship;
    std::vector<RelationClauseData> clauses;
};

struct TransactionClauseData {
    std::string package;
    std::string comparison;
    std::string version;
    std::string reason;
    std::string installed;
};

struct TransactionReasonData {
    std::string relationship;
    std::vector<TransactionClauseData> clauses;
};

struct TransactionIssueData {
    std::string package;
    std::vector<TransactionReasonData> reasons;
};

struct TransactionData {
    std::vector<std::string> installs;
    std::vector<std::string> reinstalls;
    std::vector<std::string> upgrades;
    std::vector<std::string> downgrades;
    std::vector<std::string> removes;
    std::vector<TransactionIssueData> issues;
    std::uint64_t downloading;
    std::uint64_t resuming;
    bool removesEssential;
    bool substrate;

    TransactionData();
};

std::string Fingerprint(const void *data, std::size_t size);

} // namespace CydiaAPT

#endif // Cydia_AptCompatibility_H
