/* Protected script evidence in disposable native fixtures; no dpkg child.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderInstalledScripts.hpp"
#include "Cydia/RuntimeState.hpp"
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <fcntl.h>
#include <unistd.h>

namespace {
namespace P = CydiaAPT::Provider;
namespace R = CydiaRuntime::Privileged;
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[apt-provider-installed-scripts] " << message << '\n'; std::exit(1);
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file << bytes; file.close();
    Require(file.good() && chmod(path.c_str(), mode) == 0, "write isolated fixture");
}
struct Fixture {
    std::string root, info;
    R::Environment environment; P::TriggerCaptureLock lock;
    const P::ExecutionPackage alpha = {"alpha", "2", "amd64"}, beta = {"beta", "5", "all"};
    Fixture() {
        std::string pattern(std::filesystem::current_path().string() + "/cydia-installed-scripts.XXXXXX");
        std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
        const char *created = mkdtemp(name.data()); Require(created != NULL, "create isolated fixture"); root = created;
        environment.dpkgAdmin = root + "/admin"; info = environment.dpkgAdmin + "/info";
        Require(std::filesystem::create_directories(info), "create native info directory");
        Status("1"); Write(environment.dpkgAdmin + "/lock-frontend", "", 0600);
        lock.descriptor = open((environment.dpkgAdmin + "/lock-frontend").c_str(), O_RDWR);
        struct flock request = {}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
        Require(lock.descriptor >= 3 && fcntl(lock.descriptor, F_SETLK, &request) == 0, "retain genuine frontend lock");
    }
    ~Fixture() { if (lock.descriptor >= 0) close(lock.descriptor); std::filesystem::remove_all(root); }
    void Status(const std::string &configured) {
        Write(environment.dpkgAdmin + "/status", "Package: alpha\nVersion: 2\nArchitecture: amd64\n"
            "Status: install ok unpacked\nMulti-Arch: same\n" +
            (configured.empty() ? "" : "Config-Version: " + configured + "\n") +
            "\nPackage: beta\nVersion: 5\nArchitecture: all\nStatus: install ok installed\n\n");
    }
    P::DpkgState State() {
        std::string identity, error; R::Error failure;
        Require(R::RuntimeSnapshot(environment, &identity, &failure), "capture protected package snapshot");
        P::DpkgState result;
        Require(P::ParseDpkgState("alpha\t2\tamd64\tinstall ok unpacked\tsame\t\t\n"
            "beta\t5\tall\tinstall ok installed\t\t\t\n", "amd64\n", "", identity, &result, &error), "fixture exact native state");
        return result;
    }
    bool Capture(P::InstalledScriptMetadata *out, std::string *error) {
        return P::CaptureInstalledScripts(environment, State(), lock, {alpha}, out, error);
    }
};
void NativeNamesAndAbsence() {
    Fixture fixture; P::InstalledScriptMetadata captured; std::string error;
    Write(fixture.info + "/alpha.prerm", "#!/bin/sh\nexit 0\n", 0755);
    Write(fixture.info + "/beta.postinst", "unselected", 0666);
    Require(fixture.Capture(&captured, &error) && captured.packages.size() == 1 && captured.files.size() == 8,
        "capture reads only explicitly selected scripts, ignoring unsafe unrelated script");
    const auto first = captured.packages.at("alpha:amd64");
    Require(first.package.version == "2" && first.configVersion == "1" && !first.prerm.absent &&
        first.diskStatus == P::DpkgPackageStatus::Unpacked &&
        first.prerm.bytes == "#!/bin/sh\nexit 0\n" && (first.prerm.identity.st_mode & 07777) == 0755 &&
        first.postinst.absent && first.postinst.path == fixture.info + "/alpha.postinst",
        "exact protected bytes, native bare paths, mode, absence and last-configured version retained");
    Require(chmod((fixture.info + "/beta.postinst").c_str(), 0755) == 0, "restore selected all-package script");
    Require(P::CaptureInstalledScripts(fixture.environment, fixture.State(), fixture.lock, {fixture.beta, fixture.alpha}, &captured, &error) &&
        captured.packages.at("beta:all").package.architecture == "all" && captured.packages.at("beta:all").configVersion == "5",
        "explicit all package keeps exact native identity");
    const auto canonical = captured.evidenceIdentity;
    Require(P::CaptureInstalledScripts(fixture.environment, fixture.State(), fixture.lock, {fixture.alpha, fixture.beta}, &captured, &error) &&
        captured.evidenceIdentity == canonical, "selected subset identity is independent of caller order");
    Write(fixture.info + "/alpha.postinst", "", 0755);
    Require(fixture.Capture(&captured, &error) && !captured.packages.at("alpha:amd64").postinst.absent &&
        captured.packages.at("alpha:amd64").evidenceIdentity != first.evidenceIdentity, "empty present script differs from absent script");
    const auto present = captured.packages.at("alpha:amd64").evidenceIdentity;
    Require(chmod((fixture.info + "/alpha.postinst").c_str(), 0700) == 0 && fixture.Capture(&captured, &error) &&
        captured.packages.at("alpha:amd64").evidenceIdentity != present, "protected script mode is identity-bound");
    Write(fixture.info + "/format", "1\n");
    Require(!fixture.Capture(&captured, &error) && captured.packages.empty(), "format one cannot consume obsolete bare Multi-Arch scripts");
    for (const char *name : {"prerm", "postinst"})
        Require(rename((fixture.info + "/alpha." + name).c_str(), (fixture.info + "/alpha:amd64." + name).c_str()) == 0, "qualify native files");
    Require(fixture.Capture(&captured, &error) && captured.packages.at("alpha:amd64").prerm.path == fixture.info + "/alpha:amd64.prerm",
        "format one selects exact native architecture-qualified scripts");
    Write(fixture.info + "/alpha.prerm", "", 0755);
    Require(!fixture.Capture(&captured, &error) && error == "provider_installed_scripts_ambiguous", "dual candidates refuse");
    Require(unlink((fixture.info + "/alpha.prerm").c_str()) == 0, "remove ambiguous fixture");
    Write(fixture.info + "/format-new", "1\n");
    Require(!fixture.Capture(&captured, &error), "native format migration refuses");
}
void ExactSelectionAndConsistency() {
    Fixture fixture; P::InstalledScriptMetadata captured; std::string error;
    auto state = fixture.State();
    Require(!P::CaptureInstalledScripts(fixture.environment, state, fixture.lock, {{"alpha", "1", "amd64"}}, &captured, &error), "old version target refuses");
    Require(!P::CaptureInstalledScripts(fixture.environment, state, fixture.lock, {{"beta", "5", "amd64"}}, &captured, &error), "all is not replaced with native architecture");
    Require(!P::CaptureInstalledScripts(fixture.environment, state, fixture.lock, {fixture.alpha, fixture.alpha}, &captured, &error), "duplicate target refuses");
    P::TriggerCaptureLock missing;
    Require(!P::CaptureInstalledScripts(fixture.environment, state, missing, {fixture.alpha}, &captured, &error), "real frontend lock required");
    Require(!P::CaptureInstalledScripts(fixture.environment, state, fixture.lock, {fixture.alpha}, &captured, &error,
        [] { return true; }) && captured.files.empty(), "cancelled capture never publishes partial proof");
    Require(fixture.Capture(&captured, &error), "initial metadata capture"); const auto initial = captured.evidenceIdentity;
    fixture.Status("0");
    Require(!P::CaptureInstalledScripts(fixture.environment, state, fixture.lock, {fixture.alpha}, &captured, &error), "changed protected state rejects old query");
    Require(fixture.Capture(&captured, &error) && captured.evidenceIdentity != initial && captured.packages.at("alpha:amd64").configVersion == "0",
        "retained configured version independently changes selected evidence");
    state = fixture.State(); unsigned reads = 0;
    Require(!P::CaptureInstalledScripts(fixture.environment, state, fixture.lock, {fixture.alpha}, &captured, &error, {},
        [&](std::string *value, std::string *) { *value = state.packageStateIdentity;
            if (++reads == 2) Write(fixture.info + "/alpha.postinst", "changed between snapshots", 0755);
            return true; }) &&
        captured.packages.empty(), "newly present script during capture rejects even if package snapshot token is unchanged");
    captured.evidenceIdentity = "discard";
    Require(P::CaptureInstalledScripts({}, {}, {}, {}, &captured, &error) && captured.packages.empty() &&
        captured.files.empty() && captured.evidenceIdentity.empty(), "default empty selection performs no capture or authority expansion");
}
void UnsafeScriptFiles() {
    Fixture fixture; P::InstalledScriptMetadata captured; std::string error;
    const std::string path = fixture.info + "/alpha.prerm";
    Write(path, "#!/bin/sh\n", 0777);
    Require(!fixture.Capture(&captured, &error), "writable script refuses");
    Require(chmod(path.c_str(), 0755) == 0 && link(path.c_str(), (fixture.info + "/shared").c_str()) == 0, "make hardlink fixture");
    Require(!fixture.Capture(&captured, &error), "multiply-linked script refuses");
    Require(unlink(path.c_str()) == 0 && symlink("shared", path.c_str()) == 0, "make symlink fixture");
    Require(!fixture.Capture(&captured, &error), "script symlink does not stand in for exact native leaf metadata");
    Require(unlink(path.c_str()) == 0, "remove symlink fixture");
    Write(path, std::string(P::MaximumInstalledScriptBytes + 1, 'x'), 0755);
    Require(!fixture.Capture(&captured, &error) && captured.packages.empty(), "bounded script content limit refuses before publication");
}
}
int main() {
    Require(geteuid() == 0, "run only isolated protected fixtures under fakeroot");
    alarm(20); NativeNamesAndAbsence(); ExactSelectionAndConsistency(); UnsafeScriptFiles(); alarm(0);
    std::cout << "apt-provider-installed-scripts tests passed\n";
}
