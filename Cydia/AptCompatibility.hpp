/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 */

#ifndef Cydia_AptCompatibility_H
#define Cydia_AptCompatibility_H

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
// This surface deliberately uses only Cydia-owned values; raw APT result types
// remain inside AptCompatibility.cpp.
PackageManagerResult RunPackageManager(pkgPackageManager &manager, int statusFd);
bool PrepareDistUpgrade(pkgDepCache &cache);

} // namespace Apt
} // namespace Cydia

#endif // Cydia_AptCompatibility_H
