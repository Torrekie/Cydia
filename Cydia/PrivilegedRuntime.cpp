/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PrivilegedRuntime.hpp"
#include "Cydia/SharedStateFile.hpp"
#include "Cydia/ReadOnlySourceAlias.hpp"
#include "Cydia/DpkgAdminAccess.hpp"
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <limits>
#include <sstream>
#include <unistd.h>

namespace CydiaRuntime {
namespace Privileged {
namespace {
const std::size_t maximumRequest = 8 * 1024 * 1024;
const char requestHeader[] = "CYDIA-PRIVILEGED-1\n";
const char overridesHeader[] = "CYDIA-EXECUTABLES-1\n";

bool Fail(Error *error, const char *code, const std::string &message) {
    if (error != NULL) { error->code = code; error->message = message; }
    return false;
}

bool ReadBytes(int fd, std::string *bytes, Error *error) {
    bytes->clear();
    char buffer[16384];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return Fail(error, "read_failed", std::strerror(errno));
        if (count == 0) return true;
        if (bytes->size() + static_cast<std::size_t>(count) > maximumRequest)
            return Fail(error, "request_too_large", "Privileged input exceeds its size limit.");
        bytes->append(buffer, count);
    }
}

bool WriteBytes(int fd, const std::string &bytes, Error *error) {
    std::size_t offset = 0;
    while (offset != bytes.size()) {
        ssize_t count = write(fd, bytes.data() + offset, bytes.size() - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return Fail(error, "write_failed", std::strerror(errno));
        offset += count;
    }
    return true;
}

bool ParseOne(const std::string &bytes, std::size_t *offset, std::string *value, Error *error) {
    const std::size_t start = *offset;
    std::size_t length = 0;
    while (*offset < bytes.size() && bytes[*offset] >= '0' && bytes[*offset] <= '9') {
        const unsigned digit = bytes[(*offset)++] - '0';
        if (length > (maximumRequest - digit) / 10)
            return Fail(error, "invalid_request", "Invalid netstring length.");
        length = length * 10 + digit;
    }
    if (*offset == start || (bytes[start] == '0' && *offset != start + 1) ||
        *offset >= bytes.size() || bytes[(*offset)++] != ':' ||
        length > bytes.size() - *offset)
        return Fail(error, "invalid_request", "Invalid netstring.");
    value->assign(bytes, *offset, length);
    *offset += length;
    if (*offset >= bytes.size() || bytes[(*offset)++] != ',')
        return Fail(error, "invalid_request", "Missing netstring terminator.");
    return true;
}

bool SafeString(const std::string &value) {
    return value.find('\0') == std::string::npos &&
           value.find('\n') == std::string::npos && value.find('\r') == std::string::npos;
}

std::string Parent(const std::string &path) {
    const std::size_t slash = path.find_last_of('/');
    return slash == 0 ? "/" : path.substr(0, slash);
}

bool Protected(const struct stat &identity) {
    return identity.st_uid == 0 && (identity.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

bool CheckChain(const std::string &path, Error *error, unsigned depth = 0, bool adminAccess = false, bool final = true) {
    if (depth > 40) return Fail(error, "unsafe_path", "Too many privileged path aliases.");
    std::string part;
    for (std::size_t index = 1; index <= path.size(); ++index) {
        if (index != path.size() && path[index] != '/') continue;
        part = path.substr(0, index);
        if (part.empty()) part = "/";
        struct stat identity;
        if (lstat(part.c_str(), &identity) != 0)
            return Fail(error, "unsafe_path", "Cannot inspect a privileged path.");
        if (S_ISLNK(identity.st_mode)) {
            if (identity.st_uid != 0)
                return Fail(error, "unsafe_path", "A privileged path uses a non-root-owned alias.");
            std::vector<char> target(4097);
            const ssize_t size = readlink(part.c_str(), target.data(), target.size() - 1);
            if (size <= 0 || static_cast<std::size_t>(size) == target.size() - 1)
                return Fail(error, "unsafe_path", "Cannot inspect a privileged alias target.");
            const std::string value(target.data(), size);
            const std::string destination = value[0] == '/' ? value : Parent(part) + "/" + value;
            if (!CheckChain(destination, error, depth + 1, adminAccess, final && index == path.size())) return false;
        } else if (!Protected(identity) && !(adminAccess && (!final || index != path.size()) &&
                   S_ISDIR(identity.st_mode) && AdminAccess::Ancestor(part, identity))) {
            return Fail(error, "unsafe_path", "A privileged path is writable by a non-root owner: " + part);
        }
    }
    return true;
}

bool SameIdentity(const struct stat &a, const struct stat &b) {
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_mode != b.st_mode ||
        a.st_uid != b.st_uid || a.st_gid != b.st_gid || a.st_size != b.st_size)
        return false;
#ifdef __APPLE__
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
        a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
        a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}

bool AllowedPurpose(const std::string &purpose) {
    const char *names[] = {"dpkg", "dpkg-query", "dpkg-deb", "uicache", "apt-key", "gpgv", "gpg"};
    for (const char *name : names) if (purpose == name) return true;
    return false;
}
} // namespace

std::string SerializeFields(const std::vector<std::string> &fields) {
    std::string bytes;
    for (const std::string &field : fields)
        bytes += std::to_string(field.size()) + ':' + field + ',';
    return bytes;
}

bool ParseFields(const std::string &bytes, std::size_t count,
                 std::vector<std::string> *fields, Error *error) {
    if (fields == NULL || bytes.size() > maximumRequest)
        return Fail(error, "invalid_request", "Invalid privileged request.");
    fields->clear();
    std::size_t offset = 0;
    for (std::size_t index = 0; index != count; ++index) {
        std::string field;
        if (!ParseOne(bytes, &offset, &field, error)) return false;
        fields->push_back(field);
    }
    if (offset != bytes.size())
        return Fail(error, "invalid_request", "Unexpected trailing privileged input.");
    return true;
}

std::string SerializeRequest(const Request &request) {
    const ExpectedEnvironment &e = request.expected;
    return std::string(requestHeader) + SerializeFields({e.aptConfigOverride, e.dpkgRoot,
        e.dpkgAdmin, e.dpkg, e.dpkgQuery, e.dpkgDeb, e.sourceList, e.sourceParts, request.payload});
}

bool ParseRequest(const std::string &bytes, Request *request, Error *error) {
    if (request == NULL || bytes.size() > maximumRequest ||
        bytes.compare(0, sizeof(requestHeader) - 1, requestHeader) != 0)
        return Fail(error, "invalid_request", "Unsupported privileged request.");
    std::vector<std::string> fields;
    if (!ParseFields(bytes.substr(sizeof(requestHeader) - 1), 9, &fields, error)) return false;
    for (std::size_t index = 0; index != 8; ++index)
        if (!SafeString(fields[index])) return Fail(error, "invalid_request", "Invalid descriptor string.");
    request->expected = {fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7]};
    request->payload = fields[8];
    return true;
}

bool ReadRequest(int fd, Request *request, Error *error) {
    std::string bytes;
    return ReadBytes(fd, &bytes, error) && ParseRequest(bytes, request, error);
}

static bool ValidatePath(const std::string &path, bool directory,
                         bool executable, Error *error, bool adminAccess) {
    if (path.empty() || path[0] != '/' || !SafeString(path))
        return Fail(error, "unsafe_path", "Privileged paths must be absolute.");
    char *resolved = realpath(path.c_str(), NULL);
    if (resolved == NULL) return Fail(error, "unsafe_path", "A privileged path is unavailable.");
    const std::string canonical(resolved);
    std::free(resolved);
    adminAccess = adminAccess && AdminAccess::Matches(canonical);
    if (!CheckChain(path, error, 0, adminAccess) || !CheckChain(canonical, error, 0, adminAccess)) return false;
    struct stat identity;
    if (stat(path.c_str(), &identity) != 0 || !Protected(identity) ||
        (directory ? !S_ISDIR(identity.st_mode) : !S_ISREG(identity.st_mode)) ||
        (executable && (identity.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0))
        return Fail(error, "unsafe_path", "A privileged path has unsafe ownership, type or permissions.");
    return true;
}

bool ValidateRootOwnedPath(const std::string &path, bool directory, bool executable, Error *error) {
    return ValidatePath(path, directory, executable, error, false);
}
bool ValidateDpkgAdminPath(const std::string &path, bool directory, Error *error) {
    return ValidatePath(path, directory, false, error, true);
}
static bool Capture(const std::string &path, bool directory, bool allowAbsent,
                    Evidence *evidence, Error *error, bool adminAccess) {
    if (evidence == NULL) return false;
    *evidence = Evidence();
    evidence->path = path; evidence->directory = directory; evidence->adminAccess = adminAccess;
    struct stat identity;
    if (lstat(path.c_str(), &identity) != 0) {
        if (errno != ENOENT || !allowAbsent ||
            !ValidatePath(Parent(path), true, false, error, adminAccess))
            return Fail(error, "unsafe_path", "A privileged input is unavailable.");
        evidence->absent = true;
        return true;
    }
    if (!ValidatePath(path, directory, false, error, adminAccess)) return false;
    if (directory) {
        if (stat(path.c_str(), &evidence->identity) != 0) return false;
        DIR *stream = opendir(path.c_str());
        if (stream == NULL) return Fail(error, "read_failed", std::strerror(errno));
        errno = 0;
        while (struct dirent *entry = readdir(stream)) {
            if (std::strcmp(entry->d_name, ".") != 0 && std::strcmp(entry->d_name, "..") != 0)
                evidence->entries.push_back(entry->d_name);
        }
        const int saved = errno;
        closedir(stream);
        if (saved != 0) return Fail(error, "read_failed", std::strerror(saved));
        std::sort(evidence->entries.begin(), evidence->entries.end());
        return true;
    }
    /* The root-owned alias and its canonical target were both checked. */
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return Fail(error, "read_failed", std::strerror(errno));
    const bool success = fstat(fd, &evidence->identity) == 0 && Protected(evidence->identity) &&
        S_ISREG(evidence->identity.st_mode) && ReadBytes(fd, &evidence->bytes, error);
    const int saved = errno;
    close(fd);
    if (!success) return Fail(error, "read_failed", std::strerror(saved));
    return true;
}

bool CaptureEvidence(const std::string &path, bool directory, bool allowAbsent, Evidence *evidence, Error *error) {
    return Capture(path, directory, allowAbsent, evidence, error, false);
}
bool CaptureAdminEvidence(const std::string &path, bool directory, bool allowAbsent, Evidence *evidence, Error *error) {
    return Capture(path, directory, allowAbsent, evidence, error, true);
}

bool CaptureSharedStateEvidence(const std::string &path, bool directory, bool allowAbsent,
                                Evidence *evidence, Error *error) {
    if (evidence == NULL || directory) return false;
    *evidence = Evidence(); evidence->path = path; evidence->sharedState = true;
    const int parent(SharedState::OpenParent(path, true));
    if (parent < 0) return Fail(error, "unsafe_path", "Shared package state requires a protected parent directory.");
    bool present;
    const bool safe(SharedState::Read(parent, path.substr(path.find_last_of('/') + 1), &present,
                                    &evidence->bytes, &evidence->identity));
    close(parent);
    if (!safe || (!present && !allowAbsent))
        return Fail(error, "unsafe_path", "Shared package state has an unsafe or unavailable file.");
    evidence->absent = !present; return true;
}

bool RecheckEvidence(const std::vector<Evidence> &evidence, Error *error) {
    for (const Evidence &before : evidence) {
        Evidence now;
        if (before.identityOnly) {
            if (!CapturePathIdentity(before.path, before.directory, !before.directory, &now, error, before.adminAccess)) return false;
            const struct stat &a = before.identity, &b = now.identity;
            const bool stable = a.st_dev == b.st_dev && a.st_ino == b.st_ino &&
                a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_gid == b.st_gid;
            if (!stable || (!before.directory && !SameIdentity(a, b)))
                return Fail(error, "stale_environment", "Privileged executable or directory changed; review it again.");
            continue;
        }
        if (before.sourceInput) {
            if (!CaptureSourceEvidenceForReader(before.path, before.directory, before.absent, &now, error,
                                                before.sourceReaderUID, before.sourceReaderGID, before.sourceReaderGroups)) return false;
        } else if (!(before.sharedState ? CaptureSharedStateEvidence : before.adminAccess ? CaptureAdminEvidence : CaptureEvidence)(before.path, before.directory, before.absent, &now, error)) return false;
        if (before.absent != now.absent ||
            (!before.absent && (!SameIdentity(before.identity, now.identity) ||
             before.bytes != now.bytes || before.entries != now.entries || before.sourceDelegation != now.sourceDelegation)))
            return Fail(error, "stale_environment", "Privileged configuration changed; review it again.");
    }
    return true;
}

bool CaptureSourceEvidence(const std::string &path, bool directory, bool allowAbsent,
                           Evidence *evidence, Error *error) {
    return CaptureSourceEvidenceForReader(path, directory, allowAbsent, evidence, error, getuid(), getgid());
}
bool CaptureSourceEvidenceForReader(const std::string &path, bool directory, bool allowAbsent,
                                    Evidence *evidence, Error *error, uid_t uid, gid_t gid, const CydiaSources::ReaderGroups &groups) {
    if (evidence == NULL || directory) return false;
    struct stat leaf;
    if (lstat(path.c_str(), &leaf) == 0 && S_ISLNK(leaf.st_mode)) {
        *evidence = Evidence(); evidence->path = path;
        std::string canonical; struct stat alias;
        if (!CydiaSources::ReadOnlyAlias::Read(path, &evidence->bytes, &evidence->identity, &canonical, uid, gid, &alias, groups))
            return Fail(error, "unsafe_source_alias", "Cannot safely read the delegated source data.");
        std::ostringstream identity;
        identity << alias.st_dev << ' ' << alias.st_ino << ' ' << alias.st_uid << ' ' << alias.st_gid << ' '
            << alias.st_mode << ' ' << alias.st_size << ' ' << alias.st_nlink << ' ';
#ifdef __APPLE__
        identity << alias.st_mtimespec.tv_sec << ' ' << alias.st_mtimespec.tv_nsec << ' ' << alias.st_ctimespec.tv_sec << ' ' << alias.st_ctimespec.tv_nsec;
#else
        identity << alias.st_mtim.tv_sec << ' ' << alias.st_mtim.tv_nsec << ' ' << alias.st_ctim.tv_sec << ' ' << alias.st_ctim.tv_nsec;
#endif
        evidence->sourceDelegation = SerializeFields({canonical, identity.str()});
    } else if (!CaptureEvidence(path, false, allowAbsent, evidence, error)) return false;
    evidence->sourceInput = true; evidence->sourceReaderUID = uid; evidence->sourceReaderGID = gid;
    evidence->sourceReaderGroups = groups; return true;
}

bool CapturePathIdentity(const std::string &path, bool directory, bool executable,
                         Evidence *evidence, Error *error, bool adminAccess) {
    if (evidence == NULL || !ValidatePath(path, directory, executable, error, adminAccess && !executable)) return false;
    *evidence = Evidence();
    evidence->path = path; evidence->directory = directory; evidence->identityOnly = true; evidence->adminAccess = adminAccess;
    return stat(path.c_str(), &evidence->identity) == 0 ||
        Fail(error, "unsafe_path", "Cannot inspect privileged path identity.");
}

FrontendLock::FrontendLock() : fd_(-1) {}
FrontendLock::~FrontendLock() { if (fd_ >= 0) close(fd_); }
bool FrontendLock::held() const { return fd_ >= 0; }

int OpenFrontendLock(const std::string &adminDirectory, const std::string &leaf, Error *error) {
    if (leaf != "lock" && leaf != "lock-frontend") {
        Fail(error, "unsafe_lock", "Invalid package-manager lock purpose."); return -1;
    }
    if (!ValidateDpkgAdminPath(adminDirectory, true, error)) return -1;
    const std::string path = adminDirectory + "/" + leaf;
    int fd = open(path.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { Fail(error, "lock_failed", std::strerror(errno)); return -1; }
    struct stat identity;
    if (fstat(fd, &identity) != 0 || !S_ISREG(identity.st_mode) ||
        !Protected(identity) || identity.st_nlink != 1) {
        close(fd); Fail(error, "unsafe_lock", "Unsafe package-manager lock file."); return -1;
    }
    return fd;
}

bool FrontendLockOwner(const std::string &adminDirectory, pid_t *owner, Error *error) {
    const int fd = OpenFrontendLock(adminDirectory, "lock-frontend", error);
    if (fd < 0) return false;
    struct flock lock = {};
    lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
    const bool success = fcntl(fd, F_GETLK, &lock) == 0;
    const int saved = errno;
    if (success && owner != NULL) *owner = lock.l_type == F_UNLCK ? 0 : lock.l_pid;
    close(fd);
    return success || Fail(error, "lock_failed", std::strerror(saved));
}

bool FrontendLock::Acquire(const std::string &adminDirectory, Error *error) {
    return AcquirePrivate(adminDirectory, "lock-frontend", error, true);
}

bool FrontendLock::AcquirePrivate(const std::string &adminDirectory, const std::string &leaf, Error *error, bool adminAccess) {
    if (held()) return Fail(error, "lock_state", "The frontend lock is already held.");
    if (leaf.empty() || leaf.find('/') != std::string::npos || !SafeString(leaf))
        return Fail(error, "unsafe_lock", "Invalid private lock name.");
    if (!ValidatePath(adminDirectory, true, false, error, adminAccess)) return false;
    const std::string name = adminDirectory + "/" + leaf;
    int fd = open(name.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return Fail(error, "lock_failed", std::strerror(errno));
    struct stat identity;
    if (fstat(fd, &identity) != 0 || !S_ISREG(identity.st_mode) ||
        !Protected(identity) || identity.st_nlink != 1) {
        close(fd); return Fail(error, "unsafe_lock", "The frontend lock is not a protected regular file.");
    }
    struct flock lock = {};
    lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
    if (fcntl(fd, F_SETLK, &lock) == -1) {
        const int saved = errno; close(fd);
        return Fail(error, saved == EACCES || saved == EAGAIN ? "frontend_busy" : "lock_failed",
                    "Another frontend holds the package-manager lock.");
    }
    fd_ = fd;
    return true;
}

std::string ExecutableOverridesPath(const PackageDatabasePaths &paths) {
    return paths.CydiaStateDirectory() + "/runtime.conf";
}

bool ReadExecutableOverrides(const PackageDatabasePaths &paths,
                             std::map<std::string, std::string> *overrides,
                             Evidence *evidence, Error *error) {
    return ReadExecutableOverridesFromPath(ExecutableOverridesPath(paths), overrides, evidence, error);
}

bool ReadExecutableOverridesFromPath(const std::string &path,
                             std::map<std::string, std::string> *overrides,
                             Evidence *evidence, Error *error) {
    if (!ReadExecutableOverrideSettingsFromPath(path, overrides, evidence, error)) return false;
    for (const auto &entry : *overrides)
        if (!ValidateRootOwnedPath(entry.second, false, true, error)) {
            overrides->clear();
            return Fail(error, "invalid_overrides", "Invalid private executable override.");
        }
    return true;
}

bool ReadExecutableOverrideSettings(const PackageDatabasePaths &paths,
                             std::map<std::string, std::string> *overrides,
                             Evidence *evidence, Error *error) {
    return ReadExecutableOverrideSettingsFromPath(ExecutableOverridesPath(paths), overrides, evidence, error);
}

bool ReadExecutableOverrideSettingsFromPath(const std::string &path,
                             std::map<std::string, std::string> *overrides,
                             Evidence *evidence, Error *error) {
    if (overrides == NULL || evidence == NULL) return false;
    overrides->clear();
    if (!CaptureEvidence(path, false, true, evidence, error)) return false;
    if (evidence->absent) return true;
    if (evidence->bytes.compare(0, sizeof(overridesHeader) - 1, overridesHeader) != 0)
        return Fail(error, "invalid_overrides", "Unsupported private executable configuration.");
    std::map<std::string, std::string> saved;
    std::size_t offset = sizeof(overridesHeader) - 1;
    while (offset != evidence->bytes.size()) {
        std::string purpose, path;
        if (!ParseOne(evidence->bytes, &offset, &purpose, error) ||
            !ParseOne(evidence->bytes, &offset, &path, error) ||
            !AllowedPurpose(purpose) || saved.count(purpose) != 0 ||
            path.empty() || path[0] != '/' || !SafeString(path))
            return Fail(error, "invalid_overrides", "Invalid private executable override.");
        saved[purpose] = path;
    }
    if (!RecheckEvidence({*evidence}, error)) return false;
    *overrides = saved;
    return true;
}

bool WriteExecutableOverride(const PackageDatabasePaths &paths,
                             const std::string &purpose, const std::string &path, Error *error) {
    if (!AllowedPurpose(purpose) || (!path.empty() && !ValidateRootOwnedPath(path, false, true, error)))
        return Fail(error, "invalid_override", "Invalid executable purpose or path.");
    if (!ValidateRootOwnedPath(paths.CydiaStateDirectory(), true, false, error)) return false;
    FrontendLock configurationLock;
    /* A separate private lock serializes settings writes even while a broken
     * dpkg path is being repaired. It is unrelated to bootstrap dpkg locks. */
    const std::string lockDirectory = paths.CydiaStateDirectory();
    if (!configurationLock.AcquirePrivate(lockDirectory, "runtime.conf.lock", error)) return false;
    std::map<std::string, std::string> overrides;
    Evidence before;
    if (!ReadExecutableOverrideSettings(paths, &overrides, &before, error)) return false;
    if (path.empty()) overrides.erase(purpose); else overrides[purpose] = path;
    std::vector<std::string> fields;
    for (const auto &entry : overrides) { fields.push_back(entry.first); fields.push_back(entry.second); }
    const std::string bytes = std::string(overridesHeader) + SerializeFields(fields);
    std::string temporary = paths.CydiaStateDirectory() + "/.runtime.conf.XXXXXX";
    std::vector<char> name(temporary.begin(), temporary.end()); name.push_back('\0');
    int fd = mkstemp(name.data());
    if (fd < 0) return Fail(error, "write_failed", std::strerror(errno));
    bool success = fchmod(fd, 0644) == 0 && fchown(fd, 0, 0) == 0 &&
        WriteBytes(fd, bytes, error) && fsync(fd) == 0;
    if (close(fd) != 0) success = false;
    if (success) success = RecheckEvidence({before}, error);
    if (success) success = rename(name.data(), ExecutableOverridesPath(paths).c_str()) == 0;
    if (!success) { unlink(name.data()); return Fail(error, "write_failed", "Could not publish executable configuration."); }
    int directory = open(paths.CydiaStateDirectory().c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory < 0) return Fail(error, "write_failed", "Could not synchronize executable configuration.");
    success = fsync(directory) == 0; close(directory);
    return success || Fail(error, "write_failed", "Could not synchronize executable configuration.");
}

namespace {
const std::size_t maximumDpkgArguments = 100000;
enum class DpkgOptionKind { Ordinary, Root, Admin, Hook, Indirect };
struct DpkgOption {
    const char *name;
    unsigned arity; // Native takesvalue: 0, standard value 1, continued -value 2.
    DpkgOptionKind kind;
};
// Only the main dpkg 1.21/1.23 option phase is supported here. This table
// establishes token boundaries, not effective defaults or configuration policy.
const DpkgOption dpkgOptions[] = {
    {"install", 0, DpkgOptionKind::Ordinary}, {"unpack", 0, DpkgOptionKind::Ordinary},
    {"record-avail", 0, DpkgOptionKind::Ordinary}, {"configure", 0, DpkgOptionKind::Ordinary},
    {"remove", 0, DpkgOptionKind::Ordinary}, {"purge", 0, DpkgOptionKind::Ordinary},
    {"triggers-only", 0, DpkgOptionKind::Ordinary}, {"verify", 0, DpkgOptionKind::Ordinary},
    {"listfiles", 0, DpkgOptionKind::Ordinary}, {"status", 0, DpkgOptionKind::Ordinary},
    {"get-selections", 0, DpkgOptionKind::Ordinary}, {"set-selections", 0, DpkgOptionKind::Ordinary},
    {"clear-selections", 0, DpkgOptionKind::Ordinary}, {"print-avail", 0, DpkgOptionKind::Ordinary},
    {"update-avail", 0, DpkgOptionKind::Ordinary}, {"merge-avail", 0, DpkgOptionKind::Ordinary},
    {"clear-avail", 0, DpkgOptionKind::Ordinary}, {"forget-old-unavail", 0, DpkgOptionKind::Ordinary},
    {"audit", 0, DpkgOptionKind::Ordinary}, {"yet-to-unpack", 0, DpkgOptionKind::Ordinary},
    {"list", 0, DpkgOptionKind::Ordinary}, {"search", 0, DpkgOptionKind::Ordinary},
    {"assert", 2, DpkgOptionKind::Ordinary}, {"add-architecture", 0, DpkgOptionKind::Ordinary},
    {"remove-architecture", 0, DpkgOptionKind::Ordinary}, {"print-architecture", 0, DpkgOptionKind::Ordinary},
    {"print-foreign-architectures", 0, DpkgOptionKind::Ordinary}, {"predep-package", 0, DpkgOptionKind::Ordinary},
    {"validate-pkgname", 0, DpkgOptionKind::Ordinary}, {"validate-trigname", 0, DpkgOptionKind::Ordinary},
    {"validate-archname", 0, DpkgOptionKind::Ordinary}, {"validate-version", 0, DpkgOptionKind::Ordinary},
    {"compare-versions", 0, DpkgOptionKind::Ordinary}, {"help", 0, DpkgOptionKind::Ordinary},
    {"version", 0, DpkgOptionKind::Ordinary}, {"pre-invoke", 1, DpkgOptionKind::Hook},
    {"post-invoke", 1, DpkgOptionKind::Hook}, {"path-exclude", 1, DpkgOptionKind::Ordinary},
    {"path-include", 1, DpkgOptionKind::Ordinary}, {"verify-format", 1, DpkgOptionKind::Ordinary},
    {"status-logger", 1, DpkgOptionKind::Indirect}, {"command-fd", 0, DpkgOptionKind::Indirect},
    {"status-fd", 1, DpkgOptionKind::Ordinary}, {"log", 1, DpkgOptionKind::Ordinary},
    {"pending", 0, DpkgOptionKind::Ordinary}, {"recursive", 0, DpkgOptionKind::Ordinary},
    {"no-act", 0, DpkgOptionKind::Ordinary}, {"dry-run", 0, DpkgOptionKind::Ordinary},
    {"simulate", 0, DpkgOptionKind::Ordinary}, {"no-pager", 0, DpkgOptionKind::Ordinary},
    {"no-debsig", 0, DpkgOptionKind::Ordinary}, {"selected-only", 0, DpkgOptionKind::Ordinary},
    {"triggers", 0, DpkgOptionKind::Ordinary}, {"no-triggers", 0, DpkgOptionKind::Ordinary},
    {"no-also-select", 0, DpkgOptionKind::Ordinary}, {"skip-same-version", 0, DpkgOptionKind::Ordinary},
    {"auto-deconfigure", 0, DpkgOptionKind::Ordinary}, {"robot", 0, DpkgOptionKind::Ordinary},
    {"root", 1, DpkgOptionKind::Root}, {"abort-after", 1, DpkgOptionKind::Ordinary},
    {"admindir", 1, DpkgOptionKind::Admin}, {"instdir", 1, DpkgOptionKind::Root},
    {"ignore-depends", 1, DpkgOptionKind::Ordinary}, {"force", 2, DpkgOptionKind::Ordinary},
    {"refuse", 2, DpkgOptionKind::Ordinary}, {"no-force", 2, DpkgOptionKind::Ordinary},
    {"debug", 1, DpkgOptionKind::Ordinary}, {"build", 0, DpkgOptionKind::Ordinary},
    {"contents", 0, DpkgOptionKind::Ordinary}, {"control", 0, DpkgOptionKind::Ordinary},
    {"info", 0, DpkgOptionKind::Ordinary}, {"field", 0, DpkgOptionKind::Ordinary},
    {"extract", 0, DpkgOptionKind::Ordinary}, {"vextract", 0, DpkgOptionKind::Ordinary},
    {"ctrl-tarfile", 0, DpkgOptionKind::Ordinary}, {"fsys-tarfile", 0, DpkgOptionKind::Ordinary}
};
struct DpkgPathSpan { std::size_t begin, end; };
bool DpkgArgumentBudget(const std::vector<std::string> &arguments, Error *error) {
    if (arguments.size() > maximumDpkgArguments)
        return Fail(error, "invalid_dpkg_argument", "Too many dpkg arguments.");
    std::size_t bytes = 0;
    for (const auto &argument : arguments) {
        if (argument.size() >= maximumRequest || argument.size() + 1 > maximumRequest - bytes)
            return Fail(error, "invalid_dpkg_argument", "Dpkg arguments exceed their size limit.");
        bytes += argument.size() + 1;
        if (argument.find('\0') != std::string::npos)
            return Fail(error, "invalid_dpkg_argument", "Invalid dpkg argument.");
    }
    return true;
}
bool DpkgPathMatches(const Environment &environment, DpkgOptionKind kind, const std::string &value, Error *error) {
    const auto &expected = kind == DpkgOptionKind::Admin ? environment.dpkgAdmin : environment.dpkgRoot;
    char *actual = realpath(value.c_str(), NULL);
    char *wanted = realpath(expected.c_str(), NULL);
    const bool same = actual != NULL && wanted != NULL && std::strcmp(actual, wanted) == 0;
    std::free(actual); std::free(wanted);
    return same || Fail(error, "dpkg_environment_mismatch", "dpkg and APT select different roots or databases.");
}
bool WalkDpkgArguments(const Environment &environment, const std::vector<std::string> &arguments,
    std::vector<DpkgPathSpan> *paths, Error *error) {
    if (!DpkgArgumentBudget(arguments, error)) return false;
    std::vector<std::string> hooks;
    for (std::size_t i = 0; i < arguments.size(); ++i) {
        const auto &argument = arguments[i];
        // Native parsing does not permute options past an operand. Even bytes
        // spelling an unsafe option are ordinary data after this boundary.
        if (argument == "--" || argument == "-" || argument.empty() || argument[0] != '-') {
            for (; i < arguments.size(); ++i) if (!SafeString(arguments[i]))
                return Fail(error, "invalid_dpkg_argument", "Invalid dpkg argument.");
            break;
        }
        if (argument.compare(0, 2, "--") != 0) {
            if (!SafeString(argument)) return Fail(error, "invalid_dpkg_argument", "Invalid dpkg argument.");
            // D is the sole value-taking short option in these native tables.
            // Its suffix is one opaque value, never more clustered options.
            for (std::size_t at = 1; at < argument.size(); ++at) {
                if (argument[at] == 'D') {
                    if (at + 1 == argument.size()) {
                        if (++i == arguments.size()) return Fail(error, "invalid_dpkg_argument", "Missing dpkg option value.");
                        if (!SafeString(arguments[i])) return Fail(error, "invalid_dpkg_argument", "Invalid dpkg option value.");
                    }
                    break;
                }
                if (std::strchr("iArPVLspClS?aRGONEBbceIfxX", argument[at]) == NULL)
                    return Fail(error, "unsupported_dpkg_option", "Unknown dpkg option arity is not supported.");
            }
            continue;
        }
        const auto equal = argument.find('=');
        const auto spelling = argument.substr(0, equal);
        for (const char *restricted : {"--root", "--instdir", "--admindir", "--pre-invoke", "--post-invoke", "--command-fd", "--status-logger"}) {
            const std::string name(restricted);
            if (spelling.size() > 2 && spelling.size() < name.size() && name.compare(0, spelling.size(), spelling) == 0)
                return Fail(error, "unsafe_dpkg_argument", "Abbreviated privileged options are not supported.");
        }
        const DpkgOption *option = NULL; std::size_t valueAt = std::string::npos;
        for (const auto &candidate : dpkgOptions) {
            const std::string name = std::string("--") + candidate.name;
            if (argument == name) { option = &candidate; break; }
            if (argument.size() > name.size() && argument.compare(0, name.size(), name) == 0 &&
                argument[name.size()] == (candidate.arity == 2 ? '-' : '=')) {
                if (candidate.arity == 0 && candidate.kind != DpkgOptionKind::Indirect)
                    return Fail(error, "invalid_dpkg_argument", "Unexpected dpkg option value.");
                option = &candidate; valueAt = name.size() + 1; break;
            }
        }
        if (option == NULL) return Fail(error, "unsupported_dpkg_option", "Unknown dpkg option arity is not supported.");
        if (option->kind == DpkgOptionKind::Indirect)
            return Fail(error, "unsafe_dpkg_argument", "Indirect commands are not a privileged tool interface.");
        const auto begin = i;
        std::string value;
        if (option->arity != 0) {
            if (valueAt != std::string::npos) value = argument.substr(valueAt);
            else {
                if (++i == arguments.size()) return Fail(error, "invalid_dpkg_argument", "Missing dpkg option value.");
                value = arguments[i];
            }
        }
        if (option->kind == DpkgOptionKind::Hook) {
            // Root-approved hook commands retain their exact shell bytes,
            // including line breaks; all argument NULs were rejected above.
            if (value.empty()) return Fail(error, "invalid_dpkg_argument", "Invalid dpkg hook command.");
            hooks.push_back(std::string("--") + option->name + '=' + value);
        } else {
            if (!SafeString(argument) || !SafeString(value))
                return Fail(error, "invalid_dpkg_argument", "Invalid dpkg argument.");
            if (option->kind == DpkgOptionKind::Root || option->kind == DpkgOptionKind::Admin) {
                if (!DpkgPathMatches(environment, option->kind, value, error)) return false;
                if (paths != NULL) paths->push_back({begin, i + 1});
            }
        }
    }
    if (!hooks.empty() && hooks != environment.trustedDpkgHooks)
        return Fail(error, "unsafe_dpkg_argument", "Invocation hooks must exactly match protected APT configuration.");
    return true;
}
}

bool ValidateDpkgArguments(const Environment &environment,
                           const std::vector<std::string> &arguments, Error *error) {
    return WalkDpkgArguments(environment, arguments, NULL, error);
}

bool BindDpkgArguments(const Environment &environment, const std::vector<std::string> &arguments,
    std::vector<std::string> *bound, Error *error) {
    if (!bound) return Fail(error, "invalid_dpkg_argument", "Invalid dpkg argument.");
    if (environment.dpkgRoot.size() > 4096 || environment.dpkgAdmin.size() > 4096) {
        bound->clear(); return Fail(error, "invalid_dpkg_argument", "Dpkg paths exceed their size limit.");
    }
    std::vector<DpkgPathSpan> paths;
    if (!WalkDpkgArguments(environment, arguments, &paths, error)) {
        bound->clear(); return false;
    }
    std::vector<std::string> result{"--root=" + environment.dpkgRoot, "--admindir=" + environment.dpkgAdmin};
    if (!WalkDpkgArguments(environment, result, NULL, error)) { bound->clear(); return false; }
    std::size_t begin = 0;
    for (const auto &path : paths) {
        result.insert(result.end(), arguments.begin() + begin, arguments.begin() + path.begin);
        begin = path.end;
    }
    result.insert(result.end(), arguments.begin() + begin, arguments.end());
    if (!DpkgArgumentBudget(result, error)) { bound->clear(); return false; }
    *bound = std::move(result); return true;
}

} // namespace Privileged
} // namespace CydiaRuntime
