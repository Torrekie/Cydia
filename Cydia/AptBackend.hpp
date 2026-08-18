/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT lifetime and transaction ownership boundary.
 */

#ifndef Cydia_AptBackend_HPP
#define Cydia_AptBackend_HPP

#include "Cydia/AptCompatibility.hpp"

#include <apt-pkg/acquire.h>
#include <apt-pkg/algorithms.h>
#include <apt-pkg/cachefile.h>
#include <apt-pkg/contrib/fileutl.h>
#include <apt-pkg/packagemanager.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sourcelist.h>

#include <memory>

namespace CydiaAPT {

/*
 * Database is an Objective-C façade; this class owns every mutable APT
 * handle belonging to one database epoch.  Raw handles are returned only to
 * Database.mm, which is the transition point for the DTO backend migration.
 */
class AptBackend {
  private:
    pkgAcquireStatus *status_;
    pkgCacheFile cache_;
    pkgDepCache::Policy *policy_;
    pkgRecords *records_;
    pkgProblemResolver *resolver_;
    pkgAcquire *fetcher_;
    FileFd *lock_;
    std::unique_ptr<pkgPackageManager> manager_;
    pkgSourceList *list_;

  public:
    explicit AptBackend(pkgAcquireStatus &status);
    ~AptBackend();

    void reset();
    void createCacheViews();
    CydiaAPT::PackageRecordData recordData(const void *verFileIterator);
    CydiaAPT::PackageStateData packageState(const void *pkgIterator, const void *verIterator);
    bool clearPackage(const void *pkgIterator);
    bool installPackage(const void *pkgIterator, const void *verIterator);
    bool removePackage(const void *pkgIterator);
    pkgSourceList *createSourceList();
    pkgAcquire *createFetcher();

    pkgCacheFile &cache();
    pkgDepCache::Policy *policy() const;
    pkgRecords *records() const;
    pkgProblemResolver *&resolver();
    pkgAcquire *fetcher() const;
    FileFd *&lock();
    std::unique_ptr<pkgPackageManager> &manager();
    pkgSourceList *list() const;
};

} // namespace CydiaAPT

#endif // Cydia_AptBackend_HPP
