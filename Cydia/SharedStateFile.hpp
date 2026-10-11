/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SharedStateFile_HPP
#define Cydia_SharedStateFile_HPP
#include <cerrno>
#include <cstdlib>
#include <cstdint>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include "Cydia/DpkgAdminAccess.hpp"

namespace CydiaRuntime { namespace SharedState {
/* Data-only APT/dpkg inputs may belong to another frontend's user. This
 * boundary never authorizes configuration hooks, tools, keys or destinations.
 * The caller independently resolves the exact supported state file. */
inline bool SameStat(const struct stat &a, const struct stat &b) {
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_size != b.st_size ||
        a.st_mode != b.st_mode || a.st_uid != b.st_uid || a.st_gid != b.st_gid || a.st_nlink != b.st_nlink) return false;
#ifdef __APPLE__
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
inline bool Directory(const struct stat &st, bool final, const std::string &path = {}, bool adminAccess = false) {
    return S_ISDIR(st.st_mode) && st.st_uid == 0 &&
        ((st.st_mode & 0022) == 0 || (!final && ((st.st_mode & S_ISVTX) != 0 ||
         (adminAccess && AdminAccess::Ancestor(path, st)))));
}
inline bool AliasChain(const std::string &path, bool final = true, unsigned depth = 0, bool adminAccess = false) {
    if (depth > 40 || path.empty() || path[0] != '/' || path.size() > 4096) return false;
    for (std::size_t index = 1; index <= path.size(); ++index) {
        if (index != path.size() && path[index] != '/') continue;
        const std::string part(path.substr(0, index));
        struct stat st;
        if (lstat(part.c_str(), &st) != 0) return false;
        const bool last(final && index == path.size());
        if (!S_ISLNK(st.st_mode)) { if (!Directory(st, last, part, adminAccess)) return false; continue; }
        if (st.st_uid != 0) return false;
        char target[4097];
        const ssize_t size(readlink(part.c_str(), target, sizeof(target) - 1));
        if (size <= 0 || size == static_cast<ssize_t>(sizeof(target) - 1)) return false;
        const std::string value(target, size);
        const auto slash(part.find_last_of('/'));
        const std::string destination(value[0] == '/' ? value : part.substr(0, slash + 1) + value);
        if (!AliasChain(destination, last, depth + 1, adminAccess)) return false;
    }
    return true;
}
inline int OpenParent(const std::string &path, bool permitAdminAccess = false) {
    const auto slash(path.find_last_of('/'));
    const std::string leaf(slash == std::string::npos ? "" : path.substr(slash + 1));
    if (path.empty() || path[0] != '/' || path.find('\0') != std::string::npos ||
        leaf.empty() || leaf == "." || leaf == "..") { errno = EINVAL; return -1; }
    const std::string lexical(slash == 0 ? "/" : path.substr(0, slash));
    const bool adminAccess(permitAdminAccess && AdminAccess::Matches(lexical));
    if (!AliasChain(lexical, true, 0, adminAccess)) { errno = EACCES; return -1; }
    char *resolved(realpath(lexical.c_str(), NULL));
    if (resolved == NULL) return -1;
    const std::string canonical(resolved); free(resolved);
    int parent(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    struct stat st;
    if (parent < 0) return -1;
    if (fstat(parent, &st) != 0 || !Directory(st, canonical == "/")) { close(parent); errno = EACCES; return -1; }
    for (std::size_t start = 1; start < canonical.size();) {
        const auto end(canonical.find('/', start));
        const std::string component(canonical.substr(start, end - start));
        const int next(openat(parent, component.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
        close(parent); parent = next;
        if (parent < 0) return -1;
        if (fstat(parent, &st) != 0 || !Directory(st, end == std::string::npos,
                                                canonical.substr(0, end), adminAccess)) {
            close(parent); errno = EACCES; return -1;
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return parent;
}
inline bool Read(int parent, const std::string &leaf, bool *present, std::string *bytes, struct stat *identity) {
    *present = false; bytes->clear(); *identity = {};
    const int fd(openat(parent, leaf.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    if (fd < 0) {
        struct stat entry;
        return errno == ENOENT && fstatat(parent, leaf.c_str(), &entry, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
    }
    bool safe(fstat(fd, identity) == 0 && S_ISREG(identity->st_mode) && identity->st_nlink == 1 &&
        (identity->st_mode & (S_ISUID | S_ISGID | S_IWOTH)) == 0 && identity->st_size >= 0 &&
        static_cast<std::uint64_t>(identity->st_size) <= 8 * 1024 * 1024);
    char buffer[16384];
    while (safe) {
        const ssize_t count(read(fd, buffer, sizeof(buffer)));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || bytes->size() + (count > 0 ? count : 0) > 8 * 1024 * 1024) { safe = false; break; }
        if (count == 0) break;
        bytes->append(buffer, count);
    }
    struct stat after, entry;
    safe = safe && fstat(fd, &after) == 0 && SameStat(*identity, after) &&
        fstatat(parent, leaf.c_str(), &entry, AT_SYMLINK_NOFOLLOW) == 0 && SameStat(*identity, entry);
    close(fd);
    if (!safe) { errno = EACCES; return false; }
    *present = true; return true;
}
} }
#endif
