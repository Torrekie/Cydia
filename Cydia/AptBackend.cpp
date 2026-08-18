/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT lifetime and transaction ownership boundary.
 */

#include "Cydia/AptBackend.hpp"

namespace CydiaAPT {

AptBackend::AptBackend(pkgAcquireStatus &status) :
    status_(&status),
    policy_(NULL),
    records_(NULL),
    resolver_(NULL),
    fetcher_(NULL),
    lock_(NULL),
    list_(NULL)
{
}

AptBackend::~AptBackend() {
    reset();
}

void AptBackend::reset() {
    delete list_;
    list_ = NULL;
    manager_.reset();
    delete lock_;
    lock_ = NULL;
    delete fetcher_;
    fetcher_ = NULL;
    delete resolver_;
    resolver_ = NULL;
    delete records_;
    records_ = NULL;
    delete policy_;
    policy_ = NULL;
    cache_.Close();
}

void AptBackend::createCacheViews() {
    delete resolver_;
    resolver_ = NULL;
    delete records_;
    records_ = NULL;
    delete policy_;
    policy_ = NULL;

    policy_ = new pkgDepCache::Policy();
    records_ = new pkgRecords(cache_);
    resolver_ = new pkgProblemResolver(cache_);
}

pkgSourceList *AptBackend::createSourceList() {
    delete list_;
    list_ = new pkgSourceList();
    return list_;
}

pkgAcquire *AptBackend::createFetcher() {
    delete fetcher_;
    fetcher_ = new pkgAcquire(status_);
    return fetcher_;
}

pkgCacheFile &AptBackend::cache() {
    return cache_;
}

pkgDepCache::Policy *AptBackend::policy() const {
    return policy_;
}

pkgRecords *AptBackend::records() const {
    return records_;
}

pkgProblemResolver *&AptBackend::resolver() {
    return resolver_;
}

pkgAcquire *AptBackend::fetcher() const {
    return fetcher_;
}

FileFd *&AptBackend::lock() {
    return lock_;
}

std::unique_ptr<pkgPackageManager> &AptBackend::manager() {
    return manager_;
}

pkgSourceList *AptBackend::list() const {
    return list_;
}

} // namespace CydiaAPT
