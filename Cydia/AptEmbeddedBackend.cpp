/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptBackendImplementation.hpp"
#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/AptAcquireStatusBridge.hpp"
#include "Cydia/SourcePreflight.hpp"

namespace CydiaAPT {
namespace Internal {
class EmbeddedBackend final : public BackendImplementation {
    AptBackend embedded_;
public:
    explicit EmbeddedBackend(AcquireStatus &status) :
        embedded_(*static_cast<pkgAcquireStatus *>(NativeAcquireStatus(status))) {}
    void reset() override { embedded_.reset(); }

    void createCacheViews() override { embedded_.createCacheViews(); }

    std::vector<ErrorData> drainErrors() override { return embedded_.drainErrors(); }

    void discardErrors() override { embedded_.discardErrors(); }

    bool loadSources() override { return embedded_.loadSources(); }

    bool openCache() override { return embedded_.openCache(); }

    bool lockForTransaction() override { return embedded_.lockForTransaction(); }
    void unlockForTransaction() override { embedded_.unlockForTransaction(); }
    std::vector<AutoInstalledDelta> autoInstalledDeltas() override { return embedded_.autoInstalledDeltas(); }

    CacheStateSummary cacheState() override { return embedded_.cacheState(); }

    bool applyStatus() override { return embedded_.applyStatus(); }

    bool fixBroken() override { return embedded_.fixBroken(); }

    bool minimizeUpgrade() override { return embedded_.minimizeUpgrade(); }

    bool cleanArchives() override { return embedded_.cleanArchives(); }

    bool prepareArchives() override { return embedded_.prepareArchives(); }

    SourceListData sourceList() override { return embedded_.sourceList(); }

    FetchResultData runFetcher(int pulseInterval) override { return embedded_.runFetcher(pulseInterval); }

    PackageManagerResult runPackageManager(int statusFd, FetchResultData *archiveValidation, bool *started) override { return embedded_.runPackageManager(statusFd, archiveValidation, started); }

    UpdateResultData updateLists(AcquireStatus &status, int pulseInterval) override { return embedded_.updateLists(*static_cast<pkgAcquireStatus *>(Internal::NativeAcquireStatus(status)), pulseInterval); }

    std::vector<PackageHandle> packageHandles() override { return embedded_.packageHandles(); }

    PackageLookupResult lookupPackage(const std::string &name, const std::string &preferredArchitecture) override { return embedded_.lookupPackage(name, preferredArchitecture); }

    PackageHandle packageHandle(const std::string &name, const std::string &preferredArchitecture) override { return embedded_.packageHandle(name, preferredArchitecture); }

    std::vector<PackageHandle> downgradeHandles(PackageHandle handle) override { return embedded_.downgradeHandles(handle); }

    std::vector<PackageHandle> versionHandles(PackageHandle handle) override { return embedded_.versionHandles(handle); }

    PackageSnapshot packageSnapshot(PackageHandle handle) override { return embedded_.packageSnapshot(handle); }

    PackageRecordData recordData(PackageHandle handle) override { return embedded_.recordData(handle); }

    PackageStateData packageState(PackageHandle handle) override { return embedded_.packageState(handle); }

    std::vector<RelationData> relations(PackageHandle handle) override { return embedded_.relations(handle); }

    TransactionData transactionData() override { return embedded_.transactionData(); }

    bool resolveDependencies() override { return embedded_.resolveDependencies(); }

    void clearSelections() override { embedded_.clearSelections(); }

    bool prepareDistUpgrade() override { return embedded_.prepareDistUpgrade(); }

    bool clearPackage(PackageHandle handle) override { return embedded_.clearPackage(handle); }

    bool installPackage(PackageHandle handle) override { return embedded_.installPackage(handle); }

    bool reinstallPackage(PackageHandle handle) override { return embedded_.reinstallPackage(handle); }

    bool removePackage(PackageHandle handle, bool purge) override { return embedded_.removePackage(handle, purge); }

    std::vector<SourceHandle> sourceHandles() override { return embedded_.sourceHandles(); }

    SourceSnapshot sourceSnapshot(SourceHandle handle) override { return embedded_.sourceSnapshot(handle); }

    std::string sourceField(SourceHandle handle, const std::string &name) override { return embedded_.sourceField(handle, name); }

    std::vector<std::uint32_t> sourceFileIDs(SourceHandle handle) override { return embedded_.sourceFileIDs(handle); }

    SourcePreflightResult sourcePreflight(const SourcePreflightRequest &request,
            const std::function<bool()> &cancelled) override { return RunSourcePreflight(request, cancelled); }

    SourceResourceResult sourceResource(const SourceResourceRequest &request,
            const std::function<bool()> &cancelled) override { return FetchSourceResource(request, cancelled); }

};
} // namespace Internal

AptBackend::AptBackend(AcquireStatus &status) : implementation_(new Internal::EmbeddedBackend(status)) {}
void AptBackend::KeepFileDescriptor(int descriptor) { Internal::AptBackend::KeepFileDescriptor(descriptor); }
} // namespace CydiaAPT
