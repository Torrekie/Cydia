/* Cydia - iPhone UIKit Front-End for Debian APT
 * Database operations kept behind the Cydia-owned APT boundary.
 */

#include "Cydia/AptBackend.hpp"

#include <apt-pkg/acquire-item.h>
#include <apt-pkg/clean.h>
#include <apt-pkg/error.h>
#include <apt-pkg/init.h>
#include <apt-pkg/metaindex.h>
#include <apt-pkg/pkgsystem.h>
#include <apt-pkg/progress.h>

namespace CydiaAPT {

std::vector<ErrorData> AptBackend::drainErrors() {
    std::vector<ErrorData> result;
    while (!_error->empty()) {
        ErrorData error;
        error.warning = !_error->PopMessage(error.message);
        while (!error.message.empty() && error.message[error.message.size() - 1] == '\n')
            error.message.resize(error.message.size() - 1);
        result.push_back(error);
    }
    return result;
}

void AptBackend::discardErrors() {
    _error->Discard();
}

bool AptBackend::openCache() {
    OpProgress progress;
    return cache_.Open(&progress, false);
}

CacheStateSummary AptBackend::cacheState() {
    CacheStateSummary result;
    if (static_cast<pkgDepCache *>(cache_) == NULL)
        return result;
    result.deletes = cache_->DelCount();
    result.installs = cache_->InstCount();
    result.broken = cache_->BrokenCount();
    return result;
}

bool AptBackend::applyStatus() {
    return static_cast<pkgDepCache *>(cache_) != NULL &&
        ApplyStatus(static_cast<pkgDepCache &>(cache_));
}

bool AptBackend::fixBroken() {
    return static_cast<pkgDepCache *>(cache_) != NULL &&
        FixBroken(static_cast<pkgDepCache &>(cache_));
}

bool AptBackend::minimizeUpgrade() {
    return static_cast<pkgDepCache *>(cache_) != NULL && MinimizeUpgrade(cache_);
}

bool AptBackend::cleanArchives() {
    if (lock_ != NULL)
        return false;

    const std::string archives(_config->FindDir("Dir::Cache::Archives"));
    FileFd lock(GetLock(archives + "lock"), true);
    if (_error->PendingError())
        return false;

    pkgAcquire fetcher;
    fetcher.Clean(archives);
    if (_error->PendingError())
        return false;
    return CleanArchives(archives + "partial/", static_cast<pkgCache &>(cache_));
}

bool AptBackend::prepareArchives() {
    if (fetcher_ == NULL)
        return false;
    fetcher_->Shutdown();

    pkgRecords records(cache_);
    delete lock_;
    lock_ = new FileFd(GetLock(_config->FindDir("Dir::Cache::Archives") + "lock"), true);
    if (_error->PendingError())
        return false;

    pkgSourceList list;
    if (!list.ReadMainList())
        return false;

    manager_.reset(_system->CreatePM(cache_));
    return manager_.get() != NULL && manager_->GetArchives(fetcher_, &list, &records);
}

SourceListData AptBackend::sourceList() {
    SourceListData result;
    pkgSourceList list;
    result.success = list.ReadMainList();
    if (!result.success)
        return result;
    for (pkgSourceList::const_iterator source(list.begin()); source != list.end(); ++source)
        result.uris.push_back((*source)->GetURI());
    return result;
}

FetchResultData AptBackend::runFetcher(int pulseInterval) {
    FetchResultData result;
    if (fetcher_ == NULL)
        return result;

    result.completed = fetcher_->Run(pulseInterval) == pkgAcquire::Continue;
    if (!result.completed)
        return result;

    for (pkgAcquire::ItemIterator item(fetcher_->ItemsBegin()); item != fetcher_->ItemsEnd(); ++item) {
        if (((*item)->Status == pkgAcquire::Item::StatDone && (*item)->Complete) ||
            (*item)->Status == pkgAcquire::Item::StatIdle)
            continue;
        FetchFailureData failure;
        failure.uri = (*item)->DescURI();
        failure.error = (*item)->ErrorText;
        result.failures.push_back(failure);
    }
    return result;
}

PackageManagerResult AptBackend::runPackageManager(int statusFd) {
    return manager_.get() == NULL ? PackageManagerResult::Failed :
        RunPackageManager(*manager_, statusFd);
}

UpdateResultData AptBackend::updateLists(pkgAcquireStatus &status, int pulseInterval) {
    UpdateResultData result;
    pkgSourceList list;
    if (!list.ReadMainList())
        return result;

    FileFd lock(GetLock(_config->FindDir("Dir::State::Lists") + "lock"), true);
    if (_error->PendingError())
        return result;
    result.prepared = true;
    result.success = UpdateLists(status, list, pulseInterval);
    return result;
}

} // namespace CydiaAPT
