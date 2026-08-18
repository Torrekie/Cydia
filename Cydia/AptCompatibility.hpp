/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 */

#ifndef Cydia_AptCompatibility_H
#define Cydia_AptCompatibility_H

#include <string>

class pkgCache;
class pkgDepCache;
class pkgPackageManager;

namespace Cydia {
namespace Apt {

enum class PackageManagerResult {
    Failed,
    Incomplete,
    Completed,
};

// Keep version-sensitive APT calls out of Objective-C controllers and models.
// The cache references are transitional handles; the next AptBackend slice
// will replace them with Cydia-owned transaction objects and DTOs.
PackageManagerResult RunPackageManager(pkgPackageManager &manager, int statusFd);
bool CleanArchives(const std::string &directory, pkgCache &cache);
bool MinimizeUpgrade(pkgDepCache &cache);
bool PrepareDistUpgrade(pkgDepCache &cache);

} // namespace Apt
} // namespace Cydia

#endif // Cydia_AptCompatibility_H
