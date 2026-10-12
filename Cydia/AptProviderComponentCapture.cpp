/* Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#include "Cydia/AptProviderComponentCapture.hpp"
#include "Cydia/SharedStateFile.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Active(const std::function<bool()> &cancelled, std::string *error) {
    return !(cancelled && cancelled()) || Fail(error, "provider_cancelled");
}
struct FD {
    int value;
    explicit FD(int descriptor = -1) : value(descriptor) {}
    ~FD() { if (value >= 0) close(value); }
    FD(const FD &) = delete; FD &operator=(const FD &) = delete;
};
std::string HashBytes(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM);
    return hash.Add(bytes.data(), bytes.size()) ? hash.GetHashString(Hashes::SHA256SUM).HashValue() : "";
}
bool Path(const std::string &path) {
    if (path.size() < 2 || path.size() > 4096 || path.front() != '/' || path.back() == '/') return false;
    for (unsigned char c : path) if (c < 32 || c == 127) return false;
    std::size_t cursor = 1;
    while (cursor < path.size()) {
        const auto end = path.find('/', cursor);
        const auto part = path.substr(cursor, end == std::string::npos ? end : end - cursor);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        cursor = end + 1;
    }
    return true;
}
bool Chain(const std::string &path, std::map<std::string, std::string> *parts, unsigned depth = 0) {
    if (depth > 40 || path.empty() || path.front() != '/' || path.size() > 4096) return false;
    for (std::size_t end = 1; end <= path.size(); ++end) {
        if (end != path.size() && path[end] != '/') continue;
        const std::string part(path.substr(0, end)); struct stat st;
        if (lstat(part.c_str(), &st) != 0 || st.st_uid != 0 ||
            (!S_ISLNK(st.st_mode) && (!S_ISDIR(st.st_mode) || (st.st_mode & 0022)))) return false;
        std::string target;
        if (S_ISLNK(st.st_mode)) {
            char bytes[4097]; const ssize_t size = readlink(part.c_str(), bytes, sizeof(bytes) - 1);
            if (size <= 0 || size == static_cast<ssize_t>(sizeof(bytes) - 1)) return false;
            target.assign(bytes, size);
            const auto slash = part.find_last_of('/');
            if (!Chain(target.front() == '/' ? target : part.substr(0, slash + 1) + target, parts, depth + 1)) return false;
        }
        // Directory mtimes, size and link counts change legitimately when dpkg
        // adds files. Bind canonical identity and permissions, not membership.
        const std::string identity = P::SerializeFields({part, std::to_string(st.st_dev), std::to_string(st.st_ino),
            std::to_string(st.st_mode), std::to_string(st.st_uid), std::to_string(st.st_gid), target});
        const auto found = parts->find(part);
        if (found != parts->end() && found->second != identity) return false;
        (*parts)[part] = identity;
    }
    return true;
}
bool Parents(const std::string &path, std::string *identity, std::string *error) {
    P::Error ignored;
    const auto slash = path.find_last_of('/');
    const std::string parent = slash == 0 ? "/" : path.substr(0, slash);
    if (!Path(path) || !P::ValidateRootOwnedPath(parent, true, false, &ignored))
        return Fail(error, "provider_component_parent_unsafe");
    char *resolved = realpath(parent.c_str(), nullptr);
    if (!resolved) return Fail(error, "provider_component_parent_unsafe");
    const std::string canonical(resolved); free(resolved);
    std::map<std::string, std::string> parts;
    if (!Chain(parent, &parts) || !Chain(canonical, &parts)) return Fail(error, "provider_component_parent_unsafe");
    std::string bytes("CYDIA-TRANSACTION-PARENTS-1");
    for (const auto &part : parts) bytes += part.second;
    *identity = HashBytes(bytes);
    return identity->size() == 64 || Fail(error, "provider_component_hash_failed");
}
bool Regular(const struct stat &st) {
    return S_ISREG(st.st_mode) && st.st_uid == 0 && !(st.st_mode & 0022) && st.st_nlink == 1 &&
        st.st_size >= 0 && static_cast<std::uint64_t>(st.st_size) <= CydiaPackages::ArchiveLimits().maxStreamBytes;
}
bool CaptureFile(const std::string &path, int retained, StagedArchiveEvidence *result,
    std::string *error, const std::function<bool()> &cancelled) {
    if (!result) return Fail(error, "provider_component_input_invalid");
    *result = StagedArchiveEvidence();
    if (!Active(cancelled, error)) return false;
    std::string parents;
    struct stat named, opened;
    if (!Parents(path, &parents, error) || lstat(path.c_str(), &named) != 0 || !Regular(named))
        return Fail(error, "provider_component_file_unsafe");
    FD local(retained < 0 ? open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) : -1);
    const int fd = retained >= 0 ? retained : local.value;
    if (fd < 0 || fstat(fd, &opened) != 0 || !CydiaRuntime::SharedState::SameStat(named, opened))
        return Fail(error, "provider_component_file_changed");
    Hashes hashes(Hashes::MD5SUM | Hashes::SHA1SUM | Hashes::SHA256SUM | Hashes::SHA512SUM);
    std::uint64_t offset = 0; unsigned char bytes[65536];
    while (offset < static_cast<std::uint64_t>(opened.st_size)) {
        if (!Active(cancelled, error)) return false;
        const auto length = static_cast<std::size_t>(std::min<std::uint64_t>(sizeof(bytes), opened.st_size - offset));
        ssize_t count; do { count = pread(fd, bytes, length, static_cast<off_t>(offset)); } while (count < 0 && errno == EINTR);
        if (count <= 0 || !hashes.Add(bytes, static_cast<unsigned long long>(count))) return Fail(error, "provider_component_read_failed");
        offset += count;
    }
    struct stat after, current; std::string currentParents;
    if (!Active(cancelled, error) || fstat(fd, &after) != 0 || lstat(path.c_str(), &current) != 0 ||
        !CydiaRuntime::SharedState::SameStat(opened, after) || !CydiaRuntime::SharedState::SameStat(opened, current) ||
        !Parents(path, &currentParents, error) || currentParents != parents)
        return Fail(error, "provider_component_file_changed");
    StagedArchiveEvidence value;
    for (const auto &hash : hashes.GetHashStringList()) value.hashes[hash.HashType()] = hash.HashValue();
    auto &file = value.identity;
    file.file.metadata.path = path; file.file.metadata.size = opened.st_size;
    file.file.metadata.mode = opened.st_mode & 07777; file.file.metadata.uid = opened.st_uid; file.file.metadata.gid = opened.st_gid;
    file.file.sha256 = value.hashes["SHA256"]; file.kind = ComponentFileKind::Regular;
    file.device = opened.st_dev; file.inode = opened.st_ino; file.links = opened.st_nlink; file.parentsIdentity = parents;
    *result = std::move(value); return true;
}
}
bool CaptureTransactionComponent(const std::string &path, InstalledComponentEvidence *result,
    std::string *error, const std::function<bool()> &cancelled) {
    if (!result) return Fail(error, "provider_component_input_invalid");
    *result = InstalledComponentEvidence(); StagedArchiveEvidence file;
    if (!CaptureFile(path, -1, &file, error, cancelled)) return false;
    *result = std::move(file.identity); return true;
}
bool CaptureRetainedTransactionFile(const std::string &path, int descriptor, StagedArchiveEvidence *result,
    std::string *error, const std::function<bool()> &cancelled) {
    return CaptureFile(path, descriptor, result, error, cancelled);
}
}}
