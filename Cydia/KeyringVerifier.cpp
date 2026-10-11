/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/KeyringVerifier.hpp"
#include "Cydia/KeyringImport.hpp"
#include "Cydia/DpkgRunner.h"
#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
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
} // namespace

bool VerifyPublicKey(const std::string &verifierPath, const std::string &state, const std::string &bytes,
               std::string *normalized, std::vector<std::string> *fingerprints, Privileged::Error *error) {
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
    if (!verifier.RunAndCapture(args, normalized, MaximumKeyBytes).succeeded() || normalized->empty() ||
        !CheckPublicKeyPackets(*normalized, &normalizedCount, error) || normalizedCount != rawCount)
        return Fail(error, "key_verification_failed", "GnuPG could not normalize every supplied public key.");
    if (!home.Input("public.gpg", *normalized)) return Fail(error, "key_staging_failed", "Cannot stage the normalized public key.");
    args = common;
    args.insert(args.end(), {"--fixed-list-mode", "--with-colons", "--with-fingerprint", "--show-keys", home.path() + "/public.gpg"});
    std::string listing;
    if (!verifier.RunAndCapture(args, &listing, MaximumKeyBytes).succeeded() || !ReadFingerprints(listing, fingerprints, error) ||
        fingerprints->size() != normalizedCount) return Fail(error, "key_verification_failed", "GnuPG did not return usable primary fingerprints.");
    return true;
}
} }
