/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT lifetime and transaction ownership boundary.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_AptBackend_HPP
#define Cydia_AptBackend_HPP

#include "Cydia/AptCompatibility.hpp"

#include <memory>
#include <functional>

namespace CydiaAPT {

struct AutoInstalledDelta {
    std::string package;
    std::string architecture;
    bool automatic;
};

class AcquireStatus;
struct SourcePreflightRequest;
struct SourcePreflightResult;
struct SourceResourceRequest;
struct SourceResourceResult;

namespace Internal {
class BackendImplementation;
}
namespace Provider { class Session; struct ReviewedTransaction; struct Binding; }

struct BackendFailure {
    // Stable provider/transport code; upstream diagnostics remain ErrorData.
    std::string code;
    bool indeterminate = false;
};

struct RemoteBackendOptions {
    AcquireStatus *status = nullptr;
    // The coordinator routes Session progress and parent execution through
    // this context. Descriptors stay in Cydia and never cross the wire.
    // The status is non-null only during fetch/update/package execution. Reads
    // and cleanup must not reset cancellation or flash transaction progress.
    // The callback is cleared with (nullptr, -1) after each operation.
    std::function<void(AcquireStatus *, int)> operationContext;
    std::function<bool()> cancelled;
    unsigned requestTimeoutMilliseconds = 30000;
    unsigned transactionTimeoutMilliseconds = 3 * 60 * 60 * 1000;
};

/*
 * Database is an Objective-C façade; this class owns every mutable APT
 * handle belonging to one database epoch.  Its storage and all libapt-pkg
 * headers stay in AptBackendInternal.hpp.
 */
class AptBackend {
  private:
    std::unique_ptr<Internal::BackendImplementation> implementation_;

  public:
    explicit AptBackend(AcquireStatus &status);
    // Explicit integration seam only: takes an already started/validated
    // session and never constructs or falls back to embedded APT. Discovery,
    // parent authorization and production activation belong to a coordinator.
    explicit AptBackend(std::unique_ptr<Provider::Session> session,
                        const RemoteBackendOptions &options = RemoteBackendOptions());
    ~AptBackend();
    BackendFailure providerFailure() const;
    // Supplies the complete accepted remote manifest only while its binding
    // remains current. Embedded backends have no protocol review manifest.
    bool providerReview(Provider::ReviewedTransaction *review) const;
    bool providerBinding(Provider::Binding *binding) const;

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
    SourceListData sourceList();
    FetchResultData runFetcher(int pulseInterval);
    PackageManagerResult runPackageManager(int statusFd, FetchResultData *archiveValidation = NULL,
                                          bool *started = NULL);
    UpdateResultData updateLists(AcquireStatus &status, int pulseInterval);
    std::vector<PackageHandle> packageHandles();
    PackageLookupResult lookupPackage(const std::string &name, const std::string &preferredArchitecture);
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
    SourcePreflightResult sourcePreflight(const SourcePreflightRequest &request,
        const std::function<bool()> &cancelled = std::function<bool()>());
    SourceResourceResult sourceResource(const SourceResourceRequest &request,
        const std::function<bool()> &cancelled = std::function<bool()>());
};

} // namespace CydiaAPT

#endif // Cydia_AptBackend_HPP
