/* Protected fixtures run under fakeroot, never against the host database.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEvidence.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
namespace T = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[protected-trigger-evidence] " << message << '\n'; std::exit(1);
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file << bytes; file.close();
    Require(file.good() && chmod(path.c_str(), mode) == 0, "write isolated fixture");
}
std::string Read(const std::string &path) {
    std::ifstream file(path, std::ios::binary); Require(file.good(), "read isolated fixture");
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
struct Fixture {
    std::string root, triggers;
    CydiaRuntime::Privileged::Environment environment;
    Fixture() {
        std::string pattern(std::filesystem::current_path().string() + "/cydia-trigger-evidence.XXXXXX");
        std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
        const char *created = mkdtemp(name.data()); Require(created != nullptr, "create isolated fixture"); root = created;
        environment.dpkgAdmin = root + "/admin"; triggers = environment.dpkgAdmin + "/triggers";
        Require(std::filesystem::create_directories(environment.dpkgAdmin), "create selected admin directory");
        Write(environment.dpkgAdmin + "/status", "Package: cache\nArchitecture: iphoneos-arm64\nVersion: 1\nStatus: install ok installed\n\n");
    }
    ~Fixture() { std::filesystem::remove_all(root); }
    void Populate() {
        Require(std::filesystem::create_directory(triggers), "create trigger directory");
        Write(triggers + "/Lock", "", 0600);
        Write(triggers + "/File", "/usr/share/icons icons:all/noawait\n");
        Write(triggers + "/update-cache", "cache:iphoneos-arm64\ncache:iphoneos-arm/noawait\n");
        Write(triggers + "/Unincorp", "update-cache requester:all -\n");
    }
};
std::string Snapshot(const Fixture &fixture, CydiaRuntime::Privileged::SnapshotScope scope) {
    namespace P = CydiaRuntime::Privileged;
    std::vector<P::Evidence> inputs; P::Error error;
    Require(P::CaptureSnapshotInputs(fixture.environment, scope, &inputs, &error), "production runtime snapshot inputs");
    std::string result;
    for (const auto &input : inputs) result += P::SerializeSnapshotEvidence(input);
    return result;
}
void CaptureAndChanges() {
    Fixture fixture; T::ProtectedTriggerEvidence first, changed; std::string error;
    namespace P = CydiaRuntime::Privileged;
    const std::string absentSnapshot = Snapshot(fixture, P::SnapshotScope::PackageState);
    const std::string originalTrust = Snapshot(fixture, P::SnapshotScope::RepositoryTrust);
    Require(T::CaptureProtectedTriggerEvidence(fixture.environment, &first, &error) && !first.synchronized &&
        !first.state.directoryPresent && first.evidenceIdentity.size() == 64 &&
        !T::RecheckProtectedTriggerEvidence(fixture.environment, first, &error) &&
        error == "provider_trigger_evidence_unadmitted", "absent directory is observed without fabricating lock authority");
    fixture.Populate();
    const std::string populatedSnapshot = Snapshot(fixture, P::SnapshotScope::PackageState);
    Require(populatedSnapshot != absentSnapshot && Snapshot(fixture, P::SnapshotScope::RepositoryTrust) == originalTrust,
        "production package snapshots include native registries without changing repository authentication evidence");
    const std::string originalDeferred = Read(fixture.triggers + "/Unincorp");
    Require(T::CaptureProtectedTriggerEvidence(fixture.environment, &first, &error) && first.synchronized &&
        first.state.interests.size() == 3 && first.state.deferred.size() == 1 &&
        T::RecheckProtectedTriggerEvidence(fixture.environment, first, &error), "unchanged protected native evidence rechecks");
    Require(Read(fixture.triggers + "/Unincorp") == originalDeferred && Read(fixture.triggers + "/Lock").empty(),
        "capture does not incorporate, truncate or rewrite deferred state");
    Write(fixture.triggers + "/Unincorp", "# same meaning, different protected bytes\n" + originalDeferred);
    Require(T::CaptureProtectedTriggerEvidence(fixture.environment, &changed, &error) &&
        changed.state.canonicalIdentity == first.state.canonicalIdentity && changed.evidenceIdentity != first.evidenceIdentity &&
        !T::RecheckProtectedTriggerEvidence(fixture.environment, first, &error), "raw bytes bind even semantically identical queue edits");
    first = changed;
    Write(fixture.triggers + "/extra-trigger", "cache:iphoneos-arm64\n");
    Require(!T::RecheckProtectedTriggerEvidence(fixture.environment, first, &error), "directory membership changes invalidate proof");
    Require(unlink((fixture.triggers + "/extra-trigger").c_str()) == 0 &&
        T::CaptureProtectedTriggerEvidence(fixture.environment, &first, &error), "recapture after membership change");
    Require(chmod((fixture.triggers + "/File").c_str(), 0600) == 0 &&
        !T::RecheckProtectedTriggerEvidence(fixture.environment, first, &error), "numeric metadata participates in identity");
    Require(unlink((fixture.triggers + "/Lock").c_str()) == 0 &&
        T::CaptureProtectedTriggerEvidence(fixture.environment, &changed, &error) && !changed.synchronized &&
        !changed.state.lockPresent && !T::RecheckProtectedTriggerEvidence(fixture.environment, changed, &error),
        "missing Lock remains unadmitted and is never recreated");
    Require(access((fixture.triggers + "/Lock").c_str(), F_OK) != 0, "read-only capture leaves missing Lock absent");
    Require(!Snapshot(fixture, P::SnapshotScope::PackageState).empty(), "ordinary package snapshots do not require a native trigger lock");
    Write(fixture.triggers + "/Unincorp.new", "an interrupted native write");
    const std::string interruptedSnapshot = Snapshot(fixture, P::SnapshotScope::PackageState);
    Write(fixture.triggers + "/Unincorp.new", "changed interrupted bytes");
    Require(Snapshot(fixture, P::SnapshotScope::PackageState) != interruptedSnapshot &&
        Snapshot(fixture, P::SnapshotScope::RepositoryTrust) == originalTrust,
        "raw snapshots bind unfinished native files without semantically admitting effects");
}
void UnsafeAndBounded() {
    Fixture fixture; fixture.Populate(); T::ProtectedTriggerEvidence evidence; std::string error;
    Require(chmod((fixture.triggers + "/File").c_str(), 0664) == 0 &&
        !T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error), "group-writable registry rejected");
    Require(chmod((fixture.triggers + "/File").c_str(), 0644) == 0, "restore protected fixture");
    const std::string alias = fixture.triggers + "/alias";
    Require(symlink("File", alias.c_str()) == 0 &&
        !T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error) && unlink(alias.c_str()) == 0,
        "registry symlink rejected");
    Require(link((fixture.triggers + "/File").c_str(), alias.c_str()) == 0 &&
        !T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error) && unlink(alias.c_str()) == 0,
        "hardlinked registry rejected");
    Require(mkfifo(alias.c_str(), 0600) == 0 &&
        !T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error) && unlink(alias.c_str()) == 0,
        "nonregular leaf rejected without opening a blocking stream");
    Write(fixture.triggers + "/Unincorp.new", "");
    Require(!T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error) &&
        error == "provider_trigger_registry_unsupported" && unlink((fixture.triggers + "/Unincorp.new").c_str()) == 0,
        "unfinished native journal is not mistaken for a named trigger");
    const int large = open((fixture.triggers + "/Unincorp").c_str(), O_WRONLY | O_TRUNC);
    Require(large >= 0 && ftruncate(large, T::MaximumDeferredTriggerBytes + 1) == 0, "create oversized sparse deferred fixture");
    close(large);
    Require(!T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error) &&
        error == "provider_trigger_evidence_limit" && evidence.evidenceIdentity.empty(), "oversized file rejected before reading it");
    Write(fixture.triggers + "/Unincorp", "");
    Require(!T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error, [] { return true; }) &&
        error == "provider_trigger_capture_cancelled" && evidence.files.empty(), "cancellation leaves no partial proof");
}
void LockAndRelease() {
    Fixture fixture; fixture.Populate(); std::string error; T::ProtectedTriggerEvidence evidence;
    int ready[2], release[2]; Require(pipe(ready) == 0 && pipe(release) == 0, "create fixture synchronization pipes");
    const pid_t child = fork(); Require(child >= 0, "fork native lock holder");
    if (child == 0) {
        close(ready[0]); close(release[1]);
        const int lock = open((fixture.triggers + "/Lock").c_str(), O_RDWR);
        struct flock request = {}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
        char result = lock >= 0 && fcntl(lock, F_SETLK, &request) == 0 ? '1' : '0';
        if (write(ready[1], &result, 1) != 1) _exit(2);
        char stop; if (read(release[0], &stop, 1) != 1) _exit(3);
        if (lock >= 0) close(lock); _exit(0);
    }
    close(ready[1]); close(release[0]); char result = '0';
    Require(read(ready[0], &result, 1) == 1 && result == '1', "child owns real POSIX trigger write lock"); close(ready[0]);
    const auto started = std::chrono::steady_clock::now();
    Require(!T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error, {}, 25) &&
        error == "provider_trigger_capture_timeout" &&
        std::chrono::steady_clock::now() - started < std::chrono::seconds(2), "contended native lock has bounded deadline");
    unsigned calls = 0;
    Require(!T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error, [&] { return ++calls > 1; }) &&
        error == "provider_trigger_capture_cancelled", "waiting for native lock is cancellable");
    Require(write(release[1], "x", 1) == 1, "release child lock"); close(release[1]);
    int status = 0; Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "lock-holder fixture settled");
    Require(T::CaptureProtectedTriggerEvidence(fixture.environment, &evidence, &error), "capture succeeds after writer exits");
    // A child would conflict with any read lock leaked by the parent capture.
    const pid_t probe = fork(); Require(probe >= 0, "fork lock-release probe");
    if (probe == 0) {
        const int lock = open((fixture.triggers + "/Lock").c_str(), O_RDWR);
        struct flock request = {}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
        const bool acquired = lock >= 0 && fcntl(lock, F_SETLK, &request) == 0;
        if (lock >= 0) close(lock); _exit(acquired ? 0 : 4);
    }
    Require(waitpid(probe, &status, 0) == probe && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "native lock released before returning to caller");
}
}
int main() {
    Require(geteuid() == 0, "run isolated protected fixtures through fakeroot");
    alarm(20); CaptureAndChanges(); UnsafeAndBounded(); LockAndRelease(); alarm(0);
    std::cout << "protected-trigger-evidence tests passed\n";
}
