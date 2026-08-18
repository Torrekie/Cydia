/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 */

#ifndef Cydia_AptCompatibility_H
#define Cydia_AptCompatibility_H

#include <cstddef>
#include <map>
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
