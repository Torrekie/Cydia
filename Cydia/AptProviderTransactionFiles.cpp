/* Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#include "Cydia/AptProviderTransactionFiles.hpp"
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
bool SelectHashes(const ArchiveManifest &archive, StagedArchiveEvidence *copy, std::string *error) {
    std::map<std::string, std::string> selected;
    for (const auto &hash : archive.hashes) {
        const auto actual = copy->hashes.find(hash.first);
        if (actual == copy->hashes.end() || actual->second != hash.second) return Fail(error, "provider_archive_hash_changed");
        selected.insert(*actual);
    }
    selected["SHA256"] = copy->identity.file.sha256;
    copy->hashes.swap(selected); return true;
}
}
class TransactionArchiveStore::Implementation {
public:
    std::string directory;
    int directoryFD = -1;
    std::vector<int> files;
    std::vector<std::string> leaves;
    std::vector<RetainedTransactionArchive> archives;
    std::vector<RetainedComponentArchive> successors;
    std::vector<VerifiedArchiveControlEvidence> effectControls;
    bool begun = false, ready = false;
    ~Implementation() {
        for (int fd : files) close(fd);
        if (directoryFD >= 0) {
            for (const auto &leaf : leaves) unlinkat(directoryFD, leaf.c_str(), 0);
            close(directoryFD);
        }
        if (!directory.empty()) rmdir(directory.c_str());
    }
    bool Copy(const ArchiveManifest &archive, std::string *path, int *descriptor, std::string *error,
        const std::function<bool()> &cancelled) {
        FD input(open(archive.path.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
        struct stat before, after, named;
        if (input.value < 0 || fstat(input.value, &before) != 0 || !S_ISREG(before.st_mode) || before.st_nlink != 1 ||
            before.st_size < 0 || static_cast<std::uint64_t>(before.st_size) != archive.size ||
            archive.size == 0 || archive.size > CydiaPackages::ArchiveLimits().maxStreamBytes)
            return Fail(error, "provider_archive_size_changed");
        const std::string leaf = std::to_string(leaves.size()) + ".deb";
        const int output = openat(directoryFD, leaf.c_str(), O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (output < 0) return Fail(error, "provider_archive_staging_failed");
        leaves.push_back(leaf); files.push_back(output); *path = directory + '/' + leaf; *descriptor = output;
        if (fchmod(output, 0600) != 0) return Fail(error, "provider_archive_staging_failed");
        std::uint64_t remaining = archive.size; char bytes[65536];
        while (remaining) {
            if (!Active(cancelled, error)) return false;
            const auto wanted = static_cast<std::size_t>(std::min<std::uint64_t>(remaining, sizeof(bytes)));
            ssize_t count; do { count = read(input.value, bytes, wanted); } while (count < 0 && errno == EINTR);
            if (count <= 0) return Fail(error, "provider_archive_copy_failed");
            std::size_t written = 0;
            while (written < static_cast<std::size_t>(count)) {
                ssize_t size; do { size = write(output, bytes + written, count - written); } while (size < 0 && errno == EINTR);
                if (size <= 0) return Fail(error, "provider_archive_copy_failed");
                written += size;
            }
            remaining -= count;
        }
        if (fsync(output) != 0 || fstat(input.value, &after) != 0 || lstat(archive.path.c_str(), &named) != 0 ||
            !CydiaRuntime::SharedState::SameStat(before, after) || !CydiaRuntime::SharedState::SameStat(before, named))
            return Fail(error, "provider_archive_copy_changed");
        return true;
    }
};
TransactionArchiveStore::TransactionArchiveStore() : implementation_(new Implementation) {}
TransactionArchiveStore::~TransactionArchiveStore() = default;
bool TransactionArchiveStore::Begin(const std::string &base, const RuntimeDescriptor &runtime,
    const ReviewedTransaction &review, const ReviewPolicy &policy, const std::string &searchPath,
    const std::map<std::string, std::vector<std::string>> &requested, std::string *error,
    const std::function<bool()> &cancelled, bool captureEffectControls) {
    auto &state = *implementation_;
    if (state.begun) return Fail(error, "provider_archive_store_reused");
    state.begun = true;
    ReviewAuthorization authorization;
    P::Error ignored;
    if (!authorization.Accept(review, policy, error) || !Active(cancelled, error) ||
        !P::ValidateRootOwnedPath(base, true, false, &ignored)) return Fail(error, "provider_archive_staging_unavailable");
    auto source = ArchiveEvidenceSnapshot::Capture(runtime, review, searchPath, cancelled, error);
    std::vector<VerifiedArchiveEvidence> observed;
    if (!source || !source->Verify(review.execution.archives, &observed, cancelled, error) ||
        !VerifyReviewedArchiveEvidence(review.execution.archives, observed, policy.unverifiedArchiveWarningsAccepted, error)) return false;
    std::vector<VerifiedArchiveControlEvidence> sourceControls;
    if (captureEffectControls && !source->VerifyControl(review.execution.archives, &sourceControls, cancelled, error)) return false;
    std::set<std::string> identifiers;
    for (const auto &archive : review.execution.archives) identifiers.insert(archive.identifier);
    for (const auto &paths : requested)
        if (!identifiers.count(paths.first) || paths.second.empty() || paths.second.size() > MaximumTransactionComponents)
            return Fail(error, "provider_successor_paths_invalid");
    std::string pattern = base + "/.provider-lease-XXXXXX";
    std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
    char *created = mkdtemp(name.data());
    if (!created) return Fail(error, "provider_archive_staging_failed");
    state.directory = created;
    if (chmod(created, 0700) != 0 || !P::ValidateRootOwnedPath(state.directory, true, false, &ignored) ||
        (state.directoryFD = open(created, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)) < 0)
        return Fail(error, "provider_archive_staging_failed");
    std::map<std::string, std::string> decoders;
    if (!CydiaPackages::ResolveTrustedArchiveDecoders(searchPath, &decoders, error)) return false;
    for (const auto &archive : review.execution.archives) {
        std::string path; int fd = -1;
        if (!state.Copy(archive, &path, &fd, error, cancelled)) return false;
        RetainedTransactionArchive retained;
        if (!CaptureRetainedTransactionFile(path, fd, &retained.copy, error, cancelled) || !SelectHashes(archive, &retained.copy, error)) return false;
        retained.source.archive = archive;
        const auto paths = requested.find(archive.identifier);
        CydiaPackages::ArchivePayloadEvidence payload;
        if (paths != requested.end()) {
            payload = CydiaPackages::InspectPackageArchivePayloadWithDecoders(path,
                {archive.package.package, archive.package.version, archive.package.architecture}, archive.layout,
                paths->second, decoders, CydiaPackages::ArchiveLimits(), cancelled);
            if (!payload.payload.complete || payload.files.size() != paths->second.size())
                return Fail(error, "provider_successor_payload_unverified");
            retained.source.inspection = payload.archive;
        } else retained.source.inspection = CydiaPackages::InspectPackageArchiveWithDecoders(path,
            {archive.package.package, archive.package.version, archive.package.architecture}, archive.layout,
            decoders, CydiaPackages::ArchiveLimits(), cancelled);
        retained.source.fileIdentity = "sha256:" + HashBytes(P::SerializeFields({path,
            std::to_string(retained.copy.identity.device), std::to_string(retained.copy.identity.inode),
            retained.copy.identity.file.sha256, retained.copy.identity.parentsIdentity}));
        if (!VerifyReviewedArchiveEvidence({archive}, {retained.source}, policy.unverifiedArchiveWarningsAccepted, error)) return false;
        if (captureEffectControls) {
            const auto control = CydiaPackages::InspectPackageArchiveControlWithDecoders(path,
                {archive.package.package, archive.package.version, archive.package.architecture}, archive.layout,
                decoders, CydiaPackages::ArchiveLimits(), cancelled);
            const VerifiedArchiveControlEvidence *original = nullptr;
            for (const auto &candidate : sourceControls) if (candidate.archive.archive.identifier == archive.identifier) original = &candidate;
            if (!original || !control.control.complete || !control.archive.complete || !control.archive.identityVerified ||
                control.control.controls != original->control.controls || control.control.triggersPresent != original->control.triggersPresent ||
                control.control.triggers != original->control.triggers) return Fail(error, "provider_trigger_incoming_unverified");
            VerifiedArchiveControlEvidence effect; effect.archive = retained.source; effect.control = control.control;
            state.effectControls.push_back(std::move(effect));
        }
        StagedArchiveEvidence after;
        if (!CaptureRetainedTransactionFile(path, fd, &after, error, cancelled) || !SelectHashes(archive, &after, error) ||
            !SameInstalledComponent(retained.copy.identity, after.identity) || retained.copy.hashes != after.hashes)
            return Fail(error, "provider_archive_staging_changed");
        if (paths != requested.end()) {
            RetainedComponentArchive successor; successor.archive = retained.source; successor.payload = std::move(payload);
            state.successors.push_back(std::move(successor));
        }
        state.archives.push_back(std::move(retained));
    }
    if (!source->Verify(review.execution.archives, &observed, cancelled, error) || !Active(cancelled, error)) return false;
    state.ready = true; return true;
}
bool TransactionArchiveStore::Capture(std::vector<StagedArchiveEvidence> *result, std::string *error,
    const std::function<bool()> &cancelled) const {
    if (!result) return Fail(error, "provider_archive_input_invalid");
    result->clear(); const auto &state = *implementation_;
    if (!state.ready || state.files.size() != state.archives.size()) return Fail(error, "provider_archive_store_unavailable");
    struct stat named, opened;
    if (lstat(state.directory.c_str(), &named) != 0 || fstat(state.directoryFD, &opened) != 0 ||
        named.st_dev != opened.st_dev || named.st_ino != opened.st_ino || !S_ISDIR(named.st_mode) ||
        named.st_uid != 0 || (named.st_mode & 07777) != 0700) return Fail(error, "provider_archive_staging_changed");
    std::vector<StagedArchiveEvidence> files;
    for (std::size_t index = 0; index != state.files.size(); ++index) {
        StagedArchiveEvidence value; const auto &expected = state.archives[index];
        if (!CaptureRetainedTransactionFile(expected.copy.identity.file.metadata.path, state.files[index], &value, error, cancelled) ||
            !SelectHashes(expected.source.archive, &value, error) ||
            !SameInstalledComponent(value.identity, expected.copy.identity) || value.hashes != expected.copy.hashes)
            return Fail(error, "provider_archive_staging_changed");
        files.push_back(std::move(value));
    }
    *result = std::move(files); return true;
}
const std::string &TransactionArchiveStore::directory() const { return implementation_->directory; }
const std::vector<RetainedTransactionArchive> &TransactionArchiveStore::archives() const { return implementation_->archives; }
const std::vector<RetainedComponentArchive> &TransactionArchiveStore::successors() const { return implementation_->successors; }
const std::vector<VerifiedArchiveControlEvidence> &TransactionArchiveStore::effectControls() const { return implementation_->effectControls; }
}}
