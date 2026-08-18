/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 */

#ifndef Cydia_AptCompatibility_H
#define Cydia_AptCompatibility_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

class pkgCache;
class pkgDepCache;
class pkgPackageManager;
class pkgProblemResolver;

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
 * booleans instead of touching pkgDepCache::StateCache. */
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

// Keep version-sensitive APT calls out of Objective-C controllers and models.
// AptBackend now owns the mutable epoch handles; these references are a
// transitional Database façade until the remaining cache queries become DTOs.
PackageManagerResult RunPackageManager(pkgPackageManager &manager, int statusFd);
bool CleanArchives(const std::string &directory, pkgCache &cache);
bool MinimizeUpgrade(pkgDepCache &cache);
bool PrepareDistUpgrade(pkgDepCache &cache);
bool ResolveDependencies(pkgProblemResolver &resolver);

} // namespace CydiaAPT

#endif // Cydia_AptCompatibility_H
