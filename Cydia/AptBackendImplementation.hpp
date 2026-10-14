/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptBackendImplementation_HPP
#define Cydia_AptBackendImplementation_HPP
#include "Cydia/AptBackend.hpp"

namespace CydiaAPT { namespace Internal {
// Value-only interface shared by embedded and process-isolated providers.
class BackendImplementation {
public:
    virtual ~BackendImplementation() {}
    virtual BackendFailure providerFailure() const { return BackendFailure(); }
    virtual bool providerReview(Provider::ReviewedTransaction *) const { return false; }
    virtual bool providerBinding(Provider::Binding *) const { return false; }
    virtual void retireProvider() {}
    virtual void reset() = 0;
    virtual void createCacheViews() = 0;
    virtual std::vector<ErrorData> drainErrors() = 0;
    virtual void discardErrors() = 0;
    virtual bool loadSources() = 0;
    virtual bool openCache() = 0;
    virtual bool lockForTransaction() = 0;
    virtual void unlockForTransaction() = 0;
    virtual std::vector<AutoInstalledDelta> autoInstalledDeltas() = 0;
    virtual CacheStateSummary cacheState() = 0;
    virtual bool applyStatus() = 0;
    virtual bool fixBroken() = 0;
    virtual bool minimizeUpgrade() = 0;
    virtual bool cleanArchives() = 0;
    virtual bool prepareArchives() = 0;
    virtual bool preparedRepositoryAccessRequests(std::vector<RepositoryArchiveAccessRequest> *requests) {
        if (requests) requests->clear();
        return false;
    }
    virtual void releasePreparedArchiveLock() {}
    virtual SourceListData sourceList() = 0;
    virtual FetchResultData runFetcher(int pulseInterval) = 0;
    virtual PackageManagerResult runPackageManager(int statusFd, FetchResultData *archiveValidation,
                                          bool *started) = 0;
    virtual UpdateResultData updateLists(AcquireStatus &status, int pulseInterval) = 0;
    virtual std::vector<PackageHandle> packageHandles() = 0;
    virtual PackageLookupResult lookupPackage(const std::string &name, const std::string &preferredArchitecture) = 0;
    virtual PackageHandle packageHandle(const std::string &name, const std::string &preferredArchitecture) = 0;
    virtual std::vector<PackageHandle> downgradeHandles(PackageHandle handle) = 0;
    virtual std::vector<PackageHandle> versionHandles(PackageHandle handle) = 0;
    virtual PackageSnapshot packageSnapshot(PackageHandle handle) = 0;
    virtual PackageRecordData recordData(PackageHandle handle) = 0;
    virtual PackageStateData packageState(PackageHandle handle) = 0;
    virtual std::vector<RelationData> relations(PackageHandle handle) = 0;
    virtual TransactionData transactionData() = 0;
    virtual bool resolveDependencies() = 0;
    virtual void clearSelections() = 0;
    virtual bool prepareDistUpgrade() = 0;
    virtual bool clearPackage(PackageHandle handle) = 0;
    virtual bool installPackage(PackageHandle handle) = 0;
    virtual bool reinstallPackage(PackageHandle handle) = 0;
    virtual bool removePackage(PackageHandle handle, bool purge) = 0;
    virtual std::vector<SourceHandle> sourceHandles() = 0;
    virtual SourceSnapshot sourceSnapshot(SourceHandle handle) = 0;
    virtual std::string sourceField(SourceHandle handle, const std::string &name) = 0;
    virtual std::vector<std::uint32_t> sourceFileIDs(SourceHandle handle) = 0;
    virtual SourcePreflightResult sourcePreflight(const SourcePreflightRequest &request,
        const std::function<bool()> &cancelled) = 0;
    virtual SourceResourceResult sourceResource(const SourceResourceRequest &request,
        const std::function<bool()> &cancelled) = 0;
};
}} // namespace CydiaAPT::Internal
#endif
