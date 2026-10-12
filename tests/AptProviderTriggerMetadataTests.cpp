/* Native protected declaration paths, isolated under fakeroot; no dpkg child.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEffects.hpp"
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
    std::cerr << "[apt-provider-trigger-metadata] " << message << '\n'; std::exit(1);
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file << bytes; file.close();
    Require(file.good() && chmod(path.c_str(), mode) == 0, "write isolated fixture");
}
struct Fixture {
    std::string root, info, triggers;
    R::Environment environment; P::TriggerCaptureLock lock;
    Fixture() {
        std::string pattern(std::filesystem::current_path().string() + "/cydia-trigger-metadata.XXXXXX");
        std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
        const char *created = mkdtemp(name.data()); Require(created != NULL, "create isolated fixture"); root = created;
        environment.dpkgAdmin = root + "/admin"; info = environment.dpkgAdmin + "/info";
        triggers = environment.dpkgAdmin + "/triggers";
        Require(std::filesystem::create_directories(info) && std::filesystem::create_directory(triggers), "create native admin layout");
        Write(environment.dpkgAdmin + "/status", "Package: cache\nVersion: 1\nArchitecture: amd64\nStatus: install ok installed\n"
            "Multi-Arch: same\nDepends: libc:any (>= 1),\n helper | alternative\n\n");
        Write(environment.dpkgAdmin + "/lock-frontend", "", 0600);
        Write(triggers + "/Lock", "", 0600); Write(triggers + "/cache-refresh", "cache:amd64\n");
        Write(info + "/cache.triggers", "interest-await cache-refresh\n");
        lock.descriptor = open((environment.dpkgAdmin + "/lock-frontend").c_str(), O_RDWR);
        struct flock request = {}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
        Require(lock.descriptor >= 3 && fcntl(lock.descriptor, F_SETLK, &request) == 0, "hold genuine frontend lock");
    }
    ~Fixture() { if (lock.descriptor >= 0) close(lock.descriptor); std::filesystem::remove_all(root); }
    P::DpkgState State(bool pending = false) {
        std::string identity, error; R::Error failure;
        Require(R::RuntimeSnapshot(environment, &identity, &failure), "capture same protected package snapshot");
        P::DpkgState result;
        Require(P::ParseDpkgState(std::string("cache\t1\tamd64\tinstall ok ") +
            (pending ? "triggers-pending\tsame\tcache-refresh\t\n" : "installed\tsame\t\t\n"),
            "amd64\n", "", identity, &result, &error), "fixture protected query view");
        return result;
    }
};
void NativeFormatAndEvidence() {
    Fixture fixture; P::InstalledTriggerMetadata metadata; P::TriggerEffectCheckpoint point; std::string error;
    auto state = fixture.State();
    Require(P::CaptureInstalledTriggerMetadata(fixture.environment, state, fixture.lock, &metadata, &error) &&
        metadata.packages.size() == 1 && metadata.packages.at("cache:amd64").declarations.size() == 1 &&
        metadata.packages.at("cache:amd64").controls.at("depends") == "libc:any (>= 1), helper | alternative",
        "missing info/format uses legacy bare filename even for Multi-Arch same");
    Require(P::CaptureTriggerEffectCheckpoint(fixture.environment, state, fixture.lock, &point, &error) &&
        !point.identity.empty(), "production registry/control/status join under real locks");
    const auto identity = point.identity;
    Write(fixture.info + "/cache.triggers", "# retained comment\ninterest-await cache-refresh\n");
    Require(P::CaptureTriggerEffectCheckpoint(fixture.environment, fixture.State(), fixture.lock, &point, &error) &&
        identity != point.identity, "exact declaration bytes bind even when semantic interests stay equal");
    Write(fixture.info + "/format", "1\n");
    Require(!P::CaptureInstalledTriggerMetadata(fixture.environment, fixture.State(), fixture.lock, &metadata, &error),
        "format one never silently uses obsolete bare Multi-Arch control");
    Require(rename((fixture.info + "/cache.triggers").c_str(), (fixture.info + "/cache:amd64.triggers").c_str()) == 0, "move native control fixture");
    Require(P::CaptureInstalledTriggerMetadata(fixture.environment, fixture.State(), fixture.lock, &metadata, &error),
        "format one selects exact qualified Multi-Arch filename");
    Write(fixture.info + "/cache.triggers", "interest-await cache-refresh\n");
    Require(!P::CaptureInstalledTriggerMetadata(fixture.environment, fixture.State(), fixture.lock, &metadata, &error) &&
        error == "provider_trigger_control_ambiguous", "conflicting native control candidates refused");
    Require(unlink((fixture.info + "/cache.triggers").c_str()) == 0, "remove ambiguous fixture leaf");
    Write(fixture.info + "/format-new", "1\n");
    Require(!P::CaptureInstalledTriggerMetadata(fixture.environment, fixture.State(), fixture.lock, &metadata, &error),
        "interrupted native metadata migration cannot grant authority");
}
void DeferredAndUnsafe() {
    Fixture fixture; P::TriggerEffectCheckpoint point; P::InstalledTriggerMetadata metadata; std::string error;
    // The disk status remains installed while dpkg-query's read-only view has
    // incorporated this queue. Capture must preserve rather than mutate it.
    Write(fixture.triggers + "/Unincorp", "cache-refresh -\n");
    auto state = fixture.State(true);
    Require(P::CaptureTriggerEffectCheckpoint(fixture.environment, state, fixture.lock, &point, &error) &&
        point.registry.state.deferred.size() == 1 && point.packages.packages.at("cache:amd64").triggersPending.size() == 1,
        "query incorporation and original disk status coexist in the same checkpoint");
    std::ifstream queue(fixture.triggers + "/Unincorp"); std::string bytes{std::istreambuf_iterator<char>(queue), std::istreambuf_iterator<char>()};
    Require(bytes == "cache-refresh -\n", "capture never incorporates or truncates the native queue");
    const auto valid = state;
    Write(fixture.environment.dpkgAdmin + "/status", "Package: cache\nVersion: 2\nArchitecture: amd64\nStatus: install ok installed\nMulti-Arch: same\n\n");
    Require(!P::CaptureInstalledTriggerMetadata(fixture.environment, valid, fixture.lock, &metadata, &error), "stale query snapshot rejected");
    Fixture unsafe;
    Require(chmod((unsafe.info + "/cache.triggers").c_str(), 0666) == 0 &&
        !P::CaptureInstalledTriggerMetadata(unsafe.environment, unsafe.State(), unsafe.lock, &metadata, &error), "writable installed declarations refused");
    Require(chmod((unsafe.info + "/cache.triggers").c_str(), 0644) == 0, "restore protected declaration");
    P::TriggerCaptureLock noLock;
    Require(!P::CaptureInstalledTriggerMetadata(unsafe.environment, unsafe.State(), noLock, &metadata, &error) &&
        error == "provider_frontend_lock_missing", "caller assertion without retained lock is not authority");
    Require(!P::CaptureInstalledTriggerMetadata(unsafe.environment, unsafe.State(), unsafe.lock, &metadata, &error, [] { return true; }) &&
        metadata.packages.empty(), "cancel leaves no partial metadata authority");
}
}
int main() {
    Require(geteuid() == 0, "run only isolated protected fixtures under fakeroot");
    alarm(20); NativeFormatAndEvidence(); DeferredAndUnsafe(); alarm(0);
    std::cout << "apt-provider-trigger-metadata tests passed\n";
}
