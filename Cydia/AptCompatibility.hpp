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

/* User-facing selectors are not dependency expressions. In particular :all
 * selects an actual Architecture: all version, and :native is a UI alias for
 * the native version architecture. Neither adds binary dependency syntax. */
enum class PackageSelectorKind { Default, Native, ExactArchitecture, Any };

struct PackageSelector {
    PackageSelectorKind kind = PackageSelectorKind::Default;
    std::string baseName;
    std::string architecture;
    bool valid() const { return !baseName.empty(); }
};

PackageSelector ParsePackageSelector(const std::string &name);

enum class PackageLookupStatus {
    Found, InvalidSelector, NotFound, UnsupportedArchitecture,
    NoEligibleVersion, Ambiguous,
};

struct PackageLookupResult {
    PackageLookupStatus status = PackageLookupStatus::NotFound;
    PackageSelector selector;
    PackageHandle handle;
    std::vector<PackageHandle> alternatives;
    std::vector<std::string> availableArchitectures;
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

/* Repository records are visible only when their concrete version
 * architecture is configured by the selected dpkg. A package with local dpkg
 * state remains visible even if that architecture was later deconfigured, so
 * the user can inspect, repair, or remove it. */
bool IsPackageArchitectureVisible(const std::string &versionArchitecture,
                                  bool hasLocalState,
                                  const std::vector<std::string> &configuredArchitectures);

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
    // Cydia-owned diagnostic identity. Empty for upstream APT/dpkg messages,
    // which retain their own gettext translation and must not be reclassified.
    std::string cydiaCode;

    ErrorData() : warning(false) {}
    ErrorData(const std::string &message, bool warning, const std::string &cydiaCode = std::string()) :
        message(message), warning(warning), cydiaCode(cydiaCode) {}
};

struct CacheStateSummary {
    std::uint64_t deletes;
    std::uint64_t installs;
    std::uint64_t broken;

    CacheStateSummary();
};

enum class FetchDiagnosticKind {
    General,
    ArchiveIncomplete,
    ArchiveMissingHashes,
    ArchiveMismatch,
    ArchiveUnavailable,
    UnauthenticatedSource,
    UnsignedRepository,
    MissingSigningKey,
    UnusableSigningKey,
    WeakRepository,
    MissingReleaseFile,
    RepositoryTrustDowngrade,
    BadRepositorySignature,
    InvalidRepositorySignature,
    ArchiveTrustNeedsRefresh,
    ArchiveLayoutMismatch,
    ArchiveInvalid,
    ArchiveIdentityMismatch,
    ArchiveUnverified,
};

struct FetchFailureData {
    std::string uri;
    std::string error;
    std::string package;
    std::string path;
    std::string reason;
    FetchDiagnosticKind kind;

    FetchFailureData() : kind(FetchDiagnosticKind::General) {}
};

struct FetchResultData {
    std::vector<FetchFailureData> failures;
    /* Advisory only; display before package-manager execution without
     * adding a second blocking approval for Warning mode. */
    std::vector<FetchFailureData> warnings;
    bool completed;

    FetchResultData();
};

struct SourceListData {
    std::vector<std::string> uris;
    bool success;

    SourceListData();
};

struct UpdateResultData {
    std::vector<FetchFailureData> warnings;
    std::vector<FetchFailureData> failures;
    bool prepared;
    bool success;
    /* APT may reuse old indexes after a transient network error even while
     * reporting success. That run cannot establish a new trust proof. */
    bool metadataComplete;

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
    bool protectedPackage;
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
    bool versionAvailable;
    bool installedVersionAvailable;
    bool policyCandidate;
    bool installedVersion;
    bool architectureSupported = false;
    int versionPriority;
    int versionComparison;

    PackageStateData();
};

struct PackageSnapshot {
    PackageHandle handle;
    std::vector<std::string> registeredArchitectures;
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
    /* APT's version-qualified, architecture-aware targets of this exact
     * dependency, including virtual providers. Never resolve package again
     * as a user selector when navigating a dependency. */
    std::vector<PackageHandle> providers;
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
    std::vector<PackageHandle> providers;
};

struct TransactionReasonData {
    std::string relationship;
    std::vector<TransactionClauseData> clauses;
};

struct TransactionIssueData {
    std::string package;
    std::string kind;
    std::vector<TransactionReasonData> reasons;
};

/* Owning operation metadata remains valid after dpkg changes the status file
 * or Database rebuilds its cache. The version is the planned install version
 * or the actual version being removed, never a later policy candidate. */
struct TransactionPackageData {
    PackageIdentity identity;
    std::string version;
    std::string displayName;
};

struct TransactionData {
    std::vector<std::string> registeredArchitectures;
    std::vector<std::string> installs;
    std::vector<std::string> reinstalls;
    std::vector<std::string> upgrades;
    std::vector<std::string> downgrades;
    std::vector<std::string> removes;
    std::vector<std::string> purges;
    std::vector<TransactionIssueData> issues;
    std::map<std::string, TransactionPackageData> packages;
    std::uint64_t downloading;
    std::uint64_t resuming;
    bool removesEssential;
    bool substrate;

    TransactionData();
};

/* Match APT/dpkg progress identifiers to an operation snapshot. These aliases
 * describe the package bucket; they are not user-selector lookup semantics. */
const TransactionPackageData *FindTransactionPackage(const TransactionData &transaction,
                                                     const std::string &identifier);

std::string Fingerprint(const void *data, std::size_t size);
std::string FingerprintFileDescriptor(int descriptor);

} // namespace CydiaAPT

#endif // Cydia_AptCompatibility_H
