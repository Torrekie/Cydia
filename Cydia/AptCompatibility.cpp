/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 */

#include "Cydia/AptCompatibility.hpp"

#include <apt-pkg/clean.h>
#include <apt-pkg/depcache.h>
#include <apt-pkg/install-progress.h>
#include <apt-pkg/macros.h>
#include <apt-pkg/packagemanager.h>
#include <apt-pkg/pkgcache.h>
#include <apt-pkg/upgrade.h>

#if !defined(APT_PKG_ABI) || APT_PKG_ABI < 500
#error "Cydia's APT compatibility layer requires libapt-pkg ABI 5.0 or newer"
#endif

#include <sys/stat.h>
#include <unistd.h>

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

namespace {

class ArchiveCleaner : public pkgArchiveCleaner {
  protected:
#if APT_PKG_MAJOR >= 6
    virtual void Erase(int const directoryFd, char const * const file,
                       std::string const &, std::string const &,
                       struct stat const &) {
        if (directoryFd >= 0)
            (void) unlinkat(directoryFd, file, 0);
        else
            (void) unlink(file);
    }
#else
    virtual void Erase(const char *file, std::string, std::string, struct stat &) {
        (void) unlink(file);
    }
#endif
};

} // namespace

bool CleanArchives(const std::string &directory, pkgCache &cache) {
    ArchiveCleaner cleaner;
    return cleaner.Go(directory, cache);
}

bool MinimizeUpgrade(pkgDepCache &cache) {
    return pkgMinimizeUpgrade(cache);
}

bool PrepareDistUpgrade(pkgDepCache &cache) {
    return APT::Upgrade::Upgrade(cache, APT::Upgrade::ALLOW_EVERYTHING);
}

} // namespace Apt
} // namespace Cydia
