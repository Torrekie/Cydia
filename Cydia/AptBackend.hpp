/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT lifetime and transaction ownership boundary.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_AptBackend_HPP
#define Cydia_AptBackend_HPP

#include "Cydia/AptCompatibility.hpp"

#include <memory>

namespace CydiaAPT {

class AcquireStatus;

namespace Internal {
class AptBackend;
}

/*
 * Database is an Objective-C façade; this class owns every mutable APT
 * handle belonging to one database epoch.  Its storage and all libapt-pkg
 * headers stay in AptBackendInternal.hpp.
 */
class AptBackend {
  private:
    std::unique_ptr<Internal::AptBackend> implementation_;

  public:
    explicit AptBackend(AcquireStatus &status);
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
    UpdateResultData updateLists(AcquireStatus &status, int pulseInterval);
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
