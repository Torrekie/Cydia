/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/KeyringVerifier.hpp"
#include "Cydia/KeyringImport.hpp"
#include "Cydia/DpkgRunner.h"
#include <cstdlib>
#include <filesystem>
#include <iostream>
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
};
}
int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') { std::cerr << "usage: key-verifier-tests /absolute/path/to/gpg\n"; return 2; }
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
    const std::string trustBefore(listing);
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
    Expect(fixture.run({"--fixed-list-mode", "--with-colons", "--with-fingerprint", "--list-keys"}, &listing) && listing == trustBefore,
        "import review never changes the original key database");
    for (const auto &entry : std::filesystem::directory_iterator(fixture.root))
        Expect(entry.path().filename() == "original", "temporary review homes are removed after success and failure");
    std::cout << "[key-verifier] PASS: real GnuPG normalization and private/corrupt-key rejection\n";
}
