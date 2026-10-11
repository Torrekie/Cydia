/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_ReadOnlySourceAlias_HPP
#define Cydia_ReadOnlySourceAlias_HPP
#include "Cydia/SharedStateFile.hpp"
#include "Cydia/SourceReaderGroups.hpp"
#include <grp.h>
#include <sys/wait.h>

namespace CydiaSources { namespace ReadOnlyAlias {
/* A protected root-owned source alias explicitly delegates repository DATA
 * to an external frontend. Its target may be a user-owned cache. Never use
 * this policy for hooks, tools, trust keys, state writes or edit destinations.
 * Public readability prevents privileged reads of private delegated targets. */
inline bool CallerCanOpen(const std::string &path, const struct stat &expected, uid_t uid, gid_t gid,
                          const ReaderGroups &groups) {
    if (!groups.valid) return false;
    const ReaderGroups current;
    const bool sameGroups(current.valid && current.values == groups.values);
    const bool restoreGroups(getegid() != gid || !sameGroups);
    // Direct UI reads already run as the caller. Fail closed if that process
    // would require a credential change; only the root helper restores groups.
    if (geteuid() != 0 && (geteuid() != uid || restoreGroups)) return false;
    const pid_t child(fork());
    if (child < 0) return false;
    if (child == 0) {
        // Darwin's primary-group changes can rotate supplementary groups.
        // Restore the captured list after setgid and before dropping root.
        if ((getegid() != gid && setgid(gid) != 0) ||
            (restoreGroups && (geteuid() == 0 ? setgroups(groups.values.size(), groups.values.empty() ? NULL : groups.values.data()) != 0 : !sameGroups)) ||
            (geteuid() != uid && setuid(uid) != 0)) _exit(1);
        const int fd(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
        struct stat actual;
        const bool allowed(fd >= 0 && fstat(fd, &actual) == 0 && CydiaRuntime::SharedState::SameStat(expected, actual));
        if (fd >= 0) close(fd);
        _exit(allowed ? 0 : 1);
    }
    int status; pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    return waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
inline bool Read(const std::string &path, std::string *bytes, struct stat *identity, std::string *canonical,
                 uid_t readerUID = getuid(), gid_t readerGID = getgid(), struct stat *delegation = NULL,
                 const ReaderGroups &readerGroups = ReaderGroups()) {
    const int sourceParent(CydiaRuntime::SharedState::OpenParent(path));
    if (sourceParent < 0) return false;
    const std::string leaf(path.substr(path.find_last_of('/') + 1));
    struct stat alias, after;
    bool safe(fstatat(sourceParent, leaf.c_str(), &alias, AT_SYMLINK_NOFOLLOW) == 0 &&
              S_ISLNK(alias.st_mode) && alias.st_uid == 0);
    char *resolved(safe ? realpath(path.c_str(), NULL) : NULL);
    if (resolved == NULL) { close(sourceParent); return false; }
    *canonical = resolved; free(resolved);
    const auto slash(canonical->find_last_of('/'));
    const std::string parent(slash == 0 ? "/" : canonical->substr(0, slash));
    const int targetParent(open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    bool present = false; struct stat expected;
    if (targetParent < 0) { close(sourceParent); return false; }
    safe = fstatat(targetParent, canonical->substr(slash + 1).c_str(), &expected, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISREG(expected.st_mode) && expected.st_nlink == 1 && (expected.st_mode & S_IROTH) != 0 &&
        (expected.st_mode & (S_ISUID | S_ISGID | S_IWOTH)) == 0 &&
        CallerCanOpen(*canonical, expected, readerUID, readerGID, readerGroups) &&
        CydiaRuntime::SharedState::Read(targetParent, canonical->substr(slash + 1), &present, bytes, identity) &&
        present && CydiaRuntime::SharedState::SameStat(expected, *identity);
    close(targetParent);
    // Bind both the declared delegation and its current target to this read.
    resolved = safe ? realpath(path.c_str(), NULL) : NULL;
    safe = safe && resolved != NULL && *canonical == resolved &&
        fstatat(sourceParent, leaf.c_str(), &after, AT_SYMLINK_NOFOLLOW) == 0 &&
        CydiaRuntime::SharedState::SameStat(alias, after) &&
        fstatat(sourceParent, leaf.c_str(), &after, 0) == 0 && CydiaRuntime::SharedState::SameStat(*identity, after);
    if (safe && delegation != NULL) *delegation = alias;
    free(resolved); close(sourceParent); return safe;
}
} }
#endif
