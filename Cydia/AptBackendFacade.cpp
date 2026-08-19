/* Cydia - iPhone UIKit Front-End for Debian APT
 * Stable façade for the private libapt-pkg backend.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptBackend.hpp"
#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/AptAcquireStatusBridge.hpp"

namespace CydiaAPT {

AptBackend::AptBackend(AcquireStatus &status) :
    implementation_(new Internal::AptBackend(*static_cast<pkgAcquireStatus *>(Internal::NativeAcquireStatus(status))))
{
}

AptBackend::~AptBackend() {
}

void AptBackend::KeepFileDescriptor(int descriptor) {
    Internal::AptBackend::KeepFileDescriptor(descriptor);
}

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

PackageManagerResult AptBackend::runPackageManager(int statusFd) {
    return implementation_->runPackageManager(statusFd);
}

UpdateResultData AptBackend::updateLists(AcquireStatus &status, int pulseInterval) {
    return implementation_->updateLists(*static_cast<pkgAcquireStatus *>(Internal::NativeAcquireStatus(status)), pulseInterval);
}

std::vector<PackageHandle> AptBackend::packageHandles() {
    return implementation_->packageHandles();
}

PackageHandle AptBackend::packageHandle(const std::string &name, const std::string &preferredArchitecture) {
    return implementation_->packageHandle(name, preferredArchitecture);
}

std::vector<PackageHandle> AptBackend::downgradeHandles(PackageHandle handle) {
    return implementation_->downgradeHandles(handle);
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

bool AptBackend::removePackage(PackageHandle handle) {
    return implementation_->removePackage(handle);
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

} // namespace CydiaAPT
