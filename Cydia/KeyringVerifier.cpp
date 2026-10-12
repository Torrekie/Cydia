/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/KeyringVerifier.hpp"
#include "Cydia/KeyringImport.hpp"
#include "Cydia/DpkgRunner.h"
#include <algorithm>
#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
namespace CydiaRuntime { namespace Keyring {
namespace {
bool Fail(Privileged::Error *error, const char *code, const char *message) {
    if (error) { error->code = code; error->message = message; } return false;
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
/* Only the fresh private temporary directory is recursively cleaned. Symlink
 * entries are unlinked, never followed; no caller-controlled path is used. */
void Clean(int directory, unsigned depth = 0) {
    if (depth > 8) return;
    const int duplicate(dup(directory)); DIR *entries(duplicate < 0 ? NULL : fdopendir(duplicate));
    if (!entries) { if (duplicate >= 0) close(duplicate); return; }
    while (const auto entry = readdir(entries)) {
        const std::string leaf(entry->d_name); if (leaf == "." || leaf == "..") continue;
        struct stat st; if (fstatat(directory, leaf.c_str(), &st, AT_SYMLINK_NOFOLLOW)) continue;
        if (S_ISDIR(st.st_mode)) {
            const int child(openat(directory, leaf.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
            if (child >= 0) { Clean(child, depth + 1); close(child); }
            unlinkat(directory, leaf.c_str(), AT_REMOVEDIR);
        } else unlinkat(directory, leaf.c_str(), 0);
    }
    closedir(entries);
}
class TemporaryHome {
    std::string path_;
  public:
    ~TemporaryHome() { if (!path_.empty()) { int fd(open(path_.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
        if (fd >= 0) { Clean(fd); close(fd); } rmdir(path_.c_str()); } }
    bool Create(const std::string &state, Privileged::Error *error) {
        std::string pattern(state + "/.key-review.XXXXXX"); std::vector<char> name(pattern.begin(), pattern.end()); name.push_back(0);
        if (!mkdtemp(name.data())) return Fail(error, "key_staging_failed", "Cannot create private key review staging.");
        path_ = name.data();
        return chmod(path_.c_str(), 0700) == 0;
    }
    const std::string &path() const { return path_; }
    bool Input(const std::string &leaf, const std::string &bytes) {
        const int fd(open((path_ + '/' + leaf).c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
        if (fd < 0) return false;
        const bool success(Write(fd, bytes));
        close(fd);
        return success;
    }
};
bool HexIdentity(const std::string &value, bool allowLongID = false) {
    if (value.size() != 40 && value.size() != 64 && !(allowLongID && value.size() == 16)) return false;
    for (char c : value) if (!(c >= '0' && c <= '9') && !(c >= 'A' && c <= 'F')) return false;
    return true;
}
void AddIdentity(std::vector<std::string> *identities, const std::string &value) {
    if (std::find(identities->begin(), identities->end(), value) == identities->end()) identities->push_back(value);
}
} // namespace

bool VerifyPublicKey(const std::string &verifierPath, const std::string &state, const std::string &bytes,
               std::string *normalized, std::vector<std::string> *fingerprints, Privileged::Error *error,
               const VerificationLimits &limits) {
    std::size_t rawCount(0), normalizedCount(0);
    if (!CheckPublicKeyPackets(bytes, &rawCount, error)) return false;
    if (!normalized || !fingerprints || verifierPath.empty() || verifierPath[0] != '/' || state.empty() || state[0] != '/' ||
        verifierPath.find('\0') != std::string::npos || state.find('\0') != std::string::npos)
        return Fail(error, "key_verifier_unavailable", "Invalid public-key verifier or staging location.");
    TemporaryHome home; if (!home.Create(state, error) || !home.Input("input.key", bytes)) return false;
    // GnuPG's documented import-export mode normalizes without adding trust
    // to an existing key database. No options, keyserver, agent or user home.
    const std::vector<std::string> common{"--no-options", "--homedir", home.path(), "--batch", "--no-tty", "--no-autostart",
        "--no-auto-key-retrieve", "--auto-key-locate", "clear"};
    std::vector<std::string> args(common);
    args.insert(args.end(), {"--import-options", "import-export,import-clean", "--output", "-", "--import", home.path() + "/input.key"});
    Dpkg::Runner verifier(verifierPath);
    if (!verifier.RunAndCaptureBounded(args, normalized, MaximumKeyBytes, limits.timeoutMilliseconds, limits.cancelled).succeeded() || normalized->empty() ||
        !CheckPublicKeyPackets(*normalized, &normalizedCount, error) || normalizedCount != rawCount)
        return Fail(error, "key_verification_failed", "GnuPG could not normalize every supplied public key.");
    if (!home.Input("public.gpg", *normalized)) return Fail(error, "key_staging_failed", "Cannot stage the normalized public key.");
    args = common;
    args.insert(args.end(), {"--fixed-list-mode", "--with-colons", "--with-fingerprint", "--show-keys", home.path() + "/public.gpg"});
    std::string listing;
    if (!verifier.RunAndCaptureBounded(args, &listing, MaximumKeyBytes, limits.timeoutMilliseconds, limits.cancelled).succeeded() || !ReadFingerprints(listing, fingerprints, error) ||
        fingerprints->size() != normalizedCount) return Fail(error, "key_verification_failed", "GnuPG did not return usable primary fingerprints.");
    return true;
}

bool ReadRepositorySignatureStatus(const std::string &status, bool verifierSucceeded,
    RepositorySignatureReview *review, Privileged::Error *error) {
    if (!review) return false;
    *review = RepositorySignatureReview();
    if (status.size() > MaximumKeyBytes || status.find('\0') != std::string::npos)
        return Fail(error, "repository_verifier_failed", "The signing-key verifier returned invalid status data.");
    bool bad(false), expired(false), revoked(false), unsupported(false), failed(false), missing(false), good(false);
    std::vector<std::string> hintedLongIDs;
    std::istringstream lines(status); std::string line;
    std::size_t records(0);
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.compare(0, 9, "[GNUPG:] ") != 0) continue;
        if (++records > 16384) return Fail(error, "repository_verifier_failed", "Too many signature status records.");
        std::istringstream words(line.substr(9)); std::vector<std::string> fields; std::string field;
        while (words >> field) fields.push_back(field);
        if (fields.empty()) continue;
        const std::string &kind(fields[0]);
        if (kind == "BADSIG" || kind == "NODATA" || kind == "BADARMOR") bad = true;
        else if (kind == "EXPSIG" || kind == "EXPKEYSIG") expired = true;
        else if (kind == "REVKEYSIG") revoked = true;
        else if (kind == "FAILURE" || kind == "ERROR") failed = true;
        else if (kind == "NO_PUBKEY") {
            if (fields.size() < 2 || !HexIdentity(fields[1], true)) failed = true;
            else { missing = true; AddIdentity(&hintedLongIDs, fields[1]); }
        } else if (kind == "ERRSIG") {
            // GnuPG doc/DETAILS: keyid, pkalgo, hashalgo, class, time,
            // return code, and an optional full issuer fingerprint (2.2.7+).
            if (fields.size() < 7 || !HexIdentity(fields[1], true)) { failed = true; continue; }
            if (fields[6] == "4") unsupported = true;
            else if (fields[6] == "9") {
                missing = true;
                if (fields.size() >= 8 && fields[7] != "-") {
                    if (HexIdentity(fields[7])) AddIdentity(&review->missingKeyIdentifiers, fields[7]);
                    else failed = true;
                } else AddIdentity(&hintedLongIDs, fields[1]);
            } else failed = true;
        } else if (kind == "VALIDSIG") {
            if (fields.size() < 10 || !HexIdentity(fields[1]) ||
                (fields[9] != "00" && fields[9] != "01") ||
                (fields.size() >= 11 && !HexIdentity(fields[10]))) { failed = true; continue; }
            AddIdentity(&review->signerFingerprints, fields[1]);
            AddIdentity(&review->primaryFingerprints, fields.size() >= 11 ? fields[10] : fields[1]);
        } else if (kind == "GOODSIG") good = true;
    }
    for (const auto &identifier : hintedLongIDs) {
        bool represented(false);
        for (const auto &full : review->missingKeyIdentifiers)
            if (full.size() >= identifier.size() && full.compare(full.size() - identifier.size(), identifier.size(), identifier) == 0) represented = true;
        if (!represented) AddIdentity(&review->missingKeyIdentifiers, identifier);
    }
    if (review->signerFingerprints.size() > 16 || review->primaryFingerprints.size() > 16 || review->missingKeyIdentifiers.size() > 16) failed = true;
    RepositorySignatureStatus result(RepositorySignatureStatus::VerifierError);
    if (revoked) result = RepositorySignatureStatus::Revoked;
    else if (expired) result = RepositorySignatureStatus::Expired;
    else if (bad) result = RepositorySignatureStatus::BadSignature;
    else if (unsupported) result = RepositorySignatureStatus::UnsupportedAlgorithm;
    else if (!failed && good && !review->signerFingerprints.empty() && (verifierSucceeded || missing)) result = RepositorySignatureStatus::Valid;
    else if (!failed && missing) result = RepositorySignatureStatus::MissingKey;
    review->status = result;
    switch (result) {
        case RepositorySignatureStatus::Valid: return true;
        case RepositorySignatureStatus::MissingKey: return Fail(error, "repository_key_missing", "The repository signing key is not available in the supplied keyring.");
        case RepositorySignatureStatus::Expired: return Fail(error, "repository_signature_expired", "The repository signature or signing key has expired.");
        case RepositorySignatureStatus::Revoked: return Fail(error, "repository_key_revoked", "The repository signing key has been revoked.");
        case RepositorySignatureStatus::BadSignature: return Fail(error, "repository_signature_invalid", "The repository signature does not verify.");
        case RepositorySignatureStatus::UnsupportedAlgorithm: return Fail(error, "repository_signature_unsupported", "The configured verifier does not support the repository signature algorithm.");
        default: return Fail(error, "repository_verifier_failed", "The configured verifier could not check the repository signature.");
    }
}

bool VerifyRepositorySignature(const std::string &verifierPath, const std::string &state,
    const std::string &publicKeyBytes, const std::string &metadataBytes,
    const std::string &detachedSignature, RepositorySignatureReview *review, Privileged::Error *error,
    const VerificationLimits &limits) {
    if (!review) return false;
    *review = RepositorySignatureReview();
    if (metadataBytes.empty() || metadataBytes.size() > 4 * 1024 * 1024 || detachedSignature.size() > MaximumKeyBytes ||
        verifierPath.empty() || verifierPath[0] != '/' || verifierPath.find('\0') != std::string::npos ||
        state.empty() || state[0] != '/' || state.find('\0') != std::string::npos)
        return Fail(error, "repository_verifier_failed", "Invalid repository metadata, verifier or staging location.");
    if (!publicKeyBytes.empty() && !CheckPublicKeyPackets(publicKeyBytes, NULL, error)) return false;
    TemporaryHome home;
    if (!home.Create(state, error) || !home.Input("Release", metadataBytes)) return false;
    const std::vector<std::string> common{"--no-options", "--homedir", home.path(), "--batch", "--no-tty", "--no-autostart",
        "--no-auto-key-retrieve", "--auto-key-locate", "clear", "--no-default-keyring", "--keyring", home.path() + "/candidate.gpg"};
    Dpkg::Runner verifier(verifierPath);
    if (!publicKeyBytes.empty()) {
        if (!home.Input("input.key", publicKeyBytes)) return Fail(error, "key_staging_failed", "Cannot stage the candidate public key.");
        std::vector<std::string> args(common); args.insert(args.end(), {"--import", home.path() + "/input.key"});
        std::string output;
        // Import only into this isolated temporary keyring; expired/revoked
        // candidates remain inspectable so their signature state is explicit.
        if (!verifier.RunAndCaptureBounded(args, &output, MaximumKeyBytes, limits.timeoutMilliseconds, limits.cancelled).succeeded())
            return Fail(error, "key_verification_failed", "The configured verifier could not read the candidate public key.");
    }
    std::vector<std::string> args(common); args.insert(args.end(), {"--status-fd", "1", "--verify"});
    if (!detachedSignature.empty()) {
        if (!home.Input("Release.gpg", detachedSignature)) return Fail(error, "key_staging_failed", "Cannot stage the repository signature.");
        args.push_back(home.path() + "/Release.gpg");
    }
    args.push_back(home.path() + "/Release");
    std::string status;
    const auto result(verifier.RunAndCaptureBounded(args, &status, MaximumKeyBytes, limits.timeoutMilliseconds, limits.cancelled));
    if (result.kind != Dpkg::ResultKind::Exited)
        return Fail(error, "repository_verifier_failed", "The configured signature verifier could not run.");
    return ReadRepositorySignatureStatus(status, result.succeeded(), review, error);
}
} }
