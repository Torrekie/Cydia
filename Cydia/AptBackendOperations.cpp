/* Cydia - iPhone UIKit Front-End for Debian APT
 * Database operations kept behind the Cydia-owned APT boundary.
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/AptCompatibilityInternal.hpp"
#include "Cydia/AptRuntime.hpp"

#include <apt-pkg/acquire-item.h>
#include <apt-pkg/clean.h>
#include <apt-pkg/error.h>
#include <apt-pkg/init.h>
#include <apt-pkg/metaindex.h>
#include <apt-pkg/pkgsystem.h>
#include <apt-pkg/progress.h>
#include <apt-pkg/hashes.h>

#include <sys/stat.h>

namespace CydiaAPT {
namespace Internal {

namespace {

#ifdef APT_CYDIA_STATE_FILE_WRITER
bool DeferStateFileWrite(pkgDepCache &, bool, void *) { return true; }
class DeferredStateFileWrites {
public:
    DeferredStateFileWrites() { SetStateFileWriter(DeferStateFileWrite, NULL); }
    ~DeferredStateFileWrites() { SetStateFileWriter(NULL, NULL); }
};
#endif

ArchiveIntegrity VerifyArchiveIntegrity(pkgAcqArchive &archive) {
    const HashStringList expected(archive.GetExpectedHashes());
    if ((expected.empty() || !expected.usable()) && archive.HashesRequired())
        return ArchiveIntegrity::MissingExpectedHashes;

    FileFd file(archive.DestFile, FileFd::ReadOnly);
    struct stat info;
    if (!file.IsOpen() || file.Failed() ||
        fstat(file.Fd(), &info) != 0 || !S_ISREG(info.st_mode))
        return ArchiveIntegrity::Unavailable;

    /* APT permits genuinely local volatile archives without repository
     * hashes. Preserve that explicit exception, while still checking that
     * the payload exists. Remote archives must have usable expected hashes. */
    if (expected.empty())
        return ArchiveIntegrity::NotRequired;

    const HashString *size(expected.find("Checksum-FileSize"));
    if (size != NULL && size->HashValue() != std::to_string(info.st_size))
        return ArchiveIntegrity::Mismatch;

    Hashes actual(expected);
    if (!actual.AddFD(file) || file.Failed())
        return ArchiveIntegrity::Unavailable;
    return actual.GetHashStringList() == expected ?
        ArchiveIntegrity::Verified : ArchiveIntegrity::Mismatch;
}

void ValidateArchiveItems(pkgAcquire &fetcher, FetchResultData &result) {
    const RepositorySecurityMode mode(GetRepositorySecurityMode());
    for (pkgAcquire::ItemIterator item(fetcher.ItemsBegin()); item != fetcher.ItemsEnd(); ++item) {
        pkgAcqArchive *archive(dynamic_cast<pkgAcqArchive *>(*item));
        if ((*item)->Status != pkgAcquire::Item::StatDone || !(*item)->Complete) {
            /* Idle non-archive helper items can be optional. An archive
             * itself must be complete before dpkg may use its filename. */
            if (archive == NULL && (*item)->Status == pkgAcquire::Item::StatIdle)
                continue;
            FetchFailureData failure;
            failure.uri = (*item)->DescURI();
            failure.package = (*item)->ShortDesc();
            failure.kind = (*item)->ErrorText.empty() ?
                FetchDiagnosticKind::ArchiveIncomplete : FetchDiagnosticKind::General;
            failure.error = (*item)->ErrorText.empty() ?
                "Package archive acquisition did not complete." : (*item)->ErrorText;
            result.failures.push_back(failure);
            continue;
        }
        if (archive == NULL)
            continue;

        const ArchiveIntegrity integrity(VerifyArchiveIntegrity(*archive));
        const bool trustProof(CachedRepositoryTrustValid());
        const ArchiveSecurityDecision decision(EvaluateArchiveSecurity(
            mode, trustProof && archive->IsTrusted(), integrity));
        if (decision.allowed && !decision.warning)
            continue;

        FetchFailureData diagnostic;
        diagnostic.uri = archive->DescURI();
        const std::string package(archive->ShortDesc());
        diagnostic.package = package;
        if (integrity == ArchiveIntegrity::MissingExpectedHashes) {
            diagnostic.kind = FetchDiagnosticKind::ArchiveMissingHashes;
            diagnostic.error = "Package archive has no usable expected hashes: " + package;
        } else if (integrity == ArchiveIntegrity::Mismatch) {
            diagnostic.kind = FetchDiagnosticKind::ArchiveMismatch;
            diagnostic.error = "Package archive size or hash verification failed: " + package;
        } else if (integrity == ArchiveIntegrity::Unavailable) {
            diagnostic.kind = FetchDiagnosticKind::ArchiveUnavailable;
            diagnostic.error = "Package archive is unavailable or unreadable: " + package;
        } else if (!trustProof) {
            diagnostic.kind = FetchDiagnosticKind::ArchiveTrustNeedsRefresh;
            diagnostic.error = "Refresh sources to verify repository authentication for this session: " + package;
        } else {
            diagnostic.kind = FetchDiagnosticKind::UnauthenticatedSource;
            diagnostic.error = "Package source is unauthenticated: " + package +
                " (" + diagnostic.uri + ")";
        }

        if (decision.warning)
            result.warnings.push_back(diagnostic);
        else
            result.failures.push_back(diagnostic);
    }
}

} // namespace

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
    originalAutoInstalled_.clear();
    if (!cache_.Open(&progress, false)) return false;
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    for (pkgCache::PkgIterator package(cache.PkgBegin()); !package.end(); ++package) {
        if (package.Name() == NULL || package.Arch() == NULL) continue;
        originalAutoInstalled_[std::string(package.Name()) + ':' + package.Arch()] =
            (cache[package].Flags & pkgCache::Flag::Auto) != 0;
    }
    return true;
}

bool AptBackend::lockForTransaction() {
    if (_system == NULL || _system->IsLocked())
        return _error->Error("The package-manager transaction lock is not available.");
    const std::string configured(_config->Find("Debug::NoLocking"));
    _config->Set("Debug::NoLocking", false);
    const bool success(_system->Lock());
    _config->Set("Debug::NoLocking", configured);
    return success;
}

void AptBackend::unlockForTransaction() {
    if (_system != NULL && _system->IsLocked()) _system->UnLock();
}

std::vector<AutoInstalledDelta> AptBackend::autoInstalledDeltas() {
    std::vector<AutoInstalledDelta> result;
    if (static_cast<pkgDepCache *>(cache_) == NULL) return result;
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    for (pkgCache::PkgIterator package(cache.PkgBegin()); !package.end(); ++package) {
        if (package.Name() == NULL || package.Arch() == NULL) continue;
        const std::string key(std::string(package.Name()) + ':' + package.Arch());
        const bool automatic(!cache[package].Delete() &&
                             (cache[package].Flags & pkgCache::Flag::Auto) != 0);
        const auto before(originalAutoInstalled_.find(key));
        if (before != originalAutoInstalled_.end() && before->second == automatic) continue;
        if (before == originalAutoInstalled_.end() && !automatic) continue;
        result.push_back({package.Name(), package.Arch(), automatic});
    }
    return result;
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

    /* Also verify completed/cached payloads: upstream skips downloading a
     * same-size cached .deb without recalculating its expected hashes. */
    ValidateArchiveItems(*fetcher_, result);
    return result;
}

PackageManagerResult AptBackend::runPackageManager(int statusFd) {
    if (manager_.get() == NULL || fetcher_ == NULL)
        return PackageManagerResult::Failed;
    if (_system == NULL || !_system->IsLocked()) {
        _error->Error("Package execution requires the frontend transaction lock.");
        return PackageManagerResult::Failed;
    }
    /* A resolver or another caller may have introduced an indirect removal.
     * Recheck the final state rather than relying on visible action buttons. */
    if (!transactionData().issues.empty()) {
        _error->Error("The transaction contains blocked package changes.");
        return PackageManagerResult::Failed;
    }

    /* Repeat immediately before execution, including when a caller bypasses
     * runFetcher. Warning mode remains nonblocking; its advisory is returned
     * by runFetcher for presentation before reaching this method. */
    FetchResultData verified;
    ValidateArchiveItems(*fetcher_, verified);
    if (!verified.failures.empty()) {
        for (std::vector<FetchFailureData>::const_iterator failure(verified.failures.begin());
             failure != verified.failures.end(); ++failure)
            _error->Error("%s", failure->error.c_str());
        return PackageManagerResult::Failed;
    }
    /* Follow APT's normal handoff: keep the frontend lock while dpkg owns
     * the inner admin lock, then reacquire the inner lock before persistence. */
    if (!_system->UnLockInner()) return PackageManagerResult::Failed;
#ifdef APT_CYDIA_STATE_FILE_WRITER
    DeferredStateFileWrites deferred;
#else
    _error->Error("The embedded package manager cannot defer shared state writes.");
    return PackageManagerResult::Failed;
#endif
    const PackageManagerResult result(RunPackageManager(*manager_, statusFd));
    if (!_system->LockInner()) return PackageManagerResult::Failed;
    return result;
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
    result.success = UpdateLists(status, list, pulseInterval, result);
    return result;
}

} // namespace Internal
} // namespace CydiaAPT
