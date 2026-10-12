/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/AptCompatibilityInternal.hpp"
#include "Cydia/AptRuntime.hpp"

#include <apt-pkg/algorithms.h>
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/fileutl.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/strutl.h>
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

std::string FingerprintFileDescriptor(int descriptor) {
    Hashes hashes(Hashes::SHA256SUM);
    if (descriptor < 0 || !hashes.AddFD(descriptor)) return std::string();
    const HashStringList values(hashes.GetHashStringList());
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

namespace {
class RespectPackageHolds {
    std::string original_;
    bool existed_;
public:
    RespectPackageHolds() : original_(_config->Find("APT::Ignore-Hold")),
        existed_(_config->Exists("APT::Ignore-Hold")) {
        _config->Set("APT::Ignore-Hold", false);
    }
    ~RespectPackageHolds() {
        if (existed_) _config->Set("APT::Ignore-Hold", original_);
        else _config->Clear("APT::Ignore-Hold");
    }
};
}

bool FixBroken(pkgDepCache &cache) {
    RespectPackageHolds holds;
    return pkgFixBroken(cache);
}

bool MinimizeUpgrade(pkgDepCache &cache) {
    RespectPackageHolds holds;
    return pkgMinimizeUpgrade(cache);
}

bool PrepareDistUpgrade(pkgDepCache &cache) {
    RespectPackageHolds holds;
    return APT::Upgrade::Upgrade(cache, APT::Upgrade::ALLOW_EVERYTHING);
}

bool ResolveDependencies(pkgProblemResolver &resolver) {
    RespectPackageHolds holds;
    // InstallProtect was already a deprecated no-op in the oldest supported
    // ABI 5 baseline and was removed from newer libapt-pkg releases.
    return resolver.Resolve(true);
}

bool UpdateLists(pkgAcquireStatus &status, pkgSourceList &list, int pulseInterval) {
    return ListUpdate(status, list, pulseInterval);
}

bool UpdateLists(pkgAcquireStatus &status, pkgSourceList &list, int pulseInterval,
                 UpdateResultData &result) {
    pkgAcquire fetcher(&status);
    if (!fetcher.GetLock(_config->FindDir("Dir::State::Lists")) ||
        !list.GetIndexes(&fetcher))
        return false;
    const bool success(AcquireUpdate(fetcher, pulseInterval, true));
    result.metadataComplete = success;
    for (pkgAcquire::ItemIterator item(fetcher.ItemsBegin()); item != fetcher.ItemsEnd(); ++item)
        if ((*item)->Status != pkgAcquire::Item::StatDone)
            result.metadataComplete = false;
#if defined(APT_CYDIA_AUTHENTICATION_PROVENANCE)
    /* Collect while the items still exist, after the normal update scripts,
     * cleanup and transaction commit/abort have run. Never reinterpret
     * StatAuthError: download integrity failures also use that state. */
    for (pkgAcquire::ItemIterator item(fetcher.ItemsBegin()); item != fetcher.ItemsEnd(); ++item) {
        typedef pkgAcquire::Item::AuthenticationIssue Issue;
        const Issue issue((*item)->GetAuthenticationIssue());
        if (issue == Issue::None)
            continue;
        FetchFailureData diagnostic;
        URI uri((*item)->DescURI());
        uri.User.clear();
        uri.Password.clear();
        diagnostic.uri = std::string(uri);
        diagnostic.package = (*item)->ShortDesc();
        switch (issue) {
            case Issue::Unsigned:
                diagnostic.kind = FetchDiagnosticKind::UnsignedRepository;
                diagnostic.error = "Repository is unsigned.";
                break;
            case Issue::MissingKey:
                diagnostic.kind = FetchDiagnosticKind::MissingSigningKey;
                diagnostic.error = "Repository signing key is unavailable.";
                break;
            case Issue::UnusableSignature:
                diagnostic.kind = FetchDiagnosticKind::UnusableSigningKey;
                diagnostic.error = "Repository signature cannot be authenticated with a usable signing key.";
                break;
            case Issue::WeakSecurity:
                diagnostic.kind = FetchDiagnosticKind::WeakRepository;
                diagnostic.error = "Repository provides only weak security information.";
                break;
            case Issue::MissingRelease:
                diagnostic.kind = FetchDiagnosticKind::MissingReleaseFile;
                diagnostic.error = "Repository has no Release file.";
                break;
            case Issue::TrustDowngrade:
                diagnostic.kind = FetchDiagnosticKind::RepositoryTrustDowngrade;
                diagnostic.error = "Repository is no longer authenticated.";
                break;
            case Issue::BadSignature:
                diagnostic.kind = FetchDiagnosticKind::BadRepositorySignature;
                diagnostic.error = "Repository signature does not match its content.";
                break;
            case Issue::InvalidSignature:
                diagnostic.kind = FetchDiagnosticKind::InvalidRepositorySignature;
                diagnostic.error = "Repository signature data is invalid.";
                break;
            case Issue::None:
                break;
        }
        const bool failed((*item)->Status == pkgAcquire::Item::StatError ||
                          (*item)->Status == pkgAcquire::Item::StatAuthError ||
                          (*item)->Status == pkgAcquire::Item::StatTransientNetworkError);
        const RepositorySecurityMode policy(GetRepositorySecurityMode());
        const bool hardFailure(failed || policy == RepositorySecurityMode::Error ||
            (policy != RepositorySecurityMode::Distribution &&
             (issue == Issue::BadSignature || issue == Issue::InvalidSignature)));
        if (hardFailure)
            result.failures.push_back(diagnostic);
        else if (policy == RepositorySecurityMode::Warning)
            result.warnings.push_back(diagnostic);
    }
#endif
    return success;
}

} // namespace CydiaAPT
