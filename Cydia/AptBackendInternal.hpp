/* Cydia - iPhone UIKit Front-End for Debian APT
 * Private libapt-pkg storage for AptBackend.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_AptBackendInternal_HPP
#define Cydia_AptBackendInternal_HPP

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/AptBackend.hpp"
#include "Cydia/PackageArchivePolicy.hpp"

#include <apt-pkg/acquire.h>
#include <apt-pkg/algorithms.h>
#include <apt-pkg/cachefile.h>
#include <apt-pkg/contrib/fileutl.h>
#include <apt-pkg/packagemanager.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sourcelist.h>

#include <memory>

namespace CydiaAPT {
struct RecoveryCaptureResult;
struct RuntimeDescriptor;
namespace Internal {

class PackageRegistry;
class SourceRegistry;

// Own a parser's exact control record before another lookup moves its cursor.
PackageRecordData ReadPackageRecord(pkgRecords::Parser &parser);

struct PreparedArchiveData {
    CydiaPackages::ArchiveIdentity identity;
    std::string package;
    bool commercial = false;
    std::set<std::string> commercialSources;
};

/* Obtain commercial grants without changing APT's selected package/version
 * or replacing its integrity checks. Newly staged files require GetArchives
 * to be rebuilt before the ordinary acquisition/validation path continues. */
bool StageAuthorizedArchives(pkgAcquire &fetcher, pkgAcquireStatus &status,
    const std::map<const pkgAcquire::Item *, PreparedArchiveData> &archives,
    FetchResultData *result, bool *staged, int pulseInterval);

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
    std::unique_ptr<PackageRegistry> packages_;
    std::unique_ptr<SourceRegistry> sources_;
    std::map<std::string, bool> originalAutoInstalled_;
    std::map<const pkgAcquire::Item *, PreparedArchiveData> preparedArchives_;
    std::string preparedPlan_;
    std::string preparedPrefix_;
    bool archivesPrepared_ = false;
    void validateArchives(FetchResultData &result);

  public:
    explicit AptBackend(pkgAcquireStatus &status);
    ~AptBackend();

    static void KeepFileDescriptor(int descriptor);

    void reset();
    void createCacheViews();
    std::vector<ErrorData> drainErrors();
    void discardErrors();
    bool loadSources();
    bool openCache();
    bool lockForTransaction();
    void unlockForTransaction();
    std::vector<AutoInstalledDelta> autoInstalledDeltas();
    CacheStateSummary cacheState();
    bool applyStatus();
    bool fixBroken();
    bool minimizeUpgrade();
    bool cleanArchives();
    bool prepareArchives();
    bool preparedRepositoryAccessRequests(std::vector<RepositoryArchiveAccessRequest> *requests);
    void releasePreparedArchiveLock();
    // Recording-only preview; independent of prepareArchives and manager_.
    // The caller holds the process-wide APT configuration/cache gate.
    RecoveryCaptureResult captureRecoveryReview(const RuntimeDescriptor &runtime,
        const Provider::Binding &binding, const CydiaPackages::ArchiveLayout &layout,
        const std::function<bool()> &cancelled = {}, bool finiteEffects = false);
    SourceListData sourceList();
    FetchResultData runFetcher(int pulseInterval);
    PackageManagerResult runPackageManager(int statusFd, FetchResultData *archiveValidation = NULL,
                                          bool *started = NULL);
    UpdateResultData updateLists(pkgAcquireStatus &status, int pulseInterval);
    std::vector<PackageHandle> packageHandles();
    PackageLookupResult lookupPackage(const std::string &name, const std::string &preferredArchitecture);
    RepositoryPackageAvailabilityData repositoryPackageAvailability(const std::string &name,
        const std::string &sourceURL);
    PackageHandle packageHandle(const std::string &name, const std::string &preferredArchitecture);
    std::vector<PackageHandle> downgradeHandles(PackageHandle handle);
    std::vector<PackageHandle> versionHandles(PackageHandle handle);
    PackageSnapshot packageSnapshot(PackageHandle handle);
    PackageRecordData recordData(PackageHandle handle);
    PackageStateData packageState(PackageHandle handle);
    std::vector<RelationData> relations(PackageHandle handle);
    TransactionData transactionData();
    bool resolveDependencies();
    void clearSelections();
    bool prepareDistUpgrade();
    bool clearPackage(PackageHandle handle);
    bool installPackage(PackageHandle handle);
    bool reinstallPackage(PackageHandle handle);
    bool removePackage(PackageHandle handle, bool purge = false);
    std::vector<SourceHandle> sourceHandles();
    SourceSnapshot sourceSnapshot(SourceHandle handle);
    std::string sourceField(SourceHandle handle, const std::string &name);
    std::vector<std::uint32_t> sourceFileIDs(SourceHandle handle);
};

} // namespace Internal
} // namespace CydiaAPT

#endif // Cydia_AptBackendInternal_HPP
