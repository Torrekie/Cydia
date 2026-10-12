/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/KeyringVerifier.hpp"
#include "Cydia/KeyringImport.hpp"
#include "Cydia/DpkgRunner.h"
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <utility>
#include <sys/stat.h>
#include <unistd.h>

using namespace CydiaRuntime;
namespace {
void Expect(bool value, const char *message) { if (!value) { std::cerr << "[key-verifier] FAIL: " << message << '\n'; std::exit(1); } }
struct Fixture {
    std::string root, home, verifier;
    explicit Fixture(const std::string &tool) : verifier(tool) {
        char name[] = "/tmp/cydia-key-verifier-XXXXXX"; const char *path(mkdtemp(name));
        Expect(path != nullptr, "private fixture root"); root = path; home = root + "/original";
        Expect(mkdir(home.c_str(), 0700) == 0, "private signing fixture home");
    }
    ~Fixture() {
        const std::string configuration(verifier.substr(0, verifier.rfind('/') + 1) + "gpgconf");
        if (access(configuration.c_str(), X_OK) == 0) Dpkg::Runner(configuration).Run({"--homedir", home, "--kill", "gpg-agent"});
        std::error_code error; std::filesystem::remove_all(root, error);
    }
    bool run(const std::vector<std::string> &arguments, std::string *output = nullptr) {
        std::vector<std::string> options{"--no-options", "--homedir", home, "--batch", "--no-tty"};
        options.insert(options.end(), arguments.begin(), arguments.end());
        Dpkg::Runner runner(verifier);
        return output ? runner.RunAndCapture(options, output, Keyring::MaximumKeyBytes).succeeded() : runner.Run(options).succeeded();
    }
    std::vector<std::string> databaseContents() const {
        std::vector<std::string> contents;
        for (const char *leaf : {"pubring.kbx", "trustdb.gpg"}) {
            std::ifstream file(home + '/' + leaf, std::ios::binary);
            Expect(file.is_open(), "read the original key and trust databases");
            contents.emplace_back(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
        }
        return contents;
    }
};
void StatusRecords() {
    using Keyring::RepositorySignatureStatus;
    const std::string fingerprint(40, 'A'), subkey(40, 'B');
    const std::string valid("[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG " + fingerprint.substr(24) + " Display label\n"
        "[GNUPG:] VALIDSIG " + subkey + " 2026-01-01 1767225600 0 4 0 22 10 00 " + fingerprint + "\n");
    Keyring::RepositorySignatureReview review; Privileged::Error error;
    Expect(Keyring::ReadRepositorySignatureStatus(valid, true, &review, &error) && review.primaryFingerprints[0] == fingerprint &&
        review.signerFingerprints[0] == subkey, "preserve primary identity separately from signing subkey");
    for (const auto &pair : {std::make_pair("EXPSIG", RepositorySignatureStatus::Expired),
            std::make_pair("EXPKEYSIG", RepositorySignatureStatus::Expired), std::make_pair("REVKEYSIG", RepositorySignatureStatus::Revoked),
            std::make_pair("BADSIG", RepositorySignatureStatus::BadSignature)}) {
        Expect(!Keyring::ReadRepositorySignatureStatus(valid + "[GNUPG:] " + pair.first + " ABCDEF0123456789 Label\n", true, &review, &error) &&
            review.status == pair.second, "cryptographic VALIDSIG never masks expired, revoked or invalid signature status");
    }
    const std::string missing("[GNUPG:] ERRSIG " + fingerprint.substr(24) + " 22 10 00 1767225600 9 " + fingerprint + "\n"
        "[GNUPG:] NO_PUBKEY " + fingerprint.substr(24) + "\n");
    Expect(!Keyring::ReadRepositorySignatureStatus(missing, false, &review, &error) && review.status == RepositorySignatureStatus::MissingKey &&
        review.missingKeyIdentifiers == std::vector<std::string>{fingerprint}, "prefer full issuer fingerprint over duplicate long key ID hint");
    Expect(!Keyring::ReadRepositorySignatureStatus("[GNUPG:] ERRSIG ABCDEF0123456789 99 10 00 1767225600 4 -\n", false, &review, &error) &&
        review.status == RepositorySignatureStatus::UnsupportedAlgorithm, "unsupported verifier algorithm is distinct from unavailable keys");
    Expect(!Keyring::ReadRepositorySignatureStatus("[GNUPG:] GOODSIG ABCDEF0123456789 Fake identity\n", true, &review, &error),
        "GOODSIG without verified fingerprint is insufficient");
    Expect(!Keyring::ReadRepositorySignatureStatus("[GNUPG:] VALIDSIG not-a-fingerprint\n", true, &review, &error), "malformed status fails closed");
    Expect(!Keyring::ReadRepositorySignatureStatus(valid, false, &review, &error), "unexplained failed verifier cannot authorize a key");
}
}
int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') { std::cerr << "usage: key-verifier-tests /absolute/path/to/gpg\n"; return 2; }
    StatusRecords();
    Fixture fixture(argv[1]);
    Expect(fixture.run({"--pinentry-mode", "loopback", "--passphrase", "", "--quick-generate-key",
        "Cydia fixture <fixture@example.invalid>", "ed25519", "sign", "0"}), "generate an isolated signing fixture");
    std::string listing, binary, armored, secret;
    Expect(fixture.run({"--fixed-list-mode", "--with-colons", "--with-fingerprint", "--list-keys"}, &listing), "obtain original primary fingerprint");
    std::vector<std::string> expected; Privileged::Error error;
    Expect(Keyring::ReadFingerprints(listing, &expected, &error) && expected.size() == 1, "one usable fixture identity");
    Expect(fixture.run({"--export", expected[0]}, &binary), "export binary public key");
    Expect(fixture.run({"--armor", "--export", expected[0]}, &armored), "export armored public key");
    Expect(fixture.run({"--pinentry-mode", "loopback", "--passphrase", "", "--export-secret-keys", expected[0]}, &secret), "export secret fixture for rejection");
    const std::string metadata("Origin: Cydia test fixture\nSuite: stable\nArchitectures: arm64 all\nComponents: main\n");
    { std::ofstream file(fixture.home + "/Release", std::ios::binary); file << metadata; Expect(file.good(), "write metadata fixture"); }
    Expect(fixture.run({"--pinentry-mode", "loopback", "--passphrase", "", "--detach-sign", "--output", fixture.home + "/Release.gpg", fixture.home + "/Release"}),
        "sign detached repository metadata fixture");
    Expect(fixture.run({"--pinentry-mode", "loopback", "--passphrase", "", "--clearsign", "--output", fixture.home + "/InRelease", fixture.home + "/Release"}),
        "sign clearsigned repository metadata fixture");
    std::ifstream signatureFile(fixture.home + "/Release.gpg", std::ios::binary), inReleaseFile(fixture.home + "/InRelease", std::ios::binary);
    const std::string signature((std::istreambuf_iterator<char>(signatureFile)), std::istreambuf_iterator<char>());
    const std::string inRelease((std::istreambuf_iterator<char>(inReleaseFile)), std::istreambuf_iterator<char>());
    // Colon listings contain GnuPG trust-calculation metadata. Compare the
    // actual databases after fixture setup and before any review instead.
    const std::vector<std::string> trustBefore(fixture.databaseContents());
    for (const auto &input : {binary, armored}) {
        std::string normalized; std::vector<std::string> fingerprints;
        Expect(Keyring::VerifyPublicKey(fixture.verifier, fixture.root, input, &normalized, &fingerprints, &error), "real GnuPG normalizes binary and armored input");
        Expect(!normalized.empty() && fingerprints == expected && Keyring::CheckPublicKeyPackets(normalized, nullptr, &error), "normalization keeps the actual primary fingerprint and public-only output");
    }
    std::string normalized; std::vector<std::string> fingerprints;
    Expect(!Keyring::VerifyPublicKey("/nonexistent/verifier", fixture.root, secret, &normalized, &fingerprints, &error) && error.code == "private_key_rejected",
        "secret packets are rejected before executing any verifier");
    Expect(!Keyring::VerifyPublicKey(fixture.verifier, fixture.root, binary + secret, &normalized, &fingerprints, &error) && error.code == "private_key_rejected",
        "reject mixed public/secret export material");
    std::string corrupted(binary); corrupted.back() ^= 1;
    Expect(!Keyring::VerifyPublicKey(fixture.verifier, fixture.root, corrupted, &normalized, &fingerprints, &error),
        "real GnuPG rejects corrupted self-signature rather than trusting packet shape");
    Expect(!Keyring::VerifyPublicKey("/nonexistent/verifier", fixture.root, binary, &normalized, &fingerprints, &error), "missing verifier never silently trusts a key");
    Keyring::RepositorySignatureReview repository;
    Expect(Keyring::VerifyRepositorySignature(fixture.verifier, fixture.root, armored, metadata, signature, &repository, &error) &&
        repository.primaryFingerprints == expected, "candidate key verifies detached metadata using real GnuPG");
    Expect(Keyring::VerifyRepositorySignature(fixture.verifier, fixture.root, binary, inRelease, "", &repository, &error),
        "candidate key verifies clearsigned InRelease");
    Expect(!Keyring::VerifyRepositorySignature(fixture.verifier, fixture.root, binary, metadata + "Modified: yes\n", signature, &repository, &error) &&
        repository.status == Keyring::RepositorySignatureStatus::BadSignature, "modified metadata is an integrity failure");
    Expect(!Keyring::VerifyRepositorySignature(fixture.verifier, fixture.root, "", metadata, signature, &repository, &error) &&
        repository.status == Keyring::RepositorySignatureStatus::MissingKey && !repository.missingKeyIdentifiers.empty(),
        "empty isolated keyring reports lookup hints without consulting existing user keys");
    Expect(!Keyring::VerifyRepositorySignature(fixture.verifier, fixture.root, secret, metadata, signature, &repository, &error) &&
        error.code == "private_key_rejected", "repository verification also rejects secret material");
    Expect(fixture.databaseContents() == trustBefore,
        "import review never changes the original key database");
    Expect(fixture.run({"--fixed-list-mode", "--with-colons", "--with-fingerprint", "--list-keys"}, &listing) &&
        Keyring::ReadFingerprints(listing, &fingerprints, &error) && fingerprints == expected,
        "original usable signing identities remain unchanged");
    for (const auto &entry : std::filesystem::directory_iterator(fixture.root))
        Expect(entry.path().filename() == "original", "temporary review homes are removed after success and failure");
    std::cout << "[key-verifier] PASS: real GnuPG normalization and private/corrupt-key rejection\n";
}
