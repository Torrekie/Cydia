/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 */

#ifndef Cydia_AptCompatibility_H
#define Cydia_AptCompatibility_H

#include <cstddef>
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

// Stable record view used while Package is moved behind AptBackend.  The
// opaque handle is a pkgRecords::Parser owned by the current database epoch;
// no parser methods or record-layout details escape through this header.
class PackageRecord {
  private:
    void *parser_;

  public:
    explicit PackageRecord(void *parser);

    std::string Field(const char *name) const;
    std::string DisplayName() const;
    std::vector<std::string> Tags() const;
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
