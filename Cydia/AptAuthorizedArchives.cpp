/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/RepositoryArchiveAuthorization.hpp"
#include "Cydia/RedactedURL.hpp"

#include <apt-pkg/acquire-item.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/strutl.h>
#include <apt-pkg/proxy.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstdlib>
#include <cstring>
#include <strings.h>

namespace CydiaAPT { namespace Internal {
namespace {
struct StageDirectory {
    std::string directory, file;
    explicit StageDirectory(const std::string &parent) {
        std::string pattern(parent + ".cydia-authorized.XXXXXX");
        std::vector<char> buffer(pattern.begin(), pattern.end()); buffer.push_back(0);
        if (mkdtemp(buffer.data()) != NULL) { directory = buffer.data(); file = directory + "/payload.deb"; }
    }
    ~StageDirectory() {
        if (directory.empty()) return;
        unlink(file.c_str()); unlink((file + ".FAILED").c_str()); rmdir(directory.c_str());
    }
};

void CopyConfiguration(const Configuration::Item *item, Configuration &copy, const std::string &prefix = "") {
    for (; item != NULL; item = item->Next) {
        const std::string name(prefix.empty() ? item->Tag : prefix + "::" + item->Tag);
        copy.Set(name, item->Value); CopyConfiguration(item->Child, copy, name);
    }
}

void PrivateMethodConfiguration(const Configuration::Item *item, Configuration &copy,
                                const std::string &prefix = "") {
    for (; item != NULL; item = item->Next) {
        const std::string name(prefix.empty() ? item->Tag : prefix + "::" + item->Tag);
        // Methods merge Binary::<method> into the root after receiving the
        // configuration. Remove hidden overrides as well as root settings.
        if (strcasecmp(item->Tag.c_str(), "Debug") == 0 ||
            strcasecmp(item->Tag.c_str(), "Proxy-Auto-Detect") == 0 ||
            strcasecmp(item->Tag.c_str(), "ProxyAutoDetect") == 0)
            copy.Clear(name);
        else
            PrivateMethodConfiguration(item->Child, copy, name);
    }
}

/* Signed URLs are capabilities. Do not emit them through APT's wire tracing,
 * even when debugging is enabled for ordinary repository acquisition. Keep
 * the administrator's configuration unchanged outside this download. */
struct PrivateAcquisition {
    Configuration *original = _config;
    Configuration configuration;
    bool ready = false;
    explicit PrivateAcquisition(const URI &transport) {
        CopyConfiguration(original->Tree(NULL), configuration);
        configuration.Clear("Debug");
        configuration.Set("Debug::NoLocking", original->FindB("Debug::NoLocking", false));
        _config = &configuration;
        // APT passes a URL as argv to proxy autodetection commands. Resolve
        // only an origin here and prohibit later invocation with a grant.
        URI origin(transport);
        origin.Path = "/"; origin.User.clear(); origin.Password.clear();
        ready = AutoDetectProxy(origin);
        PrivateMethodConfiguration(original->Tree(NULL), configuration);
        configuration.Set("Debug::NoLocking", original->FindB("Debug::NoLocking", false));
    }
    ~PrivateAcquisition() { _config = original; }
};

bool Failure(FetchResultData *result, const PreparedArchiveData &expected,
             const std::string &message, const char *reason) {
    FetchFailureData failure;
    failure.package = expected.package;
    failure.kind = FetchDiagnosticKind::General;
    failure.reason = reason;
    if (std::strcmp(reason, "archive_missing_hashes") == 0) failure.kind = FetchDiagnosticKind::ArchiveMissingHashes;
    else if (std::strcmp(reason, "archive_hash_mismatch") == 0) failure.kind = FetchDiagnosticKind::ArchiveMismatch;
    else if (std::strcmp(reason, "archive_staging_failed") == 0) failure.kind = FetchDiagnosticKind::ArchiveUnavailable;
    else if (std::strcmp(reason, "authorized_download_failed") == 0 && message.empty())
        failure.kind = FetchDiagnosticKind::ArchiveIncomplete;
    failure.error = CydiaRuntime::RedactDiagnosticURLs(message);
    result->failures.push_back(failure);
    // This is a completed attempt with a diagnostic, not a cancelled fetch.
    result->completed = true;
    return false;
}

bool Verify(const std::string &path, const HashStringList &expected, unsigned long long size) {
    int fd(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    if (fd < 0) return false;
    struct stat st;
    bool valid(fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= 0 &&
        static_cast<unsigned long long>(st.st_size) == size);
    if (valid) {
        Hashes actual(expected);
        valid = actual.AddFD(fd) && actual.GetHashStringList() == expected;
    }
    close(fd); return valid;
}
}

bool StageAuthorizedArchives(pkgAcquire &fetcher, pkgAcquireStatus &status,
    const std::map<const pkgAcquire::Item *, PreparedArchiveData> &archives,
    FetchResultData *result, bool *staged, int pulseInterval) {
    using namespace CydiaRuntime;
    *staged = false;
    for (auto item(fetcher.ItemsBegin()); item != fetcher.ItemsEnd(); ++item) {
        pkgAcqArchive *archive(dynamic_cast<pkgAcqArchive *>(*item));
        if (archive == NULL) continue;
        const auto found(archives.find(archive));
        if (found == archives.end() || !found->second.commercial) continue;
        // An existing archive still goes through normal hash/layout validation.
        if (archive->Status == pkgAcquire::Item::StatDone && archive->Complete) continue;
        const PreparedArchiveData &expected(found->second);
        const HashStringList hashes(archive->GetExpectedHashes());
        RepositoryArchiveAuthorizationRequest request;
        request.sourceURL = LookupTag(archive->Custom600Headers(), "Target-Repo-URI");
        request.package = expected.identity.package;
        request.version = expected.identity.version;
        request.architecture = expected.identity.architecture;
        status.Start();
        const auto grant(AuthorizeRepositoryArchive(request, [&]() { return !status.Pulse(&fetcher); }));
        status.Stop();
        if (grant.status == RepositoryArchiveAuthorizationStatus::NotRequired) continue;
        if (grant.status == RepositoryArchiveAuthorizationStatus::Cancelled) return false;
        if (grant.status != RepositoryArchiveAuthorizationStatus::Authorized)
            return Failure(result, expected, grant.message,
                grant.status == RepositoryArchiveAuthorizationStatus::Unsupported ?
                    "repository_authorization_required" : "repository_authorization_failed");
        if (!hashes.usable() || archive->FileSize == 0)
            return Failure(result, expected, "The authorized archive has no usable repository integrity information.", "archive_missing_hashes");
        const URI transport(grant.transportURL);
        if (transport.Access != "https" || transport.Host.empty() || !transport.User.empty() ||
            !transport.Password.empty() || grant.transportURL.find_first_of("\r\n\t ") != std::string::npos)
            return Failure(result, expected, "The repository returned an invalid download authorization.", "invalid_download_grant");
        const std::string cache(_config->FindDir("Dir::Cache::Archives"));
        StageDirectory temporary(cache);
        if (temporary.directory.empty())
            return Failure(result, expected, "Could not create a private package download.", "archive_staging_failed");
        {
            PrivateAcquisition configuration(transport);
            if (!configuration.ready)
                return Failure(result, expected, "", "authorized_download_failed");
            pkgAcquire authorized(&status);
            pkgAcqFile *download(new pkgAcqFile(&authorized, grant.transportURL, hashes, archive->FileSize,
                expected.package, expected.package, "", temporary.file));
            if (authorized.Run(pulseInterval) != pkgAcquire::Continue) return false;
            if (download->Status != pkgAcquire::Item::StatDone || !download->Complete)
                return Failure(result, expected, download->ErrorText, "authorized_download_failed");
        }
        if (!Verify(temporary.file, hashes, archive->FileSize))
            return Failure(result, expected, "The authorized package does not match the repository's hashes and size.", "archive_hash_mismatch");
        const std::string leaf(flNotDir(archive->DestFile));
        if (leaf.empty() || leaf == "." || leaf == ".." ||
            rename(temporary.file.c_str(), (cache + leaf).c_str()) != 0)
            return Failure(result, expected, "Could not place the verified package in the archive cache.", "archive_staging_failed");
        *staged = true;
    }
    return true;
}
} }
