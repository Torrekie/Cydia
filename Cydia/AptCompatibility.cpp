/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/AptCompatibilityInternal.hpp"

#include <apt-pkg/algorithms.h>
#include <apt-pkg/clean.h>
#include <apt-pkg/depcache.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/install-progress.h>
#include <apt-pkg/macros.h>
#include <apt-pkg/packagemanager.h>
#include <apt-pkg/pkgcache.h>
#include <apt-pkg/upgrade.h>
#include <apt-pkg/update.h>

#if !defined(APT_PKG_ABI) || APT_PKG_ABI < 500
#error "Cydia's APT compatibility layer requires libapt-pkg ABI 5.0 or newer"
#endif

#include <sys/stat.h>
#include <strings.h>
#include <unistd.h>

namespace CydiaAPT {

std::string PackageRecordData::Field(const char *name) const {
    if (name == NULL)
        return std::string();
    std::map<std::string, std::string>::const_iterator field(fields.find(name));
    if (field != fields.end())
        return field->second;
    for (field = fields.begin(); field != fields.end(); ++field)
        if (strcasecmp(field->first.c_str(), name) == 0)
            return field->second;
    return std::string();
}

PackageStateData::PackageStateData() :
    essential(false),
    ignored(false),
    broken(false),
    hasMode(false),
    half(false),
    halfConfigured(false),
    halfInstalled(false),
    hasCurrent(false),
    upgradable(false),
    candidateMatchesVersion(false),
    newInstall(false),
    deletePackage(false),
    reinstall(false),
    upgrade(false),
    downgrade(false)
{
}

PackageSnapshot::PackageSnapshot() :
    installedSize(0),
    sourceFileID(0),
    hasSourceFile(false),
    defaultPriority(false)
{
}

TransactionData::TransactionData() :
    downloading(0),
    resuming(0),
    removesEssential(false),
    substrate(false)
{
}

SourceSnapshot::SourceSnapshot() :
    trusted(false)
{
}

CacheStateSummary::CacheStateSummary() :
    deletes(0),
    installs(0),
    broken(0)
{
}

FetchResultData::FetchResultData() :
    completed(false)
{
}

SourceListData::SourceListData() :
    success(false)
{
}

UpdateResultData::UpdateResultData() :
    prepared(false),
    success(false)
{
}

std::string Fingerprint(const void *data, std::size_t size) {
    if (data == NULL && size != 0)
        return std::string();

    unsigned char empty(0);
    const unsigned char *bytes(data == NULL ? &empty : static_cast<const unsigned char *>(data));
    Hashes hashes(Hashes::SHA256SUM);
    if (!hashes.Add(bytes, size))
        return std::string();

    HashStringList values(hashes.GetHashStringList());
    const HashString *value(values.find("SHA256"));
    return value == NULL ? std::string() : value->HashValue();
}

PackageManagerResult RunPackageManager(pkgPackageManager &manager, int statusFd) {
    APT::Progress::PackageManagerProgressFd progress(statusFd);

    switch (manager.DoInstall(&progress)) {
        case pkgPackageManager::Failed:
            return PackageManagerResult::Failed;
        case pkgPackageManager::Incomplete:
            return PackageManagerResult::Incomplete;
        case pkgPackageManager::Completed:
            return PackageManagerResult::Completed;
    }

    return PackageManagerResult::Failed;
}

namespace {

class ArchiveCleaner : public pkgArchiveCleaner {
  protected:
#if APT_PKG_MAJOR >= 6
    virtual void Erase(int const directoryFd, char const * const file,
                       std::string const &, std::string const &,
                       struct stat const &) {
        if (directoryFd >= 0)
            (void) unlinkat(directoryFd, file, 0);
        else
            (void) unlink(file);
    }
#else
    virtual void Erase(const char *file, std::string, std::string, struct stat &) {
        (void) unlink(file);
    }
#endif
};

} // namespace

bool CleanArchives(const std::string &directory, pkgCache &cache) {
    ArchiveCleaner cleaner;
    return cleaner.Go(directory, cache);
}

bool ApplyStatus(pkgDepCache &cache) {
    return pkgApplyStatus(cache);
}

bool FixBroken(pkgDepCache &cache) {
    return pkgFixBroken(cache);
}

bool MinimizeUpgrade(pkgDepCache &cache) {
    return pkgMinimizeUpgrade(cache);
}

bool PrepareDistUpgrade(pkgDepCache &cache) {
    return APT::Upgrade::Upgrade(cache, APT::Upgrade::ALLOW_EVERYTHING);
}

bool ResolveDependencies(pkgProblemResolver &resolver) {
    // InstallProtect was already a deprecated no-op in the oldest supported
    // ABI 5 baseline and was removed from newer libapt-pkg releases.
    return resolver.Resolve(true);
}

bool UpdateLists(pkgAcquireStatus &status, pkgSourceList &list, int pulseInterval) {
    return ListUpdate(status, list, pulseInterval);
}

} // namespace CydiaAPT
