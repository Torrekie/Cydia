/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryTrust.hpp"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sys/stat.h>
#include <unistd.h>
namespace {
namespace R = CydiaAPT::Recovery;
void Require(bool value, const char *message) {
    if (value) return;
    std::fprintf(stderr, "[apt-recovery-trust] %s\n", message); std::exit(1);
}
void Write(const std::string &path, const std::string &bytes) {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc); stream << bytes; stream.close();
    Require(stream.good() && chmod(path.c_str(), 0644) == 0, "write isolated trust input");
}
struct Fixture {
    std::string root; R::Snapshot snapshot;
    Fixture() {
        char cwd[4096]; Require(getcwd(cwd, sizeof(cwd)), "fixture cwd");
        const auto pattern(std::string(cwd) + "/cydia-recovery-trust.XXXXXX");
        std::vector<char> bytes(pattern.begin(), pattern.end()); bytes.push_back('\0');
        Require(mkdtemp(bytes.data()) != nullptr, "temporary fixture directory"); root = bytes.data();
        for (const char *name : {"parts", "keys", "lists"}) Require(mkdir((root + '/' + name).c_str(), 0755) == 0, "fixture subdirectory");
        snapshot.identity.configuration = std::string(64, 'a'); snapshot.identity.policy = std::string(64, 'b');
        snapshot.identity.methods = snapshot.identity.libraries = snapshot.identity.frontend = std::string(64, 'c');
        snapshot.runtime.sourceListPath = root + "/sources.list"; snapshot.runtime.sourcePartsDirectory = root + "/parts";
        snapshot.runtime.trustedKeyringPath = root + "/trusted.gpg"; snapshot.runtime.trustedKeyringPartsDirectory = root + "/keys";
        snapshot.runtime.listsDirectory = root + "/lists";
        Write(root + "/sources.list", "deb [signed-by=" + root + "/scoped.gpg] https://repo.example/ ./\n");
        Write(root + "/trusted.gpg", "trust-one"); Write(root + "/scoped.gpg", "scoped-one");
        Write(root + "/lists/Packages", "Package: sample\nVersion: 1\nArchitecture: all\n\n");
    }
    ~Fixture() {
        for (const char *name : {"sources.list", "trusted.gpg", "scoped.gpg", "lists/Packages"}) unlink((root + '/' + name).c_str());
        for (const char *name : {"parts", "keys", "lists"}) rmdir((root + '/' + name).c_str());
        rmdir(root.c_str());
    }
};
}
int main() {
    // Run under the existing protected native fixture's root/fakeroot context.
    Fixture fixture; R::WorkerTrustProof proof; const std::function<bool()> running = []() { return false; };
    Require(!proof.Matches(fixture.snapshot, running), "cache opening alone does not establish trust");
    auto before(proof.BeginRefresh(fixture.snapshot, running));
    Require(!before.empty() && proof.CompleteRefresh(fixture.snapshot, before, true, running), "complete refresh establishes proof");
    Require(proof.Matches(fixture.snapshot, running) && proof.Matches(fixture.snapshot, running),
        "unchanged proof survives Reset/OpenCache-style rechecks");
    Write(fixture.root + "/scoped.gpg", "scoped-two");
    Require(!proof.Matches(fixture.snapshot, running), "per-source Signed-By key change invalidates proof");
    before = proof.BeginRefresh(fixture.snapshot, running);
    Require(proof.CompleteRefresh(fixture.snapshot, before, true, running), "new completed refresh renews proof");
    Write(fixture.root + "/lists/Packages", "Package: replacement\nVersion: 2\nArchitecture: all\n\n");
    Require(!proof.Matches(fixture.snapshot, running), "index change invalidates proof");
    before = proof.BeginRefresh(fixture.snapshot, running);
    Write(fixture.root + "/sources.list", "deb https://changed.example/ ./\n");
    Require(!proof.CompleteRefresh(fixture.snapshot, before, true, running), "source change during refresh denies proof");
    before = proof.BeginRefresh(fixture.snapshot, running);
    Require(!proof.CompleteRefresh(fixture.snapshot, before, false, running) && !proof.Matches(fixture.snapshot, running),
        "failed or partial refresh cannot renew proof");
    before = proof.BeginRefresh(fixture.snapshot, running);
    Require(proof.CompleteRefresh(fixture.snapshot, before, true, running), "complete refresh recovers proof");
    const std::function<bool()> cancelled = []() { return true; };
    Require(!proof.Matches(fixture.snapshot, cancelled), "cancelled reader cannot assert trust");
    std::puts("Recovery session trust proof tests passed.");
}
