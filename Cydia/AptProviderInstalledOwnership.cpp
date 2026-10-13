/* Native metadata capture only: no path type, sharing or disappearance claim.
 * dpkg 1.21/1.23: lib/dpkg/db-fsys-files.c, db-fsys-divert.c,
 * db-ctrl-format.c, fsys-hash.c; src/main/unpack.c pkg_disappear_others.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderInstalledOwnership.hpp"
#include "Cydia/ExtendedState.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/RuntimeState.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
using Code = InstalledOwnershipErrorCode;
bool Fail(InstalledOwnershipError *error, Code code, const std::string &path = {}) {
    if (error) { error->code = code; error->path = path.substr(0, MaximumOwnershipPathBytes); }
    return false;
}
void Clear(InstalledOwnershipError *error) { if (error) *error = InstalledOwnershipError(); }
bool Cancelled(const std::function<bool()> &cancelled, InstalledOwnershipError *error) {
    if (!cancelled || !cancelled()) return false;
    Fail(error, Code::Cancelled); return true;
}
std::string Key(const ExecutionPackage &package) { return package.package + ':' + package.architecture; }
std::string Trim(const std::string &s) {
    const auto a = s.find_first_not_of(" \t\r\n\v\f");
    return a == std::string::npos ? "" : s.substr(a, s.find_last_not_of(" \t\r\n\v\f") - a + 1);
}
bool Path(const std::string &path, bool sentinel) {
    if (path.empty() || path.size() > MaximumOwnershipPathBytes || path.front() != '/') return false;
    for (unsigned char c : path) if (c < 32 || c == 127) return false;
    if (path == "/") return true;
    if (sentinel && path == "/.") return true;
    std::size_t begin = 1;
    while (begin < path.size()) {
        const auto end = path.find('/', begin);
        const auto part = path.substr(begin, end == std::string::npos ? end : end - begin);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) return true;
        begin = end + 1;
    }
    return false;
}
struct Budget {
    std::size_t bytes = 0, paths = 0;
    bool Bytes(std::size_t amount) {
        if (amount > MaximumOwnershipBytes - bytes) return false;
        bytes += amount; return true;
    }
    bool Paths(std::size_t amount) {
        if (amount > MaximumOwnershipPaths - paths) return false;
        paths += amount; return true;
    }
};
class Identity {
    Hashes hash_;
    bool valid_ = true;
public:
    explicit Identity(const std::string &domain) : hash_(Hashes::SHA256SUM) { Add(domain); }
    void Add(const std::string &value) {
        const std::string size = std::to_string(value.size()) + ':';
        valid_ = valid_ && hash_.Add(size.data(), size.size()) && hash_.Add(value.data(), value.size()) && hash_.Add(",", 1);
    }
    std::string Finish() { return valid_ ? hash_.GetHashString(Hashes::SHA256SUM).HashValue() : ""; }
};
bool SameStat(const struct stat &a, const struct stat &b) {
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_mode != b.st_mode || a.st_nlink != b.st_nlink ||
        a.st_uid != b.st_uid || a.st_gid != b.st_gid || a.st_size != b.st_size) return false;
#ifdef __APPLE__
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
bool Regular(const struct stat &s, std::size_t limit) {
    return S_ISREG(s.st_mode) && s.st_uid == 0 && !(s.st_mode & 0022) && s.st_nlink == 1 && s.st_size >= 0 &&
        static_cast<std::uint64_t>(s.st_size) <= limit;
}
bool LocalEvidence(const P::Evidence &file, InstalledOwnershipError *error) {
    // Evidence constructors capture this process's supplementary groups. These
    // are parent-local values, but their serialized count still needs a bound.
    // This capture never creates delegated-source or directory-entry records.
    if (!file.sourceReaderGroups.valid || !file.entries.empty() || !file.sourceDelegation.empty())
        return Fail(error, Code::UnsafeInput, file.path);
    if (file.sourceReaderGroups.values.size() > MaximumOwnershipReaderGroups)
        return Fail(error, Code::LimitExceeded, file.path);
    return true;
}
bool EvidenceBytes(const P::Evidence &file, Budget *budget) {
    // Include a conservative ceiling for stat/scalar netstrings and each
    // decimal gid/netstring, rather than counting only the raw file contents.
    return budget->Bytes(file.path.size()) && budget->Bytes(file.bytes.size()) &&
        budget->Bytes(512 + file.sourceReaderGroups.values.size() * 32);
}
// Use the existing protected admin-chain validator, then a bounded no-follow
// leaf read. Unlike pre-stat followed by a generic read, a growing file cannot
// allocate beyond this file's limit. No lock inode is opened or closed here.
bool Read(const std::string &path, bool optional, std::size_t limit, P::Evidence *out,
    InstalledOwnershipError *error, const std::function<bool()> &cancelled) {
    *out = P::Evidence(); out->path = path; out->adminAccess = true;
    if (!LocalEvidence(*out, error)) return false;
    if (!Path(path, false)) return Fail(error, Code::UnsafeInput, path);
    if (Cancelled(cancelled, error)) return false;
    P::Error ignored; struct stat named{};
    if (lstat(path.c_str(), &named) != 0) {
        if (errno != ENOENT || !optional) return Fail(error, Code::Unavailable, path);
        const auto slash = path.find_last_of('/');
        if (!P::ValidateDpkgAdminPath(slash == 0 ? "/" : path.substr(0, slash), true, &ignored))
            return Fail(error, Code::UnsafeInput, path);
        out->absent = true; return true;
    }
    if (named.st_size < 0 || static_cast<std::uint64_t>(named.st_size) > limit)
        return Fail(error, Code::LimitExceeded, path);
    if (!Regular(named, limit) || !P::ValidateDpkgAdminPath(path, false, &ignored))
        return Fail(error, Code::UnsafeInput, path);
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return Fail(error, Code::Unavailable, path);
    struct Scope { int fd; ~Scope() { close(fd); } } scope{fd};
    struct stat opened{};
    if (fstat(fd, &opened) != 0 || !Regular(opened, limit) || !SameStat(named, opened))
        return Fail(error, Code::StateChanged, path);
    char buffer[16384];
    for (;;) {
        if (Cancelled(cancelled, error)) return false;
        const auto n = read(fd, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return Fail(error, Code::Unavailable, path);
        if (!n) break;
        if (static_cast<std::size_t>(n) > limit - out->bytes.size()) return Fail(error, Code::LimitExceeded, path);
        out->bytes.append(buffer, static_cast<std::size_t>(n));
    }
    struct stat after{}, finalName{};
    if (fstat(fd, &after) != 0 || lstat(path.c_str(), &finalName) != 0 || !SameStat(opened, after) ||
        !SameStat(after, finalName) || static_cast<std::uint64_t>(after.st_size) != out->bytes.size() ||
        !P::ValidateDpkgAdminPath(path, false, &ignored)) return Fail(error, Code::StateChanged, path);
    out->identity = after; return true;
}
bool PhaseMatches(DpkgPackageStatus disk, DpkgPackageStatus query) {
    return disk == query || (disk >= DpkgPackageStatus::TriggersAwaited && query >= DpkgPackageStatus::TriggersAwaited);
}
}
bool ParseInstalledOwnershipList(const std::string &bytes, std::vector<std::string> *paths, InstalledOwnershipError *error) {
    Clear(error); if (!paths) return Fail(error, Code::InvalidInput);
    paths->clear(); std::vector<std::string> result;
    if (bytes.size() > MaximumOwnershipFileBytes) return Fail(error, Code::LimitExceeded);
    std::size_t cursor = 0;
    while (cursor < bytes.size()) {
        const auto end = bytes.find('\n', cursor);
        if (end == std::string::npos) return Fail(error, Code::MalformedList);
        if (end - cursor > MaximumOwnershipPathBytes + 1 || result.size() >= MaximumOwnershipPaths)
            return Fail(error, Code::LimitExceeded);
        std::string path = bytes.substr(cursor, end - cursor); cursor = end + 1;
        if (path.compare(0, 2, "//") == 0) return Fail(error, Code::UnsupportedPath, path);
        // Native fsys_list_parse_buffer strips exactly one trailing slash.
        if (!path.empty() && path.back() == '/') path.pop_back();
        if (path.empty()) return Fail(error, Code::MalformedList);
        if (!Path(path, true)) return Fail(error, Code::UnsupportedPath, path);
        result.push_back(std::move(path));
    }
    *paths = std::move(result); return true;
}
bool ParseInstalledOwnershipDiversions(const std::string &bytes, std::vector<InstalledDiversion> *records,
    InstalledOwnershipError *error) {
    Clear(error); if (!records) return Fail(error, Code::InvalidInput);
    records->clear(); std::vector<InstalledDiversion> result; std::set<std::string> endpoints;
    if (bytes.size() > MaximumOwnershipFileBytes) return Fail(error, Code::LimitExceeded);
    std::size_t cursor = 0;
    const auto line = [&](std::string *value) {
        const auto end = bytes.find('\n', cursor);
        if (end == std::string::npos) return Fail(error, Code::MalformedDiversions);
        // MAXDIVERTFILENAME=1024 and fgets_checked require room for LF + NUL.
        if (end - cursor > 1022) return Fail(error, Code::LimitExceeded);
        *value = bytes.substr(cursor, end - cursor); cursor = end + 1; return true;
    };
    while (cursor < bytes.size()) {
        if (result.size() >= MaximumOwnershipDiversions) return Fail(error, Code::LimitExceeded);
        InstalledDiversion item; std::string owner;
        if (!line(&item.original) || !line(&item.diverted) || !line(&owner)) return false;
        if (!Path(item.original, false) || !Path(item.diverted, false)) return Fail(error, Code::UnsupportedPath);
        if (!endpoints.insert(item.original).second || !endpoints.insert(item.diverted).second)
            return Fail(error, Code::ConflictingDiversions, item.original);
        item.local = owner == ":";
        if (!item.local && !CydiaRuntime::ValidPackageName(owner)) return Fail(error, Code::MalformedDiversions);
        if (!item.local) item.package = owner;
        result.push_back(std::move(item));
    }
    *records = std::move(result); return true;
}
bool CaptureInstalledOwnership(const P::Environment &environment, const DpkgState &state,
    const TriggerCaptureLock &lock, InstalledOwnershipMetadata *metadata, InstalledOwnershipError *error,
    const std::function<bool()> &cancelled, const TriggerStateSnapshot &snapshot) {
    Clear(error); if (!metadata) return Fail(error, Code::InvalidInput);
    *metadata = InstalledOwnershipMetadata();
    if (geteuid() != 0 || !TriggerCaptureLockHeld(environment, lock)) return Fail(error, Code::FrontendLockMissing);
    if (state.packages.size() > MaximumOwnershipPackages) return Fail(error, Code::LimitExceeded);
    if (state.packageStateIdentity.empty() || state.packageStateIdentity.size() > 512) return Fail(error, Code::InvalidInput);
    for (const auto &entry : state.packages) {
        const auto &p = entry.second.package;
        if (entry.first.size() > 512 || p.package.size() > 256 || p.architecture.size() > 128 ||
            p.version.size() > 1024 || p.version.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+:~-") != std::string::npos ||
            entry.second.multiArch.size() > 16) return Fail(error, Code::InvalidInput);
    }
    if (Cancelled(cancelled, error)) return false;
    std::string before, after, ignoredText; P::Error ignored;
    const auto stateIdentity = [&](std::string *value) {
        return snapshot ? snapshot(value, &ignoredText) : P::RuntimeSnapshot(environment, value, &ignored);
    };
    if (!stateIdentity(&before) || before != state.packageStateIdentity) return Fail(error, Code::StateChanged);
    InstalledOwnershipMetadata result; Budget budget;
    const std::string directory = environment.dpkgAdmin + "/info";
    std::map<std::string, P::Evidence> files;
    const auto input = [&](const std::string &path, bool optional, std::size_t limit) -> const P::Evidence * {
        auto found = files.find(path); if (found != files.end()) return &found->second;
        P::Evidence file;
        if (!Read(path, optional, limit, &file, error, cancelled)) return nullptr;
        if (!EvidenceBytes(file, &budget)) { Fail(error, Code::LimitExceeded, path); return nullptr; }
        return &files.emplace(path, std::move(file)).first->second;
    };
    const auto status = input(environment.dpkgAdmin + "/status", false, MaximumOwnershipStatusBytes);
    if (!status) return false;
    const auto format = input(directory + "/format", true, 64);
    if (!format) return false;
    const auto migration = input(directory + "/format-new", true, 64);
    if (!migration) return false;
    if (!migration->absent) return Fail(error, Code::UnsupportedFormat, migration->path);
    const auto version = format->absent ? "0" : Trim(format->bytes);
    if (version != "0" && version != "1") return Fail(error, Code::UnsupportedFormat, format->path);
    result.infoFormat = version == "1" ? 1 : 0;
    P::Evidence info;
    if (!P::CapturePathIdentity(directory, true, false, &info, &ignored, true)) return Fail(error, Code::UnsafeInput, directory);
    if (!LocalEvidence(info, error)) return false;
    if (!EvidenceBytes(info, &budget)) return Fail(error, Code::LimitExceeded);
    files.emplace(directory, info);
    std::map<std::string, TriggerPackageMetadata> controls;
    if (!ParseInstalledTriggerControl(status->bytes, state, &controls, &ignoredText)) return Fail(error, Code::StateChanged, status->path);
    std::set<std::string> selected;
    for (const auto &record : state.packages) {
        if (Cancelled(cancelled, error)) return false;
        if (static_cast<unsigned>(record.second.status) > static_cast<unsigned>(DpkgPackageStatus::Installed) ||
            static_cast<unsigned>(record.second.selection) > static_cast<unsigned>(DpkgSelection::Purge)) return Fail(error, Code::InvalidInput);
        const auto &package = record.second.package; const auto key = Key(package);
        const auto control = controls.find(key);
        if (record.first != key || (control != controls.end() && !PhaseMatches(control->second.diskStatus, record.second.status)))
            return Fail(error, Code::StateChanged);
        if (record.second.status == DpkgPackageStatus::NotInstalled) continue;
        if (control == controls.end() || package.version.empty()) return Fail(error, Code::StateChanged);
        InstalledPackageOwnership item; item.package = package; item.selection = record.second.selection;
        item.status = record.second.status; item.diskStatus = control->second.diskStatus;
        item.reinstallRequired = record.second.reinstallRequired;
        item.configVersion = control->second.configVersion; item.multiArch = control->second.controls.at("multi-arch");
        item.disappearanceEligible = item.status > DpkgPackageStatus::ConfigFiles;
        const auto plain = input(directory + '/' + package.package + ".list", true, MaximumOwnershipFileBytes);
        const auto qualified = input(directory + '/' + key + ".list", true, MaximumOwnershipFileBytes);
        if (!plain || !qualified) return false;
        const bool useArchitecture = result.infoFormat == 1 && item.multiArch == "same";
        const auto chosen = useArchitecture ? qualified : plain, other = useArchitecture ? plain : qualified;
        if (!other->absent || !selected.insert(chosen->path).second) return Fail(error, Code::UnsafeInput, chosen->path);
        item.list = *chosen;
        if (!ParseInstalledOwnershipList(chosen->bytes, &item.paths, error)) return false;
        if (!budget.Paths(item.paths.size())) return Fail(error, Code::LimitExceeded, chosen->path);
        Identity controlHash("CYDIA-INSTALLED-OWNERSHIP-CONTROL-1");
        for (const auto &field : control->second.controls) { controlHash.Add(field.first); controlHash.Add(field.second); }
        item.controlIdentity = controlHash.Finish();
        Identity identity("CYDIA-INSTALLED-OWNERSHIP-PACKAGE-1");
        for (const auto &value : {package.package, package.version, package.architecture, item.configVersion,
            item.multiArch, item.controlIdentity, version, std::to_string(static_cast<unsigned>(item.status)),
            std::to_string(static_cast<unsigned>(item.diskStatus)), std::to_string(static_cast<unsigned>(item.selection))}) identity.Add(value);
        identity.Add(item.reinstallRequired ? "1" : "0");
        identity.Add(P::SerializeSnapshotEvidence(*plain)); identity.Add(P::SerializeSnapshotEvidence(*qualified));
        item.evidenceIdentity = identity.Finish();
        if (item.controlIdentity.size() != 64 || item.evidenceIdentity.size() != 64) return Fail(error, Code::Unavailable);
        result.packages.emplace(key, std::move(item));
    }
    const auto diversions = input(environment.dpkgAdmin + "/diversions", true, MaximumOwnershipFileBytes);
    if (!diversions) return false;
    result.diversions = *diversions;
    if (!ParseInstalledOwnershipDiversions(diversions->bytes, &result.diversionRecords, error)) return false;
    if (!budget.Paths(result.diversionRecords.size() * 2)) return Fail(error, Code::LimitExceeded);
    if (Cancelled(cancelled, error)) return false;
    if (!stateIdentity(&after) || before != after || !TriggerCaptureLockHeld(environment, lock)) return Fail(error, Code::StateChanged);
    // Recapture all leaves, including absent alternate names; the ordinary
    // package token does not include .list/diversions and cannot substitute.
    for (const auto &entry : files) {
        if (Cancelled(cancelled, error)) return false;
        if (entry.second.directory) {
            if (!P::RecheckEvidence({entry.second}, &ignored)) return Fail(error, Code::StateChanged, entry.first);
            continue;
        }
        P::Evidence again;
        const auto limit = entry.first == status->path ? MaximumOwnershipStatusBytes :
            (entry.first == format->path || entry.first == migration->path) ? 64 : MaximumOwnershipFileBytes;
        if (!Read(entry.first, entry.second.absent, limit, &again, error, cancelled)) return false;
        if (P::SerializeSnapshotEvidence(again) != P::SerializeSnapshotEvidence(entry.second)) return Fail(error, Code::StateChanged, entry.first);
    }
    if (Cancelled(cancelled, error)) return false;
    if (!stateIdentity(&after) || before != after || !TriggerCaptureLockHeld(environment, lock)) return Fail(error, Code::StateChanged);
    Identity identity("CYDIA-INSTALLED-OWNERSHIP-1"); identity.Add(after); identity.Add(version);
    for (const auto &entry : files) {
        if (Cancelled(cancelled, error)) return false;
        identity.Add(P::SerializeSnapshotEvidence(entry.second)); result.files.push_back(entry.second);
    }
    for (const auto &entry : result.packages) {
        if (Cancelled(cancelled, error)) return false;
        identity.Add(entry.first); identity.Add(entry.second.evidenceIdentity);
    }
    result.packageStateIdentity = after; result.evidenceIdentity = identity.Finish();
    if (result.evidenceIdentity.size() != 64) return Fail(error, Code::Unavailable);
    result.complete = true; *metadata = std::move(result); Clear(error); return true;
}
}}
