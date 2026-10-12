/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryTrust.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
namespace CydiaAPT { namespace Recovery {
namespace {
namespace P = CydiaRuntime::Privileged;
struct Capture {
    const std::function<bool()> &cancelled;
    std::size_t files = 0, bytes = 0;
    explicit Capture(const std::function<bool()> &value) : cancelled(value) {}
    bool Stopped() const { return cancelled && cancelled(); }
    bool Read(const std::string &path, bool directory, bool absent, P::Evidence *e, P::Error *error, bool source) {
        if (Stopped() || ++files > 1024) return false;
        if (!(source ? P::CaptureSourceEvidence : P::CaptureEvidence)(path, directory, absent, e, error)) return false;
        bytes += e->bytes.size();
        return bytes <= 16 * 1024 * 1024 && e->entries.size() <= 4096 && !Stopped();
    }
};
thread_local Capture *capture = nullptr;
bool Protected(const std::string &path, bool directory, bool absent, P::Evidence *e, P::Error *error) {
    return capture && capture->Read(path, directory, absent, e, error, false);
}
bool Source(const std::string &path, bool directory, bool absent, P::Evidence *e, P::Error *error) {
    return capture && capture->Read(path, directory, absent, e, error, true);
}
std::string Context(const Snapshot &snapshot, const std::function<bool()> &cancelled) {
    Capture bounded{cancelled};
    struct Scope { Capture *previous; explicit Scope(Capture *value) : previous(capture) { capture = value; }
        ~Scope() { capture = previous; } } scope(&bounded);
    P::Environment environment;
    environment.sourceReaderUID = getuid(); environment.sourceReaderGID = getgid();
    environment.sourceList = snapshot.runtime.sourceListPath;
    environment.sourceParts = snapshot.runtime.sourcePartsDirectory;
    environment.trusted = snapshot.runtime.trustedKeyringPath;
    environment.trustedParts = snapshot.runtime.trustedKeyringPartsDirectory;
    // Captured configuration is immutable for this process. The parent also
    // revalidates its protected origin before each review/execution; here only
    // source/key material is reread, never a new apt.conf or privileged action.
    std::vector<P::Evidence> inputs; P::Error error;
    if (!environment.sourceReaderGroups.valid || !P::CaptureSnapshotInputs(environment,
        P::SnapshotScope::RepositoryTrust, &inputs, &error, Protected, Protected, Source) || bounded.Stopped()) return {};
    Hashes hash(Hashes::SHA256SUM);
    const std::string identity(P::SerializeFields({"CYDIA-RECOVERY-TRUST-1", snapshot.identity.configuration,
        snapshot.identity.policy, snapshot.identity.methods, snapshot.identity.libraries, snapshot.identity.frontend}));
    if (!hash.Add(identity.data(), identity.size())) return {};
    for (const auto &input : inputs) {
        if (bounded.Stopped()) return {};
        // Recheck one bounded input at a time to retain cancellation points.
        if (!P::RecheckEvidence({input}, &error)) return {};
        const std::string bytes(P::SerializeSnapshotEvidence(input));
        if (!hash.Add(bytes.data(), bytes.size())) return {};
    }
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
bool Same(const struct stat &a, const struct stat &b) {
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_size != b.st_size || a.st_mode != b.st_mode) return false;
#if defined(__APPLE__)
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
bool Names(const std::string &path, std::vector<std::string> *names) {
    DIR *dir(opendir(path.c_str())); if (!dir) return false;
    bool okay = true; errno = 0;
    while (const auto entry = readdir(dir)) {
        const std::string name(entry->d_name);
        if (name != "." && name != "..") names->push_back(name);
        if (names->size() > 4096) { okay = false; break; }
    }
    okay = okay && errno == 0; closedir(dir);
    std::sort(names->begin(), names->end()); return okay;
}
std::string Indexes(const Snapshot &snapshot, const std::function<bool()> &cancelled) {
    std::vector<std::string> before, after; std::size_t total = 0;
    if (!Names(snapshot.runtime.listsDirectory, &before)) return {};
    Hashes index(Hashes::SHA256SUM);
    for (const auto &name : before) {
        if (cancelled && cancelled()) return {};
        if (name == "lock" || name == "partial" || name == "auxfiles") continue;
        const std::string path(snapshot.runtime.listsDirectory + '/' + name);
        struct stat initial, opened, final, current;
        if (lstat(path.c_str(), &initial) || !S_ISREG(initial.st_mode) || initial.st_size < 0 ||
            initial.st_size > 128 * 1024 * 1024) return {};
        const int fd(open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
        if (fd < 0) return {};
        Hashes file(Hashes::SHA256SUM); char bytes[32768]; std::size_t offset = 0;
        bool okay(fstat(fd, &opened) == 0 && Same(initial, opened));
        while (okay) {
            if (cancelled && cancelled()) { okay = false; break; }
            const auto size(read(fd, bytes, sizeof(bytes)));
            if (size < 0 && errno == EINTR) continue;
            if (size < 0) { okay = false; break; }
            if (!size) break;
            offset += size; total += size;
            okay = offset <= 128 * 1024 * 1024 && total <= 512 * 1024 * 1024 && file.Add(bytes, size);
        }
        okay = okay && offset == static_cast<std::size_t>(initial.st_size) && fstat(fd, &final) == 0 &&
            lstat(path.c_str(), &current) == 0 && Same(initial, final) && Same(initial, current);
        close(fd); if (!okay) return {};
        const auto frame(P::SerializeFields({name, file.GetHashString(Hashes::SHA256SUM).HashValue()}));
        if (!index.Add(frame.data(), frame.size())) return {};
    }
    if (!Names(snapshot.runtime.listsDirectory, &after) || before != after) return {};
    return index.GetHashString(Hashes::SHA256SUM).HashValue();
}
}
std::string WorkerTrustProof::BeginRefresh(const Snapshot &snapshot, const std::function<bool()> &cancelled) {
    proof_ = CydiaRuntime::RepositoryTrustProof();
    return Context(snapshot, cancelled);
}
bool WorkerTrustProof::CompleteRefresh(const Snapshot &snapshot, const std::string &before,
    bool complete, const std::function<bool()> &cancelled) {
    proof_ = CydiaRuntime::RepositoryTrustProof();
    return complete && proof_.RecordCompletedRefresh(before, Context(snapshot, cancelled), Indexes(snapshot, cancelled), true);
}
bool WorkerTrustProof::Matches(const Snapshot &snapshot, const std::function<bool()> &cancelled) const {
    return proof_.Matches(Context(snapshot, cancelled), Indexes(snapshot, cancelled));
}
}}
