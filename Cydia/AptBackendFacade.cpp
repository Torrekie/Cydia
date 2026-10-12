/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptBackend.hpp"
#include "Cydia/AptBackendImplementation.hpp"
#include "Cydia/SourcePreflight.hpp"

namespace CydiaAPT {
AptBackend::~AptBackend() {}
BackendFailure AptBackend::providerFailure() const { return implementation_->providerFailure(); }
bool AptBackend::providerReview(Provider::ReviewedTransaction *review) const { return implementation_->providerReview(review); }

void AptBackend::reset() {
    implementation_->reset();
}

void AptBackend::createCacheViews() {
    implementation_->createCacheViews();
}

std::vector<ErrorData> AptBackend::drainErrors() {
    return implementation_->drainErrors();
}

void AptBackend::discardErrors() {
    implementation_->discardErrors();
}

bool AptBackend::loadSources() {
    return implementation_->loadSources();
}

bool AptBackend::openCache() {
    return implementation_->openCache();
}

bool AptBackend::lockForTransaction() { return implementation_->lockForTransaction(); }
void AptBackend::unlockForTransaction() { implementation_->unlockForTransaction(); }
std::vector<AutoInstalledDelta> AptBackend::autoInstalledDeltas() {
    return implementation_->autoInstalledDeltas();
}

CacheStateSummary AptBackend::cacheState() {
    return implementation_->cacheState();
}

bool AptBackend::applyStatus() {
    return implementation_->applyStatus();
}

bool AptBackend::fixBroken() {
    return implementation_->fixBroken();
}

bool AptBackend::minimizeUpgrade() {
    return implementation_->minimizeUpgrade();
}

bool AptBackend::cleanArchives() {
    return implementation_->cleanArchives();
}

bool AptBackend::prepareArchives() {
    return implementation_->prepareArchives();
}

SourceListData AptBackend::sourceList() {
    return implementation_->sourceList();
}

FetchResultData AptBackend::runFetcher(int pulseInterval) {
    return implementation_->runFetcher(pulseInterval);
}

PackageManagerResult AptBackend::runPackageManager(int statusFd, FetchResultData *archiveValidation, bool *started) {
    return implementation_->runPackageManager(statusFd, archiveValidation, started);
}

UpdateResultData AptBackend::updateLists(AcquireStatus &status, int pulseInterval) {
    return implementation_->updateLists(status, pulseInterval);
}

std::vector<PackageHandle> AptBackend::packageHandles() {
    return implementation_->packageHandles();
}

PackageLookupResult AptBackend::lookupPackage(const std::string &name, const std::string &preferredArchitecture) {
    return implementation_->lookupPackage(name, preferredArchitecture);
}

PackageHandle AptBackend::packageHandle(const std::string &name, const std::string &preferredArchitecture) {
    return implementation_->packageHandle(name, preferredArchitecture);
}

std::vector<PackageHandle> AptBackend::downgradeHandles(PackageHandle handle) {
    return implementation_->downgradeHandles(handle);
}

std::vector<PackageHandle> AptBackend::versionHandles(PackageHandle handle) {
    return implementation_->versionHandles(handle);
}

PackageSnapshot AptBackend::packageSnapshot(PackageHandle handle) {
    return implementation_->packageSnapshot(handle);
}

PackageRecordData AptBackend::recordData(PackageHandle handle) {
    return implementation_->recordData(handle);
}

PackageStateData AptBackend::packageState(PackageHandle handle) {
    return implementation_->packageState(handle);
}

std::vector<RelationData> AptBackend::relations(PackageHandle handle) {
    return implementation_->relations(handle);
}

TransactionData AptBackend::transactionData() {
    return implementation_->transactionData();
}

bool AptBackend::resolveDependencies() {
    return implementation_->resolveDependencies();
}

void AptBackend::clearSelections() {
    implementation_->clearSelections();
}

bool AptBackend::prepareDistUpgrade() {
    return implementation_->prepareDistUpgrade();
}

bool AptBackend::clearPackage(PackageHandle handle) {
    return implementation_->clearPackage(handle);
}

bool AptBackend::installPackage(PackageHandle handle) {
    return implementation_->installPackage(handle);
}

bool AptBackend::reinstallPackage(PackageHandle handle) {
    return implementation_->reinstallPackage(handle);
}

bool AptBackend::removePackage(PackageHandle handle, bool purge) {
    return implementation_->removePackage(handle, purge);
}

std::vector<SourceHandle> AptBackend::sourceHandles() {
    return implementation_->sourceHandles();
}

SourceSnapshot AptBackend::sourceSnapshot(SourceHandle handle) {
    return implementation_->sourceSnapshot(handle);
}

std::string AptBackend::sourceField(SourceHandle handle, const std::string &name) {
    return implementation_->sourceField(handle, name);
}

std::vector<std::uint32_t> AptBackend::sourceFileIDs(SourceHandle handle) {
    return implementation_->sourceFileIDs(handle);
}

SourcePreflightResult AptBackend::sourcePreflight(const SourcePreflightRequest &request,
        const std::function<bool()> &cancelled) {
    return implementation_->sourcePreflight(request, cancelled);
}

SourceResourceResult AptBackend::sourceResource(const SourceResourceRequest &request,
        const std::function<bool()> &cancelled) {
    return implementation_->sourceResource(request, cancelled);
}

} // namespace CydiaAPT
