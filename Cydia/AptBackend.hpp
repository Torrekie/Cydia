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

class PackageRegistry;
class SourceRegistry;

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
    std::unique_ptr<PackageRegistry> packages_;
    std::unique_ptr<SourceRegistry> sources_;

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
    CacheStateSummary cacheState();
    bool applyStatus();
    bool fixBroken();
    bool minimizeUpgrade();
    bool cleanArchives();
    bool prepareArchives();
    SourceListData sourceList();
    FetchResultData runFetcher(int pulseInterval);
    PackageManagerResult runPackageManager(int statusFd);
    UpdateResultData updateLists(pkgAcquireStatus &status, int pulseInterval);
    std::vector<PackageHandle> packageHandles();
    PackageHandle packageHandle(const std::string &name, const std::string &preferredArchitecture);
    std::vector<PackageHandle> downgradeHandles(PackageHandle handle);
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
    bool removePackage(PackageHandle handle);
    std::vector<SourceHandle> sourceHandles();
    SourceSnapshot sourceSnapshot(SourceHandle handle);
    std::string sourceField(SourceHandle handle, const std::string &name);
    std::vector<std::uint32_t> sourceFileIDs(SourceHandle handle);
};

} // namespace CydiaAPT

#endif // Cydia_AptBackend_HPP
