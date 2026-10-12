/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>

using namespace CydiaRuntime::Privileged;
namespace {
/* Ownership authorization is tested by PrivilegedRuntimeTests. This reader
 * isolates snapshot coverage from the host bootstrap and requires real file
 * identity, exact contents, absent leaves and directory membership. */
bool FixtureCapture(const std::string &path, bool directory, bool allowAbsent, Evidence *input, Error *) {
    *input = Evidence(); input->path = path; input->directory = directory;
    if (lstat(path.c_str(), &input->identity) != 0) {
        input->absent = errno == ENOENT;
        return input->absent && allowAbsent;
    }
    if (directory) {
        if (!S_ISDIR(input->identity.st_mode)) return false;
        DIR *stream = opendir(path.c_str()); if (stream == NULL) return false;
        while (struct dirent *entry = readdir(stream))
            if (std::strcmp(entry->d_name, ".") && std::strcmp(entry->d_name, "..")) input->entries.push_back(entry->d_name);
        closedir(stream); std::sort(input->entries.begin(), input->entries.end()); return true;
    }
    if (!S_ISREG(input->identity.st_mode)) return false;
    std::ifstream file(path, std::ios::binary);
    input->bytes.assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
    return file.good() || file.eof();
}
void Write(const std::string &path, const std::string &bytes) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); assert(file.good()); file << bytes;
    file.close(); assert(file.good());
}
std::vector<Evidence> Capture(const Environment &environment, SnapshotScope scope) {
    std::vector<Evidence> inputs; Error error;
    const bool captured(CaptureSnapshotInputs(environment, scope, &inputs, &error, FixtureCapture, FixtureCapture, FixtureCapture));
    if (!captured) std::cerr << error.code << ": " << error.message << '\n';
    assert(captured); return inputs;
}
std::string Frame(const std::vector<Evidence> &inputs) {
    std::string frame; for (const auto &input : inputs) frame += SerializeSnapshotEvidence(input); return frame;
}
const Evidence *Find(const std::vector<Evidence> &inputs, const std::string &path) {
    const auto found = std::find_if(inputs.begin(), inputs.end(), [&](const Evidence &input) { return input.path == path; });
    return found == inputs.end() ? NULL : &*found;
}
}
int main() {
    char pattern[] = "/tmp/cydia-snapshot-XXXXXX";
    const char *created = mkdtemp(pattern); assert(created != NULL); const std::string root(created);
    for (const char *directory : {"admin", "admin/updates", "sources", "pins", "keys", "scoped"})
        assert(std::filesystem::create_directory(root + '/' + directory));
    Environment environment;
    environment.dpkgAdmin = root + "/admin";
    environment.extendedStates = root + "/extended_states";
    environment.sourceList = root + "/sources.list";
    environment.sourceParts = root + "/sources";
    environment.preferences = root + "/preferences";
    environment.preferencesParts = root + "/pins";
    environment.trusted = root + "/trusted.gpg";
    environment.trustedParts = root + "/keys";
    const std::string scopedA = root + "/scoped/a.gpg", scopedB = root + "/scoped/b.asc";
    const std::string absent = root + "/scoped/missing.gpg";
    Write(environment.dpkgAdmin + "/status", "Package: sample\nStatus: install ok installed\n\n");
    Write(environment.dpkgAdmin + "/updates/0000", "Package: pending\nStatus: install ok unpacked\n\n");
    Write(environment.extendedStates, "Package: sample\nAuto-Installed: 1\n\n");
    Write(environment.sourceList, "deb [signed-by=" + scopedA + ',' + scopedB + ",0123456789012345678901234567890123456789] https://repo.invalid stable main\n"
        "# deb [signed-by=/missing-disabled-parent/unused.gpg] https://disabled.invalid stable main\n");
    Write(root + "/sources/native.sources", "Types: deb\nURIs: https://native.invalid\nSuites: stable\nComponents: main\nSigned-By: " + scopedA + "\n " + absent + "\n 0123456789012345678901234567890123456789!\n\n"
        "Types: deb\nURIs: https://embedded.invalid\nSuites: stable\nComponents: main\nSigned-By:\n -----BEGIN PGP PUBLIC KEY BLOCK-----\n .\n /embedded-armour-is-not-a-file\n -----END PGP PUBLIC KEY BLOCK-----\n\n");
    Write(environment.preferences, "Package: sample\nPin: version 1\nPin-Priority: 1001\n");
    Write(root + "/pins/plain", "Package: retained\nPin-Priority: 1\n");
    Write(root + "/pins/architecture:arm64.pref", "Package: architecture\nPin-Priority: 50\n");
    Write(root + "/pins/ignored.bak", "unused");
    Write(environment.trusted, "legacy-public-key");
    Write(root + "/keys/global.gpg", "global-public-key");
    Write(root + "/keys/.hidden.asc", "hidden-public-key");
    Write(root + "/keys/ignored.txt", "unused");
    Write(scopedA, "scoped-public-key-a"); Write(scopedB, "scoped-public-key-b");
    Write(root + "/apt.conf", "Dir::Etc::trustedparts \"keys\";\n");
    Evidence config; assert(FixtureCapture(root + "/apt.conf", false, false, &config, NULL));
    environment.evidence.push_back(config);
    auto state = Capture(environment, SnapshotScope::PackageState);
    auto trust = Capture(environment, SnapshotScope::RepositoryTrust);
    const std::string architecturePath(environment.dpkgAdmin + "/arch");
    assert(Find(state, architecturePath)->absent && Find(state, architecturePath)->adminAccess);
    assert(!Find(state, architecturePath)->sharedState && !Find(trust, architecturePath));
    // Adding, editing or deleting dpkg registration invalidates a reviewed
    // package plan, without pretending that repository authentication changed.
    const std::string withoutArchitecture(Frame(state)), architectureTrust(Frame(trust));
    Write(architecturePath, "amd64\ni386\n");
    const auto registered(Capture(environment, SnapshotScope::PackageState));
    assert(Frame(registered) != withoutArchitecture);
    assert(Find(registered, architecturePath)->bytes == "amd64\ni386\n");
    assert(Frame(Capture(environment, SnapshotScope::RepositoryTrust)) == architectureTrust);
    Write(architecturePath, "amd64\narm64\n");
    const std::string changedArchitecture(Frame(Capture(environment, SnapshotScope::PackageState)));
    assert(changedArchitecture != Frame(registered));
    std::filesystem::remove(architecturePath);
    assert(Frame(Capture(environment, SnapshotScope::PackageState)) != changedArchitecture);
    assert(Find(Capture(environment, SnapshotScope::PackageState), architecturePath)->absent);
    assert(Frame(Capture(environment, SnapshotScope::RepositoryTrust)) == architectureTrust);
    assert(Find(state, environment.dpkgAdmin + "/status")->sharedState && Find(state, environment.extendedStates)->sharedState);
    assert(Find(state, environment.preferences)->sharedState && Find(state, root + "/pins/plain")->sharedState);
    assert(!Find(state, environment.trusted)->sharedState && !Find(state, scopedA)->sharedState &&
           !Find(state, root + "/apt.conf")->sharedState && !Find(state, environment.preferencesParts)->sharedState);
    const auto savedTrusted(environment.trusted);
    environment.trusted = environment.preferences;
    assert(!Find(Capture(environment, SnapshotScope::PackageState), environment.preferences)->sharedState);
    environment.trusted = savedTrusted;
    const auto savedParts(environment.trustedParts);
    environment.trustedParts = environment.preferencesParts;
    Write(root + "/pins/overlap.asc", "trusted-key-in-shared-parts");
    assert(!Find(Capture(environment, SnapshotScope::PackageState), root + "/pins/overlap.asc")->sharedState);
    environment.trustedParts = savedParts;
    assert(Find(state, environment.preferences) && Find(state, root + "/pins/plain") && Find(state, root + "/pins/architecture:arm64.pref"));
    assert(!Find(state, root + "/pins/ignored.bak") && !Find(state, root + "/keys/ignored.txt"));
    assert(Find(trust, root + "/keys/.hidden.asc") && Find(trust, scopedA) && Find(trust, scopedB));
    assert(Find(trust, absent) && Find(trust, absent)->absent);
    assert(!Find(trust, environment.dpkgAdmin + "/status") && !Find(trust, environment.extendedStates) && !Find(trust, environment.preferences));
    assert(!Find(trust, "/embedded-armour-is-not-a-file") && !Find(trust, "/missing-disabled-parent/unused.gpg"));
    assert(std::count_if(trust.begin(), trust.end(), [&](const Evidence &input) { return input.path == scopedA; }) == 1);
    const std::string originalTrust = Frame(trust), originalState = Frame(state);
    Write(environment.preferences, "Package: sample\nPin: version 2\nPin-Priority: 1001\n");
    assert(Frame(Capture(environment, SnapshotScope::PackageState)) != originalState);
    assert(Frame(Capture(environment, SnapshotScope::RepositoryTrust)) == originalTrust);
    Write(root + "/keys/global.gpg", "revoked-or-replaced-key");
    assert(Frame(Capture(environment, SnapshotScope::RepositoryTrust)) != originalTrust);
    trust = Capture(environment, SnapshotScope::RepositoryTrust);
    Write(absent, "new-scoped-public-key");
    assert(Frame(Capture(environment, SnapshotScope::RepositoryTrust)) != Frame(trust));
    trust = Capture(environment, SnapshotScope::RepositoryTrust);
    std::filesystem::rename(scopedA, scopedA + ".old"); Write(scopedA, "scoped-public-key-a");
    assert(Frame(Capture(environment, SnapshotScope::RepositoryTrust)) != Frame(trust));
    trust = Capture(environment, SnapshotScope::RepositoryTrust);
    std::filesystem::rename(root + "/keys/global.gpg", root + "/keys/renamed.gpg");
    assert(Frame(Capture(environment, SnapshotScope::RepositoryTrust)) != Frame(trust));
    std::filesystem::remove(scopedB);
    assert(Find(Capture(environment, SnapshotScope::RepositoryTrust), scopedB)->absent);
    // Both absent main files and absent optional parts directories are inputs.
    environment.preferences = root + "/missing-preferences";
    environment.trusted = root + "/missing-global.gpg";
    environment.preferencesParts = root + "/missing-pins";
    environment.trustedParts = root + "/missing-keys";
    state = Capture(environment, SnapshotScope::PackageState);
    assert(Find(state, environment.preferences)->absent && Find(state, environment.trusted)->absent);
    assert(Find(state, environment.preferencesParts)->absent && Find(state, environment.trustedParts)->absent);
    // Root/admin identities remain protected without volatile lock timestamps.
    Evidence identity; assert(FixtureCapture(environment.dpkgAdmin, true, false, &identity, NULL)); identity.identityOnly = true;
    const std::string before(SerializeSnapshotEvidence(identity));
    ++identity.identity.st_size;
#ifdef __APPLE__
    ++identity.identity.st_mtimespec.tv_nsec; ++identity.identity.st_ctimespec.tv_nsec;
#else
    ++identity.identity.st_mtim.tv_nsec; ++identity.identity.st_ctim.tv_nsec;
#endif
    assert(SerializeSnapshotEvidence(identity) == before);
    ++identity.identity.st_ino; assert(SerializeSnapshotEvidence(identity) != before);
    // A mutable input must still be read if another resolver identity covers it.
    assert(FixtureCapture(environment.dpkgAdmin, true, false, &identity, NULL)); identity.identityOnly = true;
    environment.evidence.push_back(identity); environment.trustedParts = environment.dpkgAdmin;
    Write(environment.dpkgAdmin + "/admin-key.gpg", "public-key");
    assert(Find(Capture(environment, SnapshotScope::RepositoryTrust), environment.dpkgAdmin + "/admin-key.gpg"));
    Error error; std::vector<Evidence> rejected;
    assert(!CaptureSnapshotInputs(environment, SnapshotScope::PackageState, &rejected, &error));
    std::filesystem::remove_all(root);
    std::cout << "Configured pin/global/scoped key content, identity, membership and absence snapshots passed\n";
}
