/* Real protected files, parent lock and bounded query children under fakeroot.
 * Only the Darwin native declaration/loader producers are fixture symbols;
 * their actual Mach-O implementation has separate NativeDpkgAuthority tests.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerCapture.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptProviderComponentCapture.hpp"
#include "Cydia/RuntimeState.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
namespace A = CydiaAPT::Provider;
namespace P = CydiaRuntime::Privileged;
A::NativeDpkgAuthority authority;
bool available = true;
unsigned closures = 0;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[trigger-capture] " << message << '\n'; std::exit(1); }
}
std::string Hash(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM); Require(hash.Add(bytes.data(), bytes.size()), "hash fixture");
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file << bytes; file.close();
    Require(file.good() && chmod(path.c_str(), mode) == 0, "write fixture");
}
std::string Read(const std::string &path) {
    std::ifstream file(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
std::string Quote(const std::string &value) {
    std::string result("'"); for (char byte : value) result += byte == '\'' ? "'\\''" : std::string(1, byte);
    return result + "'";
}
}
namespace CydiaAPT { namespace Provider {
bool ResolveNativeDpkgAuthority(const CydiaRuntime::PackageDatabasePaths &, const BrokerEnvironment &,
    const ReviewedTransaction &, NativeDpkgAuthority *result, std::string *error, const std::function<bool()> &) {
    if (!available) { if (error) *error = "provider_native_configuration_missing"; return false; }
    *result = authority; return true;
}
bool RevalidateNativeDpkgAuthority(const NativeDpkgAuthority &value,
    const std::vector<InstalledComponentEvidence> &files, std::string *error) {
    P::Error ignored;
    if (!P::RecheckEvidence(value.configurationEvidence, &ignored)) {
        if (error) *error = "provider_native_configuration_changed"; return false;
    }
    for (const auto &file : files) {
        const auto expected = value.executorGenerations.find(file.file.metadata.path);
        if (expected == value.executorGenerations.end() || !expected->second.count(file.file.sha256)) return false;
    }
    return true;
}
bool CaptureNativeDpkgClosure(const NativeDpkgAuthority &value, const std::string &path,
    const std::vector<InstalledComponentEvidence> &files, ComponentClosureEvidence *proof,
    std::string *error, const std::function<bool()> &cancelled) {
    ++closures;
    if ((cancelled && cancelled()) || !RevalidateNativeDpkgAuthority(value, files, error)) return false;
    for (const auto &file : files) if (file.file.metadata.path == path) {
        InstalledComponentEvidence fresh;
        if (!CaptureTransactionComponent(path, &fresh, error, cancelled) || !SameInstalledComponent(file, fresh)) return false;
        *proof = ComponentClosureEvidence(); proof->executable = path;
        proof->nativeConfigurationIdentity = value.configurationIdentity; proof->platformIdentity = value.platformIdentity;
        ComponentClosureNode node; node.file = fresh; proof->nodes.push_back(node); return true;
    }
    return false;
}
}}
namespace {
struct Fixture {
    std::string root, configuration, calls, deferred;
    A::BrokerEnvironment selected;
    int lock = -1;
    explicit Fixture(unsigned variant) {
        std::string pattern = std::filesystem::current_path().string() + "/trigger-capture.XXXXXX";
        std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
        const char *created = mkdtemp(name.data()); Require(created, "private fixture directory"); root = created;
        auto &environment = selected.environment; environment.dpkgAdmin = root + "/admin"; environment.dpkgRoot = "/";
        environment.dpkg = root + "/dpkg"; environment.dpkgQuery = root + "/dpkg-query";
        environment.extendedStates = root + "/extended_states";
        std::filesystem::create_directories(environment.dpkgAdmin + "/triggers");
        std::filesystem::create_directory(environment.dpkgAdmin + "/info");
        selected.runtime.architecture = "amd64"; selected.runtime.registeredArchitectures = {"amd64"};
        selected.runtime.binding.providerIdentifier = "fixture-provider";
        selected.runtime.binding.configurationIdentity = "configuration"; selected.runtime.binding.policyIdentity = "policy";
        selected.executableSearchPath = "/usr/bin:/bin";
        configuration = root + "/native.conf"; calls = root + "/queries";
        deferred = environment.dpkgAdmin + "/triggers/Unincorp";
        Write(configuration, "native graph\n"); Write(calls, ""); Write(environment.extendedStates, "");
        Write(environment.dpkgAdmin + "/status", "Package: cache\nVersion: 1\nArchitecture: amd64\nStatus: install ok installed\n\n");
        Write(environment.dpkgAdmin + "/info/cache.triggers", "interest-await cache-refresh\n");
        Write(environment.dpkgAdmin + "/triggers/cache-refresh", variant == 5 ? "unknown:any\n" : "cache\n");
        Write(deferred, "cache-refresh -\n"); Write(environment.dpkgAdmin + "/triggers/Lock", "", 0600);
        Write(environment.dpkgAdmin + "/lock-frontend", "", 0600);
        std::string manager = "#!/bin/sh\nprintf 'query\\n' >> " + Quote(calls) + "\n";
        if (variant == 2) manager += "printf 'changed\\n' > " + Quote(configuration) + "\n";
        if (variant == 3) manager += "printf 'other-trigger -\\n' > " + Quote(deferred) + "\n";
        manager += "for value do case $value in --print-architecture) printf 'amd64\\n';; esac; done\n";
        const std::string query = "#!/bin/sh\nprintf 'query\\n' >> " + Quote(calls) +
            "\nprintf 'cache\\t1\\tamd64\\tinstall ok triggers-pending\\tno\\tcache-refresh\\t\\n'\n";
        Write(environment.dpkg, manager, 0755); Write(environment.dpkgQuery, query, 0755);
        authority = A::NativeDpkgAuthority(); authority.configurationIdentity = Hash("native-config");
        authority.platformIdentity = Hash("fixture-platform");
        P::Evidence evidence; P::Error failure;
        Require(P::CaptureEvidence(configuration, false, false, &evidence, &failure), "capture protected configuration");
        authority.configurationEvidence.push_back(evidence);
        authority.componentPaths = {environment.dpkg, environment.dpkgQuery};
        authority.executorGenerations[environment.dpkg] = {Hash(manager)};
        authority.executorGenerations[environment.dpkgQuery] = {Hash(query)};
        available = true; closures = 0;
        if (variant != 1) {
            lock = open((environment.dpkgAdmin + "/lock-frontend").c_str(), O_RDWR);
            struct flock request{}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
            Require(lock >= 3 && fcntl(lock, F_SETLK, &request) == 0, "parent owns actual native frontend lock");
        }
    }
    ~Fixture() { if (lock >= 0) close(lock); std::filesystem::remove_all(root); }
};
void Run(unsigned variant) {
    Fixture fixture(variant); std::string error;
    const auto &paths = CydiaRuntime::PackageDatabasePaths::Current();
    Require(A::NativeTriggerEffectsReady(paths, fixture.selected, &error), error.c_str());
    Require(closures >= 2 && Read(fixture.calls).empty(), "startup checks actual closures without native query");
    std::vector<A::InstalledComponentEvidence> files;
    for (const auto &path : authority.componentPaths) {
        A::InstalledComponentEvidence file;
        Require(A::CaptureTransactionComponent(path, &file, &error), "capture actual native component proof"); files.push_back(file);
    }
    const auto nativeIdentity = A::TriggerNativeAuthorityIdentity(authority, files);
    Require(nativeIdentity.size() == 64, "complete native authority has a canonical approval identity");
    std::reverse(files.begin(), files.end());
    Require(A::TriggerNativeAuthorityIdentity(authority, files) == nativeIdentity, "component enumeration order does not change native approval");
    for (unsigned change = 0; change != 7; ++change) {
        auto changed = files; auto native = authority;
        if (change == 0) ++changed[0].inode;
        if (change == 1) ++changed[0].file.metadata.gid;
        if (change == 2) changed[0].parentsIdentity = Hash("different parent");
        if (change == 3) changed[0].file.sha256 = Hash("different bytes");
        if (change == 4) native.configurationIdentity = Hash("different configuration");
        if (change == 5) native.platformIdentity = Hash("different platform");
        if (change == 6) changed[0] = changed[1];
        Require(A::TriggerNativeAuthorityIdentity(native, changed) != nativeIdentity,
            "native approval binds metadata, generations, parent chains, configuration/platform and unique membership");
    }
    available = false;
    Require(!A::NativeTriggerEffectsReady(paths, fixture.selected, &error) && error == "provider_native_configuration_missing",
        "optional declaration absence never reports native readiness"); available = true;
    const pid_t child = fork(); Require(child >= 0, "fork isolated helper fixture");
    if (child == 0) {
        A::DpkgState state; const auto cancel = variant == 4 ? std::function<bool()>([] { return true; }) : std::function<bool()>();
        const bool captured = A::CaptureEffectAwareDpkgState(paths, fixture.selected, &state, &error, cancel);
        if (variant) {
            Require(!captured && state.packages.empty(), "failed admission cannot publish structured state");
            if (variant == 1) Require(error == "provider_frontend_lock_missing", "actual parent lock required");
            if (variant == 2) Require(Read(fixture.calls) == "query\n", "changed native configuration stops before the second query");
            _exit(0);
        }
        Require(captured && closures >= 7 && state.packages.at("cache:amd64").triggersPending.size() == 1, error.c_str());
        Require(Read(fixture.deferred) == "cache-refresh -\n", "read-only incorporation leaves journal untouched");
        A::ReviewedTransaction review; auto &binding = review.binding;
        binding.providerIdentifier = "fixture-provider"; binding.configurationIdentity = "configuration"; binding.policyIdentity = "policy";
        binding.session = std::string(64, 'a'); binding.cacheEpoch = binding.selectionRevision = 1; binding.review = "review";
        binding.packageStateIdentity = state.packageStateIdentity; review.transaction.registeredArchitectures = {"amd64"};
        A::ReviewedAction action; action.identifier = 1; action.action = A::ExecutionAction::Configure;
        action.package = {"cache", "1", "amd64"}; review.execution.actions.push_back(action);
        A::TriggerEffectEnvelope envelope;
        Require(A::CaptureReviewedTriggerEffects(paths, fixture.selected, review, &envelope, &error) && envelope.recipients.size() == 1 &&
            envelope.nativeAuthorityIdentity == nativeIdentity,
            "exact native review can bind existing interests before downloading archives");
        review.binding.packageStateIdentity = "stale";
        Require(!A::CaptureReviewedTriggerEffects(paths, fixture.selected, review, &envelope, &error) && envelope.identity.empty(),
            "stale reviewed state never grants an envelope");
        _exit(0);
    }
    int status = 0; Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0, "isolated helper settled");
    if (variant == 1 || variant == 4) Require(Read(fixture.calls).empty(), "lock/cancellation refusal precedes every native query");
}
}
int main() {
    for (unsigned variant = 0; variant != 6; ++variant) Run(variant);
    std::cout << "AptProviderTriggerCapture tests passed\n";
}
