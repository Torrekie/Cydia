/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 */

#include "Cydia/AptCompatibility.hpp"

#include <apt-pkg/depcache.h>
#include <apt-pkg/install-progress.h>
#include <apt-pkg/macros.h>
#include <apt-pkg/packagemanager.h>
#include <apt-pkg/upgrade.h>

#if !defined(APT_PKG_ABI) || APT_PKG_ABI < 500
#error "Cydia's APT compatibility layer requires libapt-pkg ABI 5.0 or newer"
#endif

namespace Cydia {
namespace Apt {

PackageManagerResult RunPackageManager(pkgPackageManager &manager, int statusFd) {
    APT::Progress::PackageManagerProgressFd progress(statusFd);

    switch (manager.DoInstall(&progress)) {
        case pkgPackageManager::Failed:
            return PackageManagerResult::Failed;
        case pkgPackageManager::Incomplete:
            return PackageManagerResult::Incomplete;
        case pkgPackageManager::Completed:
            return PackageManagerResult::Completed;
    }

    return PackageManagerResult::Failed;
}

bool PrepareDistUpgrade(pkgDepCache &cache) {
    return APT::Upgrade::Upgrade(cache, APT::Upgrade::ALLOW_EVERYTHING);
}

} // namespace Apt
} // namespace Cydia
