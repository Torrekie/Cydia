/* Read-only libapt archive selection for recovery transaction review.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/AptRecoveryPackageManager.hpp"
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/debindexfile.h>
#include <apt-pkg/error.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/strutl.h>
#include <set>
#include <sys/stat.h>

namespace CydiaAPT { namespace Internal {
namespace {
void CopyConfiguration(const Configuration::Item *item, Configuration &copy,
        const std::string &prefix = "") {
    for (; item; item = item->Next) {
        const std::string name(prefix.empty() ? item->Tag : prefix + "::" + item->Tag);
        copy.Set(name, item->Value);
        CopyConfiguration(item->Child, copy, name);
    }
}
// NoQueue alone is insufficient: pkgAcqArchive removes wrong-size cached and
// oversized partial files before consulting it. /dev/zero is checked to be a
// character device, so every child lookup fails with ENOTDIR. No directory is
// created. The original configuration (including absent keys and subtrees) is
// restored by identity, even if recording or cancellation throws.
struct PreviewConfiguration {
    Configuration *original = _config;
    Configuration copy;
    PreviewConfiguration() {
        CopyConfiguration(original->Tree(nullptr), copy);
        // APT specially truncates every /dev/null child path to /dev/null,
        // so use a separately checked non-directory device instead.
        copy.Set("Dir::Cache::Archives", "/dev/zero/cydia-review/");
        copy.Set("Debug::pkgAcqArchive::NoQueue", true);
        copy.Set("Debug::pkgAcquire", false);
        copy.Set("Debug::pkgAcquire::Auth", false);
        _config = &copy;
    }
    ~PreviewConfiguration() { _config = original; }
};
bool AbsolutePath(const std::string &value) {
    if (value.empty() || value.front() != '/') return false;
    for (unsigned char c : value) if (c < 32 || c == 127) return false;
    std::size_t position = 1;
    while (position < value.size()) {
        const auto end = value.find('/', position);
        const auto part = value.substr(position, end == std::string::npos ? end : end - position);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        position = end + 1;
    }
    return true;
}
bool SameHashes(const HashStringList &record, const HashStringList &selected) {
    // HashStringList::operator== accepts partial overlap and Acquire::ForceHash;
    // neither is sufficient to bind an exact selected index record.
    // APT can add hash types supplied only by alternative mirrors. Keep the
    // chosen record's full assertions, permitting that stricter acquisition
    // superset rather than requiring every mirror to advertise the same types.
    if (!record.FileSize() ||
        (!record.find("SHA256") && !record.find("SHA512"))) return false;
    for (const auto &hash : record) {
        const auto *other = selected.find(hash.HashType());
        if (!other || hash.HashValue() != other->HashValue()) return false;
    }
    return true;
}
bool Matches(pkgAcqArchive &archive, pkgCache::VerIterator version,
        pkgCache::VerFileIterator file, pkgSourceList &sources, pkgRecords &records) {
    if (file.File().Flagged(pkgCache::Flag::NotSource)) return false;
    pkgIndexFile *index = nullptr;
    if (!sources.FindIndex(file.File(), index)) return false;
    // Match only the actual origin eligible under libapt's trust selection.
    if (archive.IsTrusted() && !index->IsTrusted()) return false;
    const auto *debian = dynamic_cast<pkgDebianIndexTargetFile *>(index);
    if (!debian) return false;
    const auto target = debian->GetIndexTarget();
    auto &record = records.Lookup(file);
    if (record.RecordField("Package") != version.ParentPkg().Name() ||
        record.RecordField("Version") != version.VerStr() ||
        record.RecordField("Architecture") != version.Arch() ||
        record.FileName().empty() || index->ArchiveURI(record.FileName()) != archive.DescURI() ||
        record.Hashes().FileSize() != archive.FileSize || archive.FileSize != version->Size ||
        !SameHashes(record.Hashes(), archive.GetExpectedHashes())) return false;
    const auto headers = archive.Custom600Headers();
    const auto equal = [&](const char *name, const std::string &expected) {
        return LookupTag(headers, name) == expected;
    };
    const auto release = file.File().ReleaseFile();
    return equal("Target-Repo-URI", target.Option(IndexTarget::REPO_URI)) &&
        equal("Target-Release", target.Option(IndexTarget::RELEASE)) &&
        equal("Target-Site", target.Option(IndexTarget::SITE)) &&
        equal("Target-Base-URI", index->ArchiveURI("")) &&
        equal("Target-Architecture", version.Arch()) &&
        equal("Target-Type", flExtension(record.FileName())) &&
        equal("Target-Component", file.File()->Component ? file.File().Component() : "") &&
        equal("Target-Codename", !release.end() && release.Codename() ? release.Codename() : "") &&
        equal("Target-Suite", !release.end() && release.Archive() ? release.Archive() : "");
}
}

RecoveryCaptureResult AptBackend::captureRecoveryReview(const RuntimeDescriptor &runtime,
        const Provider::Binding &binding, const CydiaPackages::ArchiveLayout &layout,
        const std::function<bool()> &cancelled, bool finiteEffects) {
    const auto fail = [](const char *code, RecoveryCaptureStatus status = RecoveryCaptureStatus::Unsupported) {
        RecoveryCaptureResult result; result.status = status; result.errorCode = code; return result;
    };
    if (cancelled && cancelled()) return fail("recovery_cancelled", RecoveryCaptureStatus::Cancelled);
    if (!_config || !static_cast<pkgDepCache *>(cache_) || !records_)
        return fail("recovery_cache_unavailable", RecoveryCaptureStatus::Failed);
    // RootDir also rebases absolute paths, including the non-directory guard.
    // Refuse before GetArchives has a chance to inspect any archive file.
    if (!_config->Find("RootDir").empty()) return fail("recovery_rootdir_ordering_unsupported");
    struct stat guardDevice;
    if (stat("/dev/zero", &guardDevice) || !S_ISCHR(guardDevice.st_mode))
        return fail("recovery_preview_guard_unavailable");
    const auto archivesDirectory = _config->FindDir("Dir::Cache::Archives");
    if (!AbsolutePath(archivesDirectory) || archivesDirectory.back() != '/')
        return fail("recovery_archive_directory_unsupported");
    const auto transaction = transactionData();
    pkgDepCache &cache = static_cast<pkgDepCache &>(cache_);
    PreviewConfiguration preview;
    pkgSourceList sources;
    if (!sources.ReadMainList()) return fail("recovery_sources_unavailable", RecoveryCaptureStatus::Failed);
    pkgRecords records(cache);
    AptRecoveryPackageManager recorder(&cache);
    std::map<std::string, std::vector<pkgCache::VerIterator>> selectedVersions;
    for (auto package = cache.PkgBegin(); !package.end(); ++package) {
        if (cache[package].Delete()) continue;
        const auto version = cache[package].InstVerIter(cache);
        if (!version.end()) selectedVersions[package.FullName(true)].push_back(version);
    }
    {
        pkgAcquire acquisition;
        if (!recorder.GetArchives(&acquisition, &sources, &records) || _error->PendingError())
            return fail("recovery_archive_selection_failed", RecoveryCaptureStatus::Failed);
        std::set<unsigned long> bound;
        for (auto item = acquisition.ItemsBegin(); item != acquisition.ItemsEnd(); ++item) {
            if (cancelled && cancelled()) return fail("recovery_cancelled", RecoveryCaptureStatus::Cancelled);
            auto *archive = dynamic_cast<pkgAcqArchive *>(*item);
            if (!archive || !archive->Complete || archive->Status != pkgAcquire::Item::StatDone)
                return fail("recovery_archive_selection_failed");
            pkgCache::VerIterator selected;
            pkgCache::VerFileIterator selectedRecord;
            unsigned matches = 0;
            const auto versions = selectedVersions.find(archive->ShortDesc());
            if (versions == selectedVersions.end()) return fail("recovery_archive_origin_unavailable");
            for (const auto version : versions->second) {
                for (auto file = version.FileList(); !file.end(); ++file) {
                    if (cancelled && cancelled()) return fail("recovery_cancelled", RecoveryCaptureStatus::Cancelled);
                    if (!Matches(*archive, version, file, sources, records)) continue;
                    selected = version; selectedRecord = file; ++matches;
                }
            }
            if (matches != 1) return fail(matches ? "recovery_archive_origin_ambiguous" : "recovery_archive_origin_unavailable");
            if (!bound.insert(selected.ParentPkg()->ID).second) return fail("recovery_duplicate_archive_binding");
            const auto leaf = flNotDir(archive->DestFile);
            if (leaf.empty() || leaf == "." || leaf == ".." ||
                archive->DestFile != "/dev/zero/cydia-review/" + leaf)
                return fail("recovery_archive_path_unavailable");
            std::string error;
            if (!recorder.BindArchive(selected, selectedRecord, archivesDirectory + leaf, &error))
                return fail(error.c_str());
        }
    }
    // Destroy the preview queue before recording order. Keep the isolated
    // configuration through ordering so temporary planner-log suppression also
    // cannot leave previously absent keys behind in the app's configuration.
    // No existing manager/fetcher or prepared state is used.
    return recorder.Capture(sources, records, runtime, transaction, binding, layout, cancelled, finiteEffects);
}
}} // namespace CydiaAPT::Internal
