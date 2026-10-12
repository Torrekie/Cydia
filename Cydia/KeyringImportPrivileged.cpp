/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/KeyringImport.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/RuntimeState.hpp"
#include "Cydia/KeyringVerifier.hpp"
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sstream>
#include <unistd.h>

namespace CydiaRuntime { namespace Keyring {
namespace {
bool Fail(Privileged::Error *error, const char *code, const char *message) {
    if (error) { error->code = code; error->message = message; } return false;
}
std::string Digest(const std::string &bytes) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), hash);
    const char *hex = "0123456789abcdef"; std::string result;
    for (unsigned char c : hash) { result += hex[c >> 4]; result += hex[c & 15]; } return result;
}
bool Write(int fd, const std::string &bytes) {
    std::size_t offset(0);
    while (offset < bytes.size()) { const ssize_t count(write(fd, bytes.data() + offset, bytes.size() - offset));
        if (count < 0 && errno == EINTR) continue; if (count <= 0) return false; offset += count; }
    return fsync(fd) == 0;
}
struct PublishedKey {
    bool created;
    struct stat identity;
    PublishedKey() : created(false), identity() {}
};
bool Publish(const std::string &state, const std::string &destination, const std::string &bytes,
             PublishedKey *published, Privileged::Error *error) {
    const std::string directory(state + "/keyrings");
    if (!Privileged::ValidateRootOwnedPath(state, true, false, error)) return false;
    if (mkdir(directory.c_str(), 0755) && errno != EEXIST) return Fail(error, "key_write_failed", "Cannot create the private public-key directory.");
    if (!Privileged::ValidateRootOwnedPath(directory, true, false, error) || destination != directory + '/' + Digest(bytes) + ".gpg") return false;
    const std::string leaf(destination.substr(directory.size() + 1));
    const int parent(open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (parent < 0) return false;
    struct stat st;
    if (fstatat(parent, leaf.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0) {
        close(parent); CydiaSources::ProtectedFileSnapshot existing;
        return CydiaSources::ReadProtectedFile(destination, &existing) && existing.identity.exists && existing.bytes == bytes ? true :
            Fail(error, "key_destination_exists", "An existing keyring will not be replaced.");
    }
    if (errno != ENOENT) { close(parent); return false; }
    std::string pattern(directory + "/.public-key.XXXXXX"); std::vector<char> name(pattern.begin(), pattern.end()); name.push_back(0);
    const int fd(mkstemp(name.data()));
    if (fd < 0) { close(parent); return false; }
    const bool written(fchown(fd, 0, 0) == 0 && fchmod(fd, 0644) == 0 && Write(fd, bytes) && fstat(fd, &published->identity) == 0);
    close(fd);
    // linkat publishes without replacing any existing regular file or alias.
    const std::string temporary(name.data()); const std::string temporaryLeaf(temporary.substr(directory.size() + 1));
    const bool linked(written && linkat(parent, temporaryLeaf.c_str(), parent, leaf.c_str(), 0) == 0);
    published->created = linked;
    unlinkat(parent, temporaryLeaf.c_str(), 0);
    const bool synced(linked && fsync(parent) == 0); close(parent);
    return synced || Fail(error, "key_write_failed", "Cannot publish the reviewed keyring without overwriting existing files.");
}
void RemoveUnreferenced(const Privileged::Environment &environment, const std::string &destination,
                        const PublishedKey &published) {
    if (!published.created) return;
    const auto sources(CydiaSources::ReadEffectiveDocuments({environment.sourceList, environment.sourceParts,
        environment.sourceReaderUID, environment.sourceReaderGID, environment.sourceReaderGroups}));
    if (!sources.ready()) return;
    for (const auto &source : sources.documents)
        if (source.document.bytes.find(destination) != std::string::npos) return;
    const std::size_t slash(destination.rfind('/'));
    const int parent(open(destination.substr(0, slash).c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (parent < 0) return;
    struct stat current;
    // The frontend lock serializes our source writers. Keep a file if another
    // actor replaced it or added a link; never remove a previously present key.
    if (fstatat(parent, destination.substr(slash + 1).c_str(), &current, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISREG(current.st_mode) && current.st_uid == 0 && current.st_nlink == 1 &&
        current.st_dev == published.identity.st_dev && current.st_ino == published.identity.st_ino &&
        current.st_size == published.identity.st_size && current.st_mtime == published.identity.st_mtime)
        if (unlinkat(parent, destination.substr(slash + 1).c_str(), 0) == 0) fsync(parent);
    close(parent);
}
bool PackageName(const std::string &package) {
    if (package.empty() || package.size() > 256 || (!(package[0] >= 'a' && package[0] <= 'z') && !(package[0] >= '0' && package[0] <= '9'))) return false;
    for (char c : package) if (!(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '+' && c != '-' && c != '.' && c != ':') return false;
    return true;
}
}

bool Prepare(const PackageDatabasePaths &paths, const Privileged::Environment &environment,
             const Input &input, Review *review, std::string *publicBytes, Privileged::Error *error) {
    if (!review || !publicBytes) return false;
    const std::string policyPath(paths.CydiaStateDirectory() + "/source-protection");
    const auto policy(CydiaSources::ReadProtectionPolicy(policyPath));
    if (!policy.valid || !policy.present || policy.bytes != input.source.expectedPolicy)
        return Fail(error, "key_source_review_required", "Review source protection in Advanced Settings before binding a key.");
    Privileged::Environment checked(environment); Privileged::Evidence verifier, policyEvidence;
    if (!Privileged::CapturePathIdentity(environment.gpg, false, true, &verifier, error))
        return Fail(error, "key_verifier_unavailable", "Configure a trusted GnuPG executable in Advanced Settings before importing keys.");
    if (!Privileged::CaptureEvidence(policyPath, false, false, &policyEvidence, error)) return false;
    checked.evidence.push_back(verifier); checked.evidence.push_back(policyEvidence);
    if (input.referencePackage.empty() != input.referencePath.empty())
        return Fail(error, "invalid_key_request", "Select a complete installed keyring reference.");
    if (!input.referencePath.empty()) {
        std::string bytes;
        if (!ReadPackageKey(checked, input.referencePackage, input.referencePath, &bytes, error) || bytes != input.bytes)
            return Fail(error, "key_package_ownership_changed", "The installed keyring changed. Review its current key again.");
        // APT distinguishes the supported armored and binary keyring formats
        // by suffix. Other package files remain importable as copied keys.
        const std::string suffix(input.referencePath.size() >= 4 ? input.referencePath.substr(input.referencePath.size() - 4) : "");
        if (suffix != ".gpg" && suffix != ".asc")
            return Fail(error, "invalid_key_reference", "Reference a package-owned .gpg or .asc keyring, or import a copy.");
        const std::size_t first(bytes.find_first_not_of(" \t\r\n"));
        const bool armored(first != std::string::npos && bytes[first] == '-');
        if ((suffix == ".asc") != armored)
            return Fail(error, "invalid_key_reference", "The installed keyring format does not match its APT filename extension. Import a copy instead.");
        Privileged::Evidence key;
        if (!Privileged::CaptureEvidence(input.referencePath, false, false, &key, error) || key.bytes != input.bytes) return false;
        checked.evidence.push_back(key);
    }
    if (!Privileged::ValidateRootOwnedPath(paths.CydiaStateDirectory(), true, false, error) ||
        !VerifyPublicKey(checked.gpg, paths.CydiaStateDirectory(), input.bytes, publicBytes, &review->fingerprints, error)) return false;
    review->destination = input.referencePath.empty() ? paths.CydiaStateDirectory() + "/keyrings/" + Digest(*publicBytes) + ".gpg" : input.referencePath;
    if (!BindSourceSignedBy(input.source, review->destination, &review->source, error)) return false;
    const auto plan(CydiaSources::PlanStoredMutation({environment.sourceList, environment.sourceParts,
        environment.sourceReaderUID, environment.sourceReaderGID, environment.sourceReaderGroups}, review->source.expected,
        review->source.mutation, policy.selectors, review->source.access));
    if (!plan.ready()) return Fail(error, "stale_key_source", "The selected source changed. Review the key and source again.");
    std::vector<CydiaSources::Document> documents;
    for (const auto &stored : plan.fresh.documents) documents.push_back(stored.document);
    if (review->source.mutation.kind == CydiaSources::EditKind::ReplaceDefinition &&
        CydiaSources::EvaluateProtection(documents, policy.selectors, review->source.expected.document.path,
        review->source.mutation.ordinal).state == CydiaSources::ProtectionState::ReviewRequired)
        return Fail(error, "key_source_review_required", "Review stale source protection in Advanced Settings before binding another key.");
    std::string snapshot;
    if (!Privileged::RuntimeSnapshot(checked, &snapshot, error)) return false;
    review->token = Digest(Privileged::SerializeFields({input.bytes, *publicBytes,
        CydiaSources::SerializeCommitRequest(review->source), snapshot, input.referencePackage, input.referencePath}));
    return Privileged::RecheckEvidence(checked.evidence, error);
}
bool Apply(const PackageDatabasePaths &paths, const Privileged::Environment &environment,
           const Input &input, Privileged::Error *error) {
    if (input.token.empty()) return Fail(error, "key_review_required", "A native fingerprint and source review is required.");
    Review review; std::string bytes;
    if (!Prepare(paths, environment, input, &review, &bytes, error)) return false;
    if (input.token != review.token || input.source.mutation.contents != review.source.mutation.contents)
        return Fail(error, "stale_key_review", "The key, verifier, configuration or source changed. Review the import again.");
    if (!Privileged::RecheckEvidence(environment.evidence, error)) return false;
    PublishedKey published;
    if (input.referencePath.empty() && !Publish(paths.CydiaStateDirectory(), review.destination, bytes, &published, error)) {
        RemoveUnreferenced(environment, review.destination, published); return false;
    }
    const CydiaSources::EffectiveLocations locations(environment.sourceList, environment.sourceParts,
        environment.sourceReaderUID, environment.sourceReaderGID, environment.sourceReaderGroups);
    const auto result(review.source.access == CydiaSources::Access::AdvancedSettings ?
        CydiaSources::CommitSourceRequestWithProtectionRefresh(locations, paths.CydiaStateDirectory() + "/source-protection", review.source) :
        CydiaSources::CommitSourceRequest(locations, paths.CydiaStateDirectory() + "/source-protection", review.source));
    if (result.status == CydiaSources::CommitStatus::SourceAppliedPolicyReviewRequired)
        return Fail(error, "key_source_policy_review_required", "The key was bound to the source, but its protection references need Advanced review before further source edits.");
    if (!result.succeeded()) RemoveUnreferenced(environment, review.destination, published);
    return result.succeeded() || Fail(error, "key_source_commit_failed", "The source binding was not committed. Review the source again.");
}
bool PackageKeys(const Privileged::Environment &environment, const std::string &package,
                 std::vector<std::string> *files, Privileged::Error *error) {
    if (!files || !PackageName(package)) return Fail(error, "invalid_key_package", "Invalid package identity.");
    std::string output; Dpkg::Runner query(environment.dpkgQuery);
    if (!query.RunAndCapture({"--admindir=" + environment.dpkgAdmin, "--listfiles", "--", package}, &output, 4 * 1024 * 1024).succeeded())
        return Fail(error, "key_package_unavailable", "Cannot read the package file manifest.");
    files->clear(); std::istringstream lines(output); std::string path;
    while (std::getline(lines, path)) {
        if (path.empty() || path[0] != '/' || path.find('\r') != std::string::npos || path.find('\0') != std::string::npos) continue;
        bool suffix(false); for (const char *ending : {".gpg", ".asc", ".pgp", ".key", ".pub"}) {
            const std::string value(ending); if (path.size() >= value.size() && path.compare(path.size() - value.size(), value.size(), value) == 0) suffix = true;
        }
        if (!suffix) continue;
        if (environment.dpkgRoot != "/") path = environment.dpkgRoot + path;
        Privileged::Error ignored;
        if (!Privileged::ValidateRootOwnedPath(path, false, false, &ignored)) continue;
        struct stat st; if (lstat(path.c_str(), &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || static_cast<std::size_t>(st.st_size) > MaximumKeyBytes) continue;
        files->push_back(path); if (files->size() > 256) return Fail(error, "key_package_too_large", "Too many candidate key files in this package.");
    }
    std::sort(files->begin(), files->end()); files->erase(std::unique(files->begin(), files->end()), files->end());
    return Privileged::RecheckEvidence(environment.evidence, error);
}
bool ReadPackageKey(const Privileged::Environment &environment, const std::string &package,
                    const std::string &path, std::string *bytes, Privileged::Error *error) {
    std::vector<std::string> files;
    if (!PackageKeys(environment, package, &files, error) || std::find(files.begin(), files.end(), path) == files.end())
        return Fail(error, "key_package_ownership_changed", "The selected file is no longer a package-owned key candidate.");
    Privileged::Evidence key;
    if (!Privileged::CaptureEvidence(path, false, false, &key, error) || key.bytes.size() > MaximumKeyBytes ||
        !CheckPublicKeyPackets(key.bytes, NULL, error) || !Privileged::RecheckEvidence({key}, error)) return false;
    *bytes = key.bytes; return true;
}
} }
