/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RecoveryPrivileged.hpp"
#include <CommonCrypto/CommonDigest.h>
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sstream>
#include <unistd.h>

namespace CydiaRuntime { namespace Recovery {
namespace {
bool Fail(Privileged::Error *error, const char *code, const char *message) {
    if (error != NULL) { error->code = code; error->message = message; } return false;
}
void Put(std::string *bytes, const std::string &value) { *bytes += std::to_string(value.size()) + ':' + value + ','; }
std::string Identity(const CydiaSources::FileIdentity &id) {
    std::ostringstream out;
    out << id.exists << ' ' << id.device << ' ' << id.inode << ' ' << id.size << ' ' << id.links << ' '
        << id.mode << ' ' << id.owner << ' ' << id.group << ' ' << id.modifiedSeconds << ' '
        << id.modifiedNanoseconds << ' ' << id.changedSeconds << ' ' << id.changedNanoseconds;
    return out.str();
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
std::string Digest(const std::string &bytes) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest);
    const char *hex("0123456789abcdef"); std::string result;
    for (unsigned char c : digest) { result += hex[c >> 4]; result += hex[c & 15]; }
    return result;
}
#pragma clang diagnostic pop
class FD {
    int fd_;
  public:
    explicit FD(int fd = -1) : fd_(fd) {}
    ~FD() { if (fd_ >= 0) close(fd_); }
    int get() const { return fd_; }
};
bool SafeDirectory(const struct stat &st, uid_t owner) {
    return S_ISDIR(st.st_mode) && (st.st_uid == 0 || st.st_uid == owner) &&
        ((st.st_mode & (S_IWGRP | S_IWOTH)) == 0 || (st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0));
}
int OpenDirectory(const std::string &path, uid_t owner) {
    if (path.empty() || path[0] != '/') return -1;
    char *resolved(realpath(path.c_str(), NULL));
    if (resolved == NULL) return -1;
    const std::string canonical(resolved); free(resolved);
    struct stat st;
    for (std::size_t end(1);;) {
        const std::string prefix(end == 1 ? "/" : canonical.substr(0, end));
        if (lstat(prefix.c_str(), &st) != 0 || !SafeDirectory(st, owner)) return -1;
        if (end == canonical.size()) break;
        end = canonical.find('/', end + 1);
        if (end == std::string::npos) end = canonical.size();
    }
    const int fd(open(canonical.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (fd >= 0 && (fstat(fd, &st) != 0 || !SafeDirectory(st, owner))) { close(fd); return -1; }
    return fd;
}
bool PendingUpdates(const std::string &admin, uid_t owner) {
    struct stat st;
    if (lstat((admin + "/updates").c_str(), &st) != 0) return errno != ENOENT;
    if (!SafeDirectory(st, owner)) return true;
    const int fd(OpenDirectory(admin + "/updates", owner));
    DIR *directory(fd < 0 ? NULL : fdopendir(fd));
    if (directory == NULL) { if (fd >= 0) close(fd); return true; }
    bool pending(false); errno = 0;
    while (const auto entry = readdir(directory)) {
        const std::string name(entry->d_name);
        if (name != "." && name != "..") { pending = true; break; }
    }
    pending = pending || errno != 0; closedir(directory); return pending;
}
bool Write(int fd, const std::string &bytes) {
    std::size_t offset(0);
    while (offset < bytes.size()) {
        const ssize_t count(write(fd, bytes.data() + offset, bytes.size() - offset));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        offset += count;
    }
    return fsync(fd) == 0;
}
bool NewFile(int directory, const std::string &leaf, const std::string &bytes, mode_t mode, uid_t owner, gid_t group) {
    FD file(openat(directory, leaf.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    return file.get() >= 0 && Write(file.get(), bytes) && fchown(file.get(), owner, group) == 0 &&
        fchmod(file.get(), mode) == 0 && fsync(file.get()) == 0;
}
bool Backup(const std::string &state, const Snapshot &snapshot, std::string *path, Privileged::Error *error, uid_t owner) {
    FD parent(OpenDirectory(state, owner));
    struct stat st;
    if (parent.get() < 0 || fstat(parent.get(), &st) != 0 || st.st_uid != owner || (st.st_mode & (S_IWGRP | S_IWOTH)) != 0)
        return Fail(error, "recovery_backup_unavailable", "Cydia's protected backup directory is unavailable.");
    if (mkdirat(parent.get(), "emergency-recovery", 0700) != 0 && errno != EEXIST)
        return Fail(error, "recovery_backup_failed", "Cannot create the emergency backup directory.");
    FD root(openat(parent.get(), "emergency-recovery", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (root.get() < 0 || fstat(root.get(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != owner || (st.st_mode & 077) != 0)
        return Fail(error, "recovery_backup_unavailable", "The emergency backup directory is not private.");
    std::string canonical;
    char *resolved(realpath(state.c_str(), NULL));
    if (resolved == NULL) return false;
    canonical = resolved; free(resolved);
    std::string pattern(canonical + "/emergency-recovery/transaction.XXXXXX");
    std::vector<char> name(pattern.begin(), pattern.end()); name.push_back(0);
    if (mkdtemp(name.data()) == NULL) return Fail(error, "recovery_backup_failed", "Cannot create a package-specific backup.");
    *path = name.data(); FD backup(OpenDirectory(*path, owner));
    if (backup.get() < 0) return false;
    std::string manifest("CYDIA-EMERGENCY-BACKUP-1\n");
    Put(&manifest, snapshot.review.analysis.package); Put(&manifest, snapshot.review.token);
    Put(&manifest, snapshot.review.analysis.stanza);
    for (const auto &script : snapshot.scripts) {
        Put(&manifest, script.path); Put(&manifest, Identity(script.file.identity));
        if (script.file.identity.exists && !NewFile(backup.get(), script.suffix.substr(1), script.file.bytes, 0600, owner, getegid()))
            return Fail(error, "recovery_backup_failed", "A package script could not be backed up.");
    }
    if (!NewFile(backup.get(), "manifest", manifest, 0600, owner, getegid()) || fsync(backup.get()) != 0 ||
        fsync(root.get()) != 0 || fsync(parent.get()) != 0)
        return Fail(error, "recovery_backup_failed", "The package backup could not be committed.");
    return true;
}
bool Recheck(const Snapshot &snapshot, const Privileged::Environment &environment, uid_t owner) {
    CydiaSources::ProtectedFileSnapshot file;
    if (PendingUpdates(environment.dpkgAdmin, owner) || !CydiaSources::ReadProtectedFile(environment.dpkgAdmin + "/status", &file, owner) ||
        !file.identity.sameVersion(snapshot.status.identity) || file.bytes != snapshot.status.bytes) return false;
    for (const auto &script : snapshot.scripts) {
        if (!CydiaSources::ReadProtectedFile(script.path, &file, owner) ||
            !file.identity.sameVersion(script.file.identity) || file.bytes != script.file.bytes) return false;
    }
    return true;
}
bool Restore(const Snapshot &snapshot, const Privileged::Environment &environment, uid_t owner) {
    FD info(OpenDirectory(environment.dpkgAdmin + "/info", owner));
    if (info.get() < 0) return false;
    bool success(true);
    for (const auto &script : snapshot.scripts) {
        if (!script.file.identity.exists) continue;
        const std::string leaf(script.path.substr(script.path.find_last_of('/') + 1));
        struct stat st;
        if (fstatat(info.get(), leaf.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0) {
            CydiaSources::ProtectedFileSnapshot current;
            if (!CydiaSources::ReadProtectedFile(script.path, &current, owner) || current.bytes != script.file.bytes) success = false;
            continue;
        }
        if (errno != ENOENT || !NewFile(info.get(), leaf, script.file.bytes,
             script.file.identity.mode & 0777, script.file.identity.owner, script.file.identity.group)) success = false;
    }
    return fsync(info.get()) == 0 && success;
}
}
bool Prepare(const Privileged::Environment &environment, const std::string &identity,
             const std::string &nativeArchitecture, Snapshot *snapshot, Privileged::Error *error, uid_t owner) {
    if (snapshot == NULL || !ValidPackageIdentity(identity) || PendingUpdates(environment.dpkgAdmin, owner))
        return Fail(error, "recovery_state_unavailable", "The dpkg state requires ordinary recovery before a targeted emergency action.");
    Snapshot result;
    if (!CydiaSources::ReadProtectedFile(environment.dpkgAdmin + "/status", &result.status, owner) || !result.status.identity.exists)
        return Fail(error, "recovery_state_unavailable", "Cannot read the active protected dpkg status database.");
    result.review.analysis = AnalyzeStatus(result.status.bytes, identity, nativeArchitecture);
    if (result.review.analysis.reason == "unavailable") return Fail(error, "recovery_state_unavailable", "Cannot determine this package's actual dpkg state and dependency impact.");
    std::string bytes;
    for (const auto &value : std::vector<std::string>{environment.dpkgRoot, environment.dpkgAdmin, environment.dpkg,
         nativeArchitecture, result.review.analysis.package, Identity(result.status.identity), result.status.bytes}) Put(&bytes, value);
    for (const char *suffix : {".prerm", ".postrm", ".preinst", ".postinst", ".extrainst_"}) {
        ScriptSnapshot script; script.suffix = suffix;
        script.path = environment.dpkgAdmin + "/info/" + result.review.analysis.package + suffix;
        if (!CydiaSources::ReadProtectedFile(script.path, &script.file, owner))
            return Fail(error, "recovery_script_unavailable", "A package script cannot be safely inspected for backup.");
        if (script.file.identity.exists) result.review.scripts.push_back(script.suffix.substr(1));
        Put(&bytes, script.path); Put(&bytes, Identity(script.file.identity)); Put(&bytes, script.file.bytes);
        result.scripts.push_back(script);
    }
    result.review.token = Digest(bytes);
    if (!Recheck(result, environment, owner)) return Fail(error, "recovery_state_changed", "Package state changed during the recovery review.");
    *snapshot = result; return true;
}
bool Remove(const std::string &privateState, const Privileged::Environment &environment,
            const std::string &identity, const std::string &nativeArchitecture, const std::string &reviewToken,
            const std::function<int(const std::string &)> &executeRemoval,
            RemovalResult *result, Privileged::Error *error, uid_t owner) {
    if (result == NULL || !executeRemoval) return Fail(error, "recovery_invalid_request", "Invalid emergency recovery request.");
    Snapshot snapshot;
    if (!Prepare(environment, identity, nativeArchitecture, &snapshot, error, owner)) return false;
    if (!snapshot.review.analysis.canEmergencyRemove) return Fail(error, "recovery_protected", "Emergency removal would affect protected packages or installed dependents.");
    if (reviewToken != snapshot.review.token) return Fail(error, "recovery_state_changed", "The package changed after confirmation. Review it again.");
    if (!Backup(privateState, snapshot, &result->backupDirectory, error, owner)) return false;
    if (!Recheck(snapshot, environment, owner)) return Fail(error, "recovery_state_changed", "The package changed before script removal.");
    FD info(OpenDirectory(environment.dpkgAdmin + "/info", owner));
    if (info.get() < 0) return Fail(error, "recovery_script_unavailable", "Cannot safely open the selected package's script directory.");
    for (const auto &script : snapshot.scripts) {
        if (!script.file.identity.exists) continue;
        const std::string leaf(script.path.substr(script.path.find_last_of('/') + 1));
        if (unlinkat(info.get(), leaf.c_str(), 0) != 0) {
            result->scriptsRestored = Restore(snapshot, environment, owner);
            return Fail(error, "recovery_remove_failed", "A package script could not be cleared; the backup has been retained.");
        }
    }
    if (fsync(info.get()) != 0) {
        result->scriptsRestored = Restore(snapshot, environment, owner);
        return Fail(error, "recovery_remove_failed", "Script removal could not be committed; the backup has been retained.");
    }
    result->exitCode = executeRemoval(snapshot.review.analysis.package);
    if (result->exitCode != 0) {
        result->scriptsRestored = Restore(snapshot, environment, owner);
        return Fail(error, "recovery_remove_failed", "dpkg could not remove the package. Original scripts were restored where possible; the backup has been retained.");
    }
    return true;
}
} }
