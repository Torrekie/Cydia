/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/LegacyCydiaSourceAlias.hpp"
#include "Cydia/PackageDatabasePaths.hpp"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace CydiaRuntime {
namespace {
class FD {
    int value_;
  public:
    explicit FD(int value) : value_(value) {}
    ~FD() { if (value_ >= 0) close(value_); }
    int get() const { return value_; }
};
const std::size_t Limit(4 * 1024 * 1024);
std::string Parent(const std::string &path) { const auto slash(path.rfind('/')); return slash == 0 ? "/" : path.substr(0, slash); }
std::string Leaf(const std::string &path) { return path.substr(path.rfind('/') + 1); }
std::string Normalize(const std::string &path) {
    if (path.empty() || path[0] != '/' || path.size() > 4096 || path.find('\0') != std::string::npos) return {};
    std::vector<std::string> parts;
    for (std::size_t begin = 1; begin < path.size();) {
        const auto end(path.find('/', begin));
        const auto part(path.substr(begin, end - begin));
        for (unsigned char c : part) if (c < 32 || c == 127) return {};
        if (part == "..") { if (parts.empty()) return {}; parts.pop_back(); }
        else if (!part.empty() && part != ".") parts.push_back(part);
        if (end == std::string::npos) break;
        begin = end + 1;
    }
    std::string result;
    for (const auto &part : parts) result += '/' + part;
    return result.empty() ? "/" : result;
}
bool Stable(const struct stat &a, const struct stat &b) {
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_size != b.st_size || a.st_nlink != b.st_nlink ||
        a.st_uid != b.st_uid || a.st_gid != b.st_gid || a.st_mode != b.st_mode) return false;
#ifdef __APPLE__
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
bool Directory(const struct stat &st, uid_t administrator, uid_t owner, bool final) {
    return S_ISDIR(st.st_mode) && (st.st_uid == 0 || st.st_uid == administrator || st.st_uid == owner) &&
        ((st.st_mode & 0022) == 0 || (!final && st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0));
}
bool AliasChain(const std::string &path, uid_t administrator, uid_t owner,
                const std::string &noAliasBelow, unsigned depth = 0) {
    if (depth > 40 || Normalize(path) != path) return false;
    for (std::size_t index = 1; index <= path.size(); ++index) {
        if (index != path.size() && path[index] != '/') continue;
        const auto part(path.substr(0, index)); struct stat st;
        if (lstat(part.c_str(), &st) != 0) return false;
        if (!S_ISLNK(st.st_mode)) { if (!Directory(st, administrator, owner, index == path.size())) return false; continue; }
        if ((st.st_uid != 0 && st.st_uid != administrator) || (!noAliasBelow.empty() &&
            part.compare(0, noAliasBelow.size() + 1, noAliasBelow + '/') == 0)) return false;
        char bytes[4097]; const auto size(readlink(part.c_str(), bytes, sizeof(bytes) - 1));
        if (size <= 0 || size == static_cast<ssize_t>(sizeof(bytes) - 1)) return false;
        const std::string link(bytes, size);
        const auto destination(Normalize(link[0] == '/' ? link : Parent(part) + '/' + link));
        if (destination.empty() || !AliasChain(destination, administrator, owner, {}, depth + 1)) return false;
    }
    return true;
}
int OpenDirectory(const std::string &path, uid_t administrator, uid_t owner,
                  const std::string &noAliasBelow, std::string *canonical = NULL) {
    if (!AliasChain(path, administrator, owner, noAliasBelow)) { errno = EACCES; return -1; }
    char *resolved(realpath(path.c_str(), NULL)); if (resolved == NULL) return -1;
    const std::string value(resolved); free(resolved);
    int parent(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (parent < 0) return -1;
    for (std::size_t begin = 1; begin < value.size();) {
        const auto end(value.find('/', begin)); const auto part(value.substr(begin, end - begin));
        const int next(openat(parent, part.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
        close(parent); parent = next; struct stat st;
        if (parent < 0) return -1;
        if (fstat(parent, &st) != 0 || !Directory(st, administrator, owner, end == std::string::npos)) {
            close(parent); errno = EACCES; return -1;
        }
        if (end == std::string::npos) break;
        begin = end + 1;
    }
    if (canonical != NULL) *canonical = value;
    return parent;
}
bool ReadFile(int parent, const std::string &leaf, uid_t owner, std::string *bytes, struct stat *identity) {
    const FD input(openat(parent, leaf.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    if (input.get() < 0) return false;
    if (fstat(input.get(), identity) != 0) return false;
    if (!S_ISREG(identity->st_mode) || identity->st_uid != owner || identity->st_nlink != 1 ||
        (identity->st_mode & (0022 | S_ISUID | S_ISGID)) != 0 || identity->st_size < 0 ||
        static_cast<unsigned long long>(identity->st_size) > Limit) { errno = EACCES; return false; }
    bytes->clear(); char buffer[16384];
    for (;;) {
        const auto count(read(input.get(), buffer, sizeof(buffer)));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return false;
        if (count == 0) break;
        if (bytes->size() + static_cast<std::size_t>(count) > Limit) { errno = EFBIG; return false; }
        bytes->append(buffer, count);
    }
    struct stat after, named;
    if (fstat(input.get(), &after) != 0 || fstatat(parent, leaf.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0) return false;
    if (!Stable(*identity, after) || !Stable(*identity, named) || bytes->size() != static_cast<std::size_t>(identity->st_size)) {
        errno = ESTALE; return false;
    }
    return true;
}
bool IsDiverted(const std::string &admin, const std::string &source, const std::string &canonicalSource,
                uid_t administrator, bool *diverted) {
    *diverted = false;
    const FD parent(OpenDirectory(admin, administrator, administrator, {}));
    if (parent.get() < 0) return false;
    struct stat st;
    if (fstatat(parent.get(), "diversions", &st, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT;
    std::string bytes;
    if (!ReadFile(parent.get(), "diversions", administrator, &bytes, &st)) return false;
    std::vector<std::string> lines;
    for (std::size_t begin = 0; begin < bytes.size();) {
        const auto end(bytes.find('\n', begin));
        if (end == std::string::npos || end == begin) { errno = EINVAL; return false; }
        lines.push_back(bytes.substr(begin, end - begin)); begin = end + 1;
    }
    if (lines.size() % 3 != 0) { errno = EINVAL; return false; }
    for (std::size_t index = 0; index < lines.size(); index += 3)
        if (Normalize(lines[index]) == source || Normalize(lines[index]) == canonicalSource ||
            Normalize(lines[index + 1]) == source || Normalize(lines[index + 1]) == canonicalSource) {
            *diverted = true; break;
        }
    return true;
}
bool ForeignOwner(const std::string &admin, const std::vector<std::string> &paths,
                  uid_t administrator, bool *owned) {
    *owned = false;
    const int parent(OpenDirectory(admin + "/info", administrator, administrator, {}));
    if (parent < 0) return false;
    DIR *directory(fdopendir(parent));
    if (directory == NULL) { close(parent); return false; }
    bool success(true); unsigned count(0); std::size_t total(0); errno = 0;
    while (struct dirent *entry = readdir(directory)) {
        const std::string name(entry->d_name);
        if (name.size() <= 5 || name.compare(name.size() - 5, 5, ".list") != 0 || name == "cydia.list" ||
            name.compare(0, 6, "cydia:") == 0) continue;
        if (++count > 4096) { errno = EFBIG; success = false; break; }
        std::string bytes; struct stat identity;
        if (!ReadFile(parent, name, administrator, &bytes, &identity)) { success = false; break; }
        total += bytes.size();
        if (total > 64 * 1024 * 1024) { errno = EFBIG; success = false; break; }
        for (std::size_t begin = 0; begin < bytes.size();) {
            const auto end(bytes.find('\n', begin));
            const auto line(bytes.substr(begin, end - begin));
            const auto path(Normalize(!line.empty() && line[0] == '/' ? line : '/' + line));
            for (const auto &candidate : paths) if (path == candidate) { *owned = true; break; }
            if (*owned || end == std::string::npos) break;
            begin = end + 1;
        }
        if (*owned) break;
        errno = 0;
    }
    if (success && errno != 0) success = false;
    const int error(errno); closedir(directory); errno = error;
    return success;
}
}

LegacyCydiaSourceAliasResult MaterializeLegacyCydiaSourceAliasAt(
    const std::string &source, const std::string &mobileHome, uid_t mobileOwner,
    gid_t mobileGroup, const std::string &adminDirectory, uid_t administrator) {
    (void) mobileGroup; // Cache metadata remains unchanged; the new shared file belongs to the administrator.
    typedef LegacyCydiaSourceAliasResult Result;
    if (Normalize(source) != source || Leaf(source) != "cydia.list" || Normalize(mobileHome) != mobileHome ||
        Normalize(adminDirectory) != adminDirectory) { errno = EINVAL; return Result::Refused; }
    struct stat initial;
    if (lstat(source.c_str(), &initial) != 0) return errno == ENOENT ? Result::Unchanged : Result::Refused;
    if (!S_ISLNK(initial.st_mode)) return Result::Unchanged;
    char linkBytes[4097]; const auto count(readlink(source.c_str(), linkBytes, sizeof(linkBytes) - 1));
    if (count <= 0 || count == static_cast<ssize_t>(sizeof(linkBytes) - 1)) { errno = EINVAL; return Result::Refused; }
    const std::string link(linkBytes, count);
    const auto destination(Normalize(link[0] == '/' ? link : Parent(source) + '/' + link));
    const std::string cache(mobileHome + "/Library/Caches/com.saurik.Cydia");
    char *canonicalCache(realpath(cache.c_str(), NULL));
    const std::string canonicalTarget(canonicalCache == NULL ? "" : std::string(canonicalCache) + "/sources.list");
    free(canonicalCache);
    if (destination != cache + "/sources.list" && (canonicalTarget.empty() || destination != canonicalTarget)) return Result::Unchanged;
    if (initial.st_uid != administrator) { errno = EACCES; return Result::Refused; }

    std::string canonicalParts;
    const FD parts(OpenDirectory(Parent(source), administrator, administrator, {}, &canonicalParts));
    const FD cacheParent(OpenDirectory(cache, administrator, mobileOwner, mobileHome));
    if (parts.get() < 0 || cacheParent.get() < 0) return Result::Refused;
    const std::vector<std::string> ownershipPaths = {source, canonicalParts + "/cydia.list", cache + "/sources.list", canonicalTarget};
    bool diverted, cacheDiverted, foreignOwned;
    if (!IsDiverted(adminDirectory, source, canonicalParts + "/cydia.list", administrator, &diverted)) return Result::Refused;
    if (!IsDiverted(adminDirectory, cache + "/sources.list", canonicalTarget, administrator, &cacheDiverted)) return Result::Refused;
    if (!ForeignOwner(adminDirectory, ownershipPaths, administrator, &foreignOwned)) return Result::Refused;
    if (diverted || cacheDiverted || foreignOwned) return Result::Unchanged;
    struct stat sourceIdentity;
    if (fstatat(parts.get(), "cydia.list", &sourceIdentity, AT_SYMLINK_NOFOLLOW) != 0 || !Stable(initial, sourceIdentity)) {
        errno = ESTALE; return Result::Refused;
    }
    struct stat cacheIdentity; std::string bytes;
    if (!ReadFile(cacheParent.get(), "sources.list", mobileOwner, &bytes, &cacheIdentity)) return Result::Refused;

    std::string temporary; int output(-1);
    for (unsigned attempt = 0; attempt < 128; ++attempt) {
        temporary = ".cydia-source-alias." + std::to_string(getpid()) + '.' + std::to_string(attempt);
        output = openat(parts.get(), temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (output >= 0 || errno != EEXIST) break;
    }
    if (output < 0) return Result::Refused;
    bool success(true);
    for (std::size_t offset = 0; success && offset < bytes.size();) {
        const auto written(write(output, bytes.data() + offset, bytes.size() - offset));
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) success = false;
        else offset += static_cast<std::size_t>(written);
    }
    success = success && fchown(output, administrator, administrator == 0 ? 0 : getgid()) == 0 &&
        fchmod(output, 0644) == 0 && fsync(output) == 0;
    close(output);
    struct stat latestSource, latestCache; std::string latestBytes;
    if (success) {
        const FD freshParts(OpenDirectory(Parent(source), administrator, administrator, {}));
        const FD freshCache(OpenDirectory(cache, administrator, mobileOwner, mobileHome));
        struct stat originalParts, currentParts, originalCache, currentCache;
        success = freshParts.get() >= 0 && freshCache.get() >= 0 &&
            fstat(parts.get(), &originalParts) == 0 && fstat(freshParts.get(), &currentParts) == 0 &&
            fstat(cacheParent.get(), &originalCache) == 0 && fstat(freshCache.get(), &currentCache) == 0 &&
            originalParts.st_dev == currentParts.st_dev && originalParts.st_ino == currentParts.st_ino &&
            originalCache.st_dev == currentCache.st_dev && originalCache.st_ino == currentCache.st_ino &&
            IsDiverted(adminDirectory, source, canonicalParts + "/cydia.list", administrator, &diverted) && !diverted &&
            IsDiverted(adminDirectory, cache + "/sources.list", canonicalTarget, administrator, &cacheDiverted) && !cacheDiverted &&
            ForeignOwner(adminDirectory, ownershipPaths, administrator, &foreignOwned) && !foreignOwned;
        success = success && fstatat(parts.get(), "cydia.list", &latestSource, AT_SYMLINK_NOFOLLOW) == 0 && Stable(sourceIdentity, latestSource) &&
            ReadFile(cacheParent.get(), "sources.list", mobileOwner, &latestBytes, &latestCache) &&
            Stable(cacheIdentity, latestCache) && bytes == latestBytes;
        if (!success) errno = ESTALE;
    }
    if (success) success = renameat(parts.get(), temporary.c_str(), parts.get(), "cydia.list") == 0;
    const int error(errno);
    if (!success) { unlinkat(parts.get(), temporary.c_str(), 0); errno = error; return Result::Refused; }
    // The cache is deliberately retained, including after a late durability error.
    if (fsync(parts.get()) != 0 && errno != EINVAL) return Result::Refused;
    return Result::Materialized;
}

LegacyCydiaSourceAliasResult MaterializeLegacyCydiaSourceAlias(
    const PackageDatabasePaths &paths, const std::string &mobileHome,
    uid_t mobileOwner, gid_t mobileGroup, const std::string &adminDirectory) {
    if (paths.layout() != PackageDatabaseLayout::Rootful) return LegacyCydiaSourceAliasResult::Unchanged;
    return MaterializeLegacyCydiaSourceAliasAt(paths.LegacyCydiaSourcesListPath(), mobileHome,
        mobileOwner, mobileGroup, adminDirectory, 0);
}
}
