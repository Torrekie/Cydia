/* Real protected files, parent lock and bounded query children under fakeroot.
 * Only the Darwin native declaration/loader producers are fixture symbols;
 * their actual Mach-O implementation has separate NativeDpkgAuthority tests.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerCapture.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptProviderComponentCapture.hpp"
#include "Cydia/RuntimeState.hpp"
#include "Cydia/DpkgRunner.h"
#include <apt-pkg/hashes.h>
#include <apt-pkg/strutl.h>
#include <chrono>
#include <cerrno>
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
std::function<void()> closureObserver;
std::string fixtureExecutable;
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
    if (closureObserver) closureObserver();
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
        const std::string checkEnvironment = "[ \"$CYDIA_NATIVE_ENV_TEST\" = frozen ] || exit 1\n";
        std::string manager = "#!/bin/sh\n" + checkEnvironment + "printf 'query\\n' >> " + Quote(calls) + "\n";
        if (variant == 2) manager += "printf 'changed\\n' > " + Quote(configuration) + "\n";
        if (variant == 3) manager += "printf 'other-trigger -\\n' > " + Quote(deferred) + "\n";
        manager += "for value do case $value in --print-architecture) printf 'amd64\\n';; esac; done\n";
        const std::string query = "#!/bin/sh\n" + checkEnvironment + "printf 'query\\n' >> " + Quote(calls) +
            "\nprintf 'cache\\t1\\tamd64\\tinstall ok triggers-pending\\tno\\tcache-refresh\\t\\n'\n";
        Write(environment.dpkg, manager, 0755); Write(environment.dpkgQuery, query, 0755);
        authority = A::NativeDpkgAuthority(); authority.configurationIdentity = Hash("native-config");
        authority.platformIdentity = Hash("fixture-platform");
        Require(CydiaRuntime::NativeLaunchEnvironment::FromEntries({"PATH=/usr/bin:/bin", "DPKG_FRONTEND_LOCKED=1", "CYDIA_NATIVE_ENV_TEST=frozen"},
            &authority.launchEnvironment), "explicit fixture launch snapshot");
        authority.launchEnvironmentBytes = P::SerializeFields(authority.launchEnvironment.entries());
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
    for (unsigned mode = 0; mode != 8; ++mode) {
        authority.effectRecordState = A::NativeEffectRecordState::Parsed;
        A::NativeEffectPolicy::Record record; record.semanticProfile = "dpkg-1.23.7-effects-1";
        record.executorPath = fixture.selected.environment.dpkg;
        record.executorSHA256 = *authority.executorGenerations.at(record.executorPath).begin();
        if (mode == 1) authority.effectRecordState = A::NativeEffectRecordState::Missing;
        if (mode == 2) authority.effectRecordState = A::NativeEffectRecordState::Invalid;
        if (mode == 3) record.semanticProfile = "unknown-profile";
        if (mode == 4) record.executorSHA256 = Hash("future executor");
        if (mode == 5) record.executorPath = fixture.selected.environment.dpkgQuery;
        if (mode == 6) record.role = A::NativeEffectPolicy::Role::Configure;
        if (mode == 7) record.unsupportedSettings = "opaque assertion";
        authority.effectRecords = {record}; bool supported = true;
        Require(A::NativeTriggerEffectsReady(paths, fixture.selected, &error, {}, &supported) && supported == (mode == 0) &&
            Read(fixture.calls).empty(), "conditional capture routing requires protected current supported unpack records and performs no query");
    }
    authority.effectRecordState = A::NativeEffectRecordState::Missing; authority.effectRecords.clear();
    std::vector<A::InstalledComponentEvidence> files;
    for (const auto &path : authority.componentPaths) {
        A::InstalledComponentEvidence file;
        Require(A::CaptureTransactionComponent(path, &file, &error), "capture actual native component proof"); files.push_back(file);
    }
    const auto nativeIdentity = A::TriggerNativeAuthorityIdentity(authority, files);
    Require(nativeIdentity.size() == 64, "complete native authority has a canonical approval identity");
    std::reverse(files.begin(), files.end());
    Require(A::TriggerNativeAuthorityIdentity(authority, files) == nativeIdentity, "component enumeration order does not change native approval");
    for (unsigned change = 0; change != 8; ++change) {
        auto changed = files; auto native = authority;
        if (change == 0) ++changed[0].inode;
        if (change == 1) ++changed[0].file.metadata.gid;
        if (change == 2) changed[0].parentsIdentity = Hash("different parent");
        if (change == 3) changed[0].file.sha256 = Hash("different bytes");
        if (change == 4) native.configurationIdentity = Hash("different configuration");
        if (change == 5) native.platformIdentity = Hash("different platform");
        if (change == 6) changed[0] = changed[1];
        if (change == 7) Require(native.launchEnvironment.Overlay({"CYDIA_NATIVE_ENV_TEST=changed"}, {}, &native.launchEnvironment),
            "change fixture environment without changing asserted native identities");
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
void NativeCompleteStateQueries() {
    Fixture fixture(0); auto &environment = fixture.selected.environment;
    const std::string nativeQuery = "/usr/bin/dpkg-query";
    Require(access(nativeQuery.c_str(), X_OK) == 0, "native fixture requires installed upstream dpkg-query");
    environment.dpkgQuery = nativeQuery;
    // This fixture also exercises the legacy ambient-environment reader.
    // Only the architecture response is fixed; package rows come from the
    // actual installed upstream dpkg-query over this disposable database.
    Write(environment.dpkg, "#!/bin/sh\ncase \"$3\" in --print-architecture) printf 'amd64\\n';; --print-foreign-architectures) :;; *) exit 9;; esac\n", 0755);
    authority.executorGenerations[environment.dpkg] = {Hash(Read(environment.dpkg))};
    authority.componentPaths = {environment.dpkg, environment.dpkgQuery};
    authority.executorGenerations.erase(fixture.root + "/dpkg-query");
    authority.executorGenerations[nativeQuery] = {Hash(Read(nativeQuery))};
    Write(fixture.deferred, "");
    Require(unlink((environment.dpkgAdmin + "/triggers/cache-refresh").c_str()) == 0, "remove irrelevant trigger registry");
    const auto record = [](const std::string &name, const std::string &version, const std::string &selection,
        const std::string &phase, const std::string &extra = "") {
        return "Package: " + name + "\nVersion: " + version + "\nArchitecture: all\nStatus: " + selection + " ok " + phase +
            "\nMaintainer: Fixture <fixture@example.invalid>\nDescription: disposable fixture\n" + extra + '\n';
    };
    const std::string status = record("keep", "1", "install", "installed", "Depends: reference-only\n") +
        record("retained-install", "1", "install", "not-installed") + record("retained-hold", "2", "hold", "not-installed") +
        "Package: forgotten\nStatus: unknown ok not-installed\n\n";
    Write(environment.dpkgAdmin + "/status", status);
    CydiaRuntime::Dpkg::Runner query(nativeQuery); P::Error snapshotError; std::string bytes, identity, error;
    const std::vector<std::string> ordinary{"--admindir=" + environment.dpkgAdmin,
        "--showformat=" + std::string(A::DpkgStateQueryFormat()), "--show"};
    auto complete = ordinary; complete.push_back("*");
    Require(query.RunAndCaptureBounded(ordinary, authority.launchEnvironment, &bytes, 1024 * 1024, 3000).succeeded() &&
        bytes.find("retained-install\t") == std::string::npos && bytes.find("retained-hold\t") == std::string::npos,
        "native no-pattern listing omits retained NotInstalled selections");
    const auto read = [&]() {
        A::DpkgState result;
        Require(query.RunAndCaptureBounded(complete, authority.launchEnvironment, &bytes, 1024 * 1024, 3000).succeeded() &&
            P::RuntimeSnapshot(environment, &identity, &snapshotError) && A::ParseDpkgState(bytes, "amd64\n", "", identity, &result, &error),
            "literal wildcard captures native complete fields without shell expansion or available metadata");
        return result;
    };
    const auto before = read();
    Require(before.packages.at("retained-install:all").package.version == "1" &&
        before.packages.at("retained-install:all").selection == A::DpkgSelection::Install &&
        before.packages.at("retained-hold:all").package.version == "2" &&
        before.packages.at("retained-hold:all").selection == A::DpkgSelection::Hold &&
        A::DpkgStateReferenceOnly(before.packages.at("forgotten:")) &&
        A::DpkgStateReferenceOnly(before.packages.at("reference-only:")),
        "actual native retained generations and metadata-empty references remain distinct");
    const auto captures = [&](bool empty, bool expected) {
        A::DpkgState legacy;
        Require(A::CaptureDpkgState(environment, fixture.lock, &legacy, &error) == expected &&
            (!expected || (empty ? legacy.packages.empty() : legacy.packages.count("retained-hold:all") == 1)),
            "legacy locked complete-state capture preserves selections and true empty database");
        const pid_t child = fork(); Require(child >= 0, "fork real-query protected capture");
        if (child == 0) {
            A::DpkgState captured;
            Require(A::CaptureEffectAwareDpkgState(CydiaRuntime::PackageDatabasePaths::Current(), fixture.selected, &captured, &error) == expected &&
                (!expected || (empty ? captured.packages.empty() : captured.packages.count("retained-install:all") == 1)),
                "native-authority complete capture includes retained selections and keeps query failures explicit");
            _exit(0);
        }
        int settled = 0; Require(waitpid(child, &settled, 0) == child && WIFEXITED(settled) && WEXITSTATUS(settled) == 0,
            "real-query protected child settled");
    };
    captures(false, true);
    const std::string incoming = record("incoming", "2", "install", "unpacked", "Depends: newly-referenced\n");
    Write(environment.dpkgAdmin + "/status", status + incoming); const auto after = read();
    A::ReviewedTransaction review; A::ReviewedAction action; action.identifier = 1; action.action = A::ExecutionAction::Unpack;
    action.package = {"incoming", "2", "all"}; review.execution.actions = {action};
    A::AuthorizedExecution batch; batch.batch = 1; batch.action = A::ExecutionAction::Unpack; batch.actions = {1}; batch.arguments = {"--no-triggers"};
    Require(A::DpkgStateReferenceOnly(after.packages.at("newly-referenced:")) &&
        A::VerifyDpkgStateTransition(before, after, review, batch, &error),
        "actual native reference-only addition is not an unreviewed package mutation");
    auto changed = after; changed.packages.at("retained-hold:all").selection = A::DpkgSelection::Install;
    Require(!A::VerifyDpkgStateTransition(before, changed, review, batch, &error), "retained Hold changes are never reference normalization");
    changed = after; changed.packages.erase("retained-install:all");
    Require(!A::VerifyDpkgStateTransition(before, changed, review, batch, &error), "retained Install disappearance stays unreviewed");
    Write(environment.dpkgAdmin + "/status", record("retained-hold", "2", "hold", "not-installed", "Config-Version: 1\n"));
    Require(!query.RunAndCaptureBounded(complete, authority.launchEnvironment, &bytes, 1024 * 1024, 3000).succeeded(),
        "native NotInstalled query cannot hide configured history");
    captures(false, false);
    Write(environment.dpkgAdmin + "/status", "");
    const auto unmatched = query.RunAndCaptureBounded(complete, authority.launchEnvironment, &bytes, 1024 * 1024, 3000);
    Require(unmatched.kind == CydiaRuntime::Dpkg::ResultKind::Exited && unmatched.error == 0 && unmatched.code == 1 && bytes.empty(),
        "literal wildcard reports no match for an actually empty native database");
    captures(true, true);
    // Exit 1 has this narrow meaning only with independently empty status.
    environment.dpkgQuery = fixture.root + "/dpkg-query"; Write(environment.dpkgQuery, "#!/bin/sh\nexit 1\n", 0755);
    authority.componentPaths = {environment.dpkg, environment.dpkgQuery};
    authority.executorGenerations.erase(nativeQuery); authority.executorGenerations[environment.dpkgQuery] = {Hash(Read(environment.dpkgQuery))};
    Write(environment.dpkgAdmin + "/status", status); captures(false, false);
}
void SnapshotCancellation() {
    Fixture fixture(0); std::string original; P::Error error;
    Require(P::RuntimeSnapshot(fixture.selected.environment, &original, &error), "initial snapshot before contended trigger lock");
    int ready[2], release[2]; Require(pipe(ready) == 0 && pipe(release) == 0, "trigger-lock fixture channels");
    const pid_t child = fork(); Require(child >= 0, "fork actual trigger-lock owner");
    if (child == 0) {
        close(ready[0]); close(release[1]); alarm(5);
        const int descriptor = open((fixture.selected.environment.dpkgAdmin + "/triggers/Lock").c_str(), O_RDWR);
        struct flock request{}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
        Require(descriptor >= 0 && fcntl(descriptor, F_SETLK, &request) == 0, "retain actual native trigger lock");
        const char value = 'x'; Require(write(ready[1], &value, 1) == 1, "signal retained trigger lock");
        char released; Require(read(release[0], &released, 1) == 1, "release trigger lock fixture");
        close(descriptor); close(ready[1]); close(release[0]); _exit(0);
    }
    close(ready[1]); close(release[0]); char value;
    Require(read(ready[0], &value, 1) == 1, "wait for actual trigger contention"); close(ready[0]);
    const auto start = std::chrono::steady_clock::now(); std::string cancelled = "must clear";
    const bool captured = P::RuntimeSnapshot(fixture.selected.environment, &cancelled, &error, [&] {
        return std::chrono::steady_clock::now() - start >= std::chrono::milliseconds(50);
    });
    Require(write(release[1], &value, 1) == 1, "settle trigger-lock fixture"); close(release[1]);
    int status = 0; Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "trigger-lock owner settled");
    Require(!captured && cancelled.empty() && error.code == "provider_trigger_capture_cancelled" &&
        std::chrono::steady_clock::now() - start < std::chrono::seconds(2),
        "snapshot cancellation interrupts actual native trigger-lock wait and clears its token");
    std::string after;
    Require(P::RuntimeSnapshot(fixture.selected.environment, &after, &error, [] { return false; }) && after == original,
        "optional cancellation preserves unchanged snapshot identity and ordinary lock behavior");
}
enum class DeconfigurationCase {
    Less, Greater, Equal, NoVictims, MissingAuthority, MissingLock, StaleReview,
    WrongSession, DuplicateArchive, OversizedReview, NativeError, NativeOutput,
    NativeConfigurationChange, NativeStateChange, IndexChange, SourceChange,
    RetainedScriptChange, CachedStateChange, CancelledQuery, QueryTimeout,
    AmbiguousScript, EmptyScript, CompressedIndex, CorruptCompressedIndex
};
A::ReviewedAction Action(std::uint64_t id, A::ExecutionAction kind, const A::ExecutionPackage &package,
    const std::string &archive = "") {
    A::ReviewedAction action; action.identifier = id; action.action = kind; action.package = package;
    action.archive = archive; return action;
}
void Deconfiguration(DeconfigurationCase kind) {
    Fixture fixture(kind == DeconfigurationCase::MissingLock ? 1 : 0);
    auto &environment = fixture.selected.environment; auto &runtime = fixture.selected.runtime;
    runtime.binding.session.assign(64, 'a'); runtime.acquisitionArchitectures = {"amd64"};
    runtime.sourceListPath = fixture.root + "/sources.list"; runtime.listsDirectory = fixture.root + "/lists";
    environment.sourceList = runtime.sourceListPath;
    fixture.selected.archiveDecoderSearchPath = "/usr/bin:/bin";
    const bool compressed = kind == DeconfigurationCase::CompressedIndex || kind == DeconfigurationCase::CorruptCompressedIndex;
    if (compressed) {
        const auto tools = fixture.root + "/decoders";
        std::filesystem::create_directory(tools);
        Require(symlink(fixtureExecutable.c_str(), (tools + "/xz").c_str()) == 0, "retained fixture decoder path");
        fixture.selected.archiveDecoderSearchPath = tools;
    }
    std::filesystem::create_directory(runtime.listsDirectory);
    Write(runtime.sourceListPath, "deb https://example.invalid/ ./\n");
    const std::string originalStatus = Read(environment.dpkgAdmin + "/status") +
        "Package: beta\nVersion: 1\nArchitecture: amd64\nStatus: install ok installed\n\n";
    Write(environment.dpkgAdmin + "/status", originalStatus);
    const std::string script = environment.dpkgAdmin + "/info/beta.prerm";
    Write(script, kind == DeconfigurationCase::EmptyScript ? "" : "#!/bin/sh\nexit 0\n", 0755);
    if (kind == DeconfigurationCase::AmbiguousScript)
        Write(environment.dpkgAdmin + "/info/beta:amd64.prerm", "ambiguous", 0755);
    A::ReviewedTransaction review;
    review.binding.providerIdentifier = runtime.binding.providerIdentifier;
    review.binding.session = runtime.binding.session;
    review.binding.configurationIdentity = runtime.binding.configurationIdentity;
    review.binding.policyIdentity = runtime.binding.policyIdentity;
    review.binding.cacheEpoch = review.binding.selectionRevision = 1; review.binding.review = "review";
    review.transaction.registeredArchitectures = {"amd64"};
    A::ArchiveManifest archive; archive.identifier = "alpha"; archive.package = {"alpha", "2", "amd64"};
    archive.sourceDefinitionPath = runtime.sourceListPath;
    archive.sourceURI = "https://example.invalid/"; archive.sourceIndexURI = "https://example.invalid/./Packages";
    archive.sourceIndexPath = runtime.listsDirectory + '/' + URItoFileName(archive.sourceIndexURI) + (compressed ? ".xz" : "");
    archive.filename = "pool/alpha.deb"; archive.path = fixture.root + "/not-downloaded.deb";
    archive.size = 123; archive.hashes = {{"SHA256", Hash("download has not occurred")}};
    archive.layout = {"/", {"/var/jb"}};
    const std::string relation = kind == DeconfigurationCase::Greater ? "beta (>> 0)" :
        kind == DeconfigurationCase::Equal ? "beta (= 1)" : "beta (<< 2)";
    const std::string record = "Package: alpha\nVersion: 2\nArchitecture: amd64\nFilename: " + archive.filename +
        "\nSize: " + std::to_string(archive.size) + "\nSHA256: " + archive.hashes.at("SHA256") + '\n' +
        (kind == DeconfigurationCase::NoVictims ? "" : "Breaks: " + relation + '\n') + '\n';
    const std::string encodedIndex = kind == DeconfigurationCase::CorruptCompressedIndex ? "!" + record : record;
    archive.recordSize = record.size(); archive.sourceIndexIdentity = "SHA256:" + Hash(encodedIndex);
    Write(archive.sourceIndexPath, encodedIndex); review.execution.archives = {archive};
    review.execution.actions = {Action(10, A::ExecutionAction::Unpack, archive.package, archive.identifier),
        Action(40, A::ExecutionAction::Remove, {"beta", "1", "amd64"}),
        Action(50, A::ExecutionAction::Configure, archive.package)};
    const std::string frozen = "[ \"$CYDIA_NATIVE_ENV_TEST\" = frozen ] || exit 9\n";
    std::string manager = "#!/bin/sh\n" + frozen +
        "[ \"$1\" = " + Quote("--root=" + environment.dpkgRoot) + " ] || exit 8\n" +
        "[ \"$2\" = " + Quote("--admindir=" + environment.dpkgAdmin) + " ] || exit 8\nshift 2\n" +
        "case \"$1\" in\n--print-architecture) printf 'query\\n' >> " + Quote(fixture.calls) + "; printf 'amd64\\n'; exit 0;;\n" +
        "--print-foreign-architectures) printf 'query\\n' >> " + Quote(fixture.calls) + "; exit 0;;\n" +
        "--compare-versions) [ \"$#\" = 4 ] || exit 8;;\n*) exit 8;;\nesac\n" +
        "printf 'compare\\n' >> " + Quote(fixture.calls) + "\n";
    if (kind == DeconfigurationCase::NativeError) manager += "exit 2\n";
    if (kind == DeconfigurationCase::NativeOutput) manager += "printf x\n";
    if (kind == DeconfigurationCase::NativeConfigurationChange)
        manager += "printf 'changed\\n' > " + Quote(fixture.configuration) + "\n";
    if (kind == DeconfigurationCase::NativeStateChange)
        manager += "printf '\\n' >> " + Quote(environment.dpkgAdmin + "/status") + "\n";
    if (kind == DeconfigurationCase::IndexChange)
        manager += "printf '\\n' >> " + Quote(archive.sourceIndexPath) + "\n";
    if (kind == DeconfigurationCase::SourceChange)
        manager += "printf '# changed\\n' >> " + Quote(runtime.sourceListPath) + "\n";
    if (kind == DeconfigurationCase::CancelledQuery || kind == DeconfigurationCase::QueryTimeout)
        manager += "while :; do :; done\n";
    // The disposable query executable verifies exact argv and returns only
    // native comparison exit semantics, independently of the Cydia matcher.
    manager += "case \"$2:$3:$4\" in 1:lt:2|1:gt:0) exit 0;; 1:lt:0|1:lt:1|1:gt:1) exit 1;; *) exit 8;; esac\n";
    const std::string query = "#!/bin/sh\n" + frozen +
        "[ \"$1\" = " + Quote("--admindir=" + environment.dpkgAdmin) + " ] || exit 8\n" +
        "printf 'query\\n' >> " + Quote(fixture.calls) +
        "\nprintf 'cache\\t1\\tamd64\\tinstall ok triggers-pending\\tno\\tcache-refresh\\t\\n" +
        "beta\\t1\\tamd64\\tinstall ok installed\\tno\\t\\t\\n'\n";
    Write(environment.dpkg, manager, 0755); Write(environment.dpkgQuery, query, 0755);
    authority.executorGenerations[environment.dpkg] = {Hash(manager)};
    authority.executorGenerations[environment.dpkgQuery] = {Hash(query)};
    P::Error ignored;
    Require(P::RuntimeSnapshot(environment, &review.binding.packageStateIdentity, &ignored), "initial exact package state");
    if (kind == DeconfigurationCase::StaleReview) review.binding.packageStateIdentity = "state:stale";
    if (kind == DeconfigurationCase::WrongSession) review.binding.session.assign(64, 'b');
    if (kind == DeconfigurationCase::DuplicateArchive) review.execution.archives.push_back(archive);
    if (kind == DeconfigurationCase::OversizedReview) review.execution.actions.resize(A::MaximumDeconfigurationActions + 1);
    if (kind == DeconfigurationCase::MissingAuthority) available = false;
    const pid_t child = fork(); Require(child >= 0, "fork protected deconfiguration capture");
    if (child == 0) {
        unsigned postQueryChecks = 0;
        closureObserver = [&] {
            if (Read(fixture.calls).find("compare\n") == std::string::npos) return;
            ++postQueryChecks;
            // The first two guards settle the native query, the next two
            // settle its comparator result, two precede script capture and
            // the next two validate the retained script evidence. The ninth
            // enters the cached comparator during the independent rebuild.
            if (kind == DeconfigurationCase::RetainedScriptChange && postQueryChecks == 7)
                Write(script, "changed after capture\n", 0755);
            if (kind == DeconfigurationCase::CachedStateChange && postQueryChecks == 9)
                Write(environment.dpkgAdmin + "/status", originalStatus + "\n");
        };
        const std::function<bool()> cancel = kind == DeconfigurationCase::CancelledQuery ?
            std::function<bool()>([&] { return Read(fixture.calls).find("compare\n") != std::string::npos; }) : std::function<bool()>();
        auto output = std::make_shared<const A::ProtectedDeconfigurationReview>();
        std::string error; const auto begin = std::chrono::steady_clock::now();
        const bool captured = A::CaptureReviewedDeconfiguration(CydiaRuntime::PackageDatabasePaths::Current(),
            fixture.selected, review, &output, &error, cancel);
        const bool success = kind == DeconfigurationCase::Less || kind == DeconfigurationCase::Greater ||
            kind == DeconfigurationCase::Equal || kind == DeconfigurationCase::NoVictims || kind == DeconfigurationCase::EmptyScript ||
            kind == DeconfigurationCase::CompressedIndex;
        if (!success) {
            Require(!captured && !output && !error.empty(), "failed capture clears the whole immutable result");
            if (kind == DeconfigurationCase::MissingAuthority)
                Require(error == "provider_native_configuration_missing", "invalid native declaration is not a missing-graph fallback");
            if (kind == DeconfigurationCase::MissingLock)
                Require(error == "provider_frontend_lock_missing", "review capture requires the retained parent frontend lock");
            if (kind == DeconfigurationCase::CancelledQuery)
                Require(error == "provider_cancelled", "cancelled comparison cannot yield a relationship answer");
            if (kind == DeconfigurationCase::CancelledQuery || kind == DeconfigurationCase::QueryTimeout)
                Require(std::chrono::steady_clock::now() - begin < std::chrono::seconds(6), "blocking query settles within its timeout/cancellation budget");
            if (kind == DeconfigurationCase::RetainedScriptChange || kind == DeconfigurationCase::CachedStateChange)
                Require(postQueryChecks >= (kind == DeconfigurationCase::RetainedScriptChange ? 7u : 9u),
                    "post-capture and cached native-state guards were reached");
            _exit(0);
        }
        Require(captured && output && output->sourceSnapshot, error.c_str());
        Require(access(archive.path.c_str(), F_OK) != 0, "native approval does not download or require an archive");
        Require(output->indexControls.size() == 1 && output->indexControls[0].archive.identifier == "alpha" &&
            output->indexControls[0].evidenceIdentity.size() == 64, "complete retained index provenance precedes approval");
        Require(output->allowances.primaryReview.execution.actions[1].identifier == 40 &&
            output->allowances.initialCheckpoint == output->checkpoint.identity &&
            output->allowances.nativeAuthorityIdentity.size() == 64, "approval preserves exact review and frozen native checkpoint");
        const std::string calls = Read(fixture.calls);
        if (kind == DeconfigurationCase::NoVictims) {
            Require(output->allowances.allowances.empty() && output->installedScripts.packages.empty() &&
                calls == "query\nquery\nquery\n", "empty allowance needs neither script captures nor comparisons");
        } else {
            Require(output->allowances.allowances.size() == 1 && output->installedScripts.packages.size() == 1,
                "only exact predicted old generation scripts enter the immutable output");
            const auto &allowance = output->allowances.allowances.at("beta:amd64@1");
            const auto &scripts = output->installedScripts.packages.at("beta:amd64");
            Require(allowance.endpoint.action == 40 && allowance.endpoint.kind == A::ExecutionAction::Remove &&
                allowance.causes.size() == 1 && allowance.causes[0].unpackAction == 10 &&
                allowance.causes[0].canonicalRelation == relation && allowance.configVersion == "1",
                "native comparison retains canonical cause, history and existing restoration endpoint");
            Require(!scripts.prerm.absent && scripts.postinst.absent &&
                scripts.prerm.bytes == (kind == DeconfigurationCase::EmptyScript ? "" : "#!/bin/sh\nexit 0\n"),
                "selected present-empty and absent script evidence remain distinct");
            Require(calls == "query\nquery\nquery\ncompare\n" +
                std::string(kind == DeconfigurationCase::Greater || kind == DeconfigurationCase::Equal ? "compare\n" : ""),
                "independent allowance rebuild reuses only the guarded same-generation comparator cache");
        }
        std::vector<A::VerifiedIndexControlEvidence> checked;
        Require(output->sourceSnapshot->ControlEvidence(review.execution.archives, &checked, {}, &error) &&
            checked[0].evidenceIdentity == output->indexControls[0].evidenceIdentity, "retained source snapshot remains independently usable");
        Write(runtime.sourceListPath, "# changed after review\ndeb https://example.invalid/ ./\n");
        Require(!output->sourceSnapshot->ControlEvidence(review.execution.archives, &checked, {}, &error) && checked.empty(),
            "immutable output never makes source provenance perpetual");
        _exit(0);
    }
    int status = 0;
    Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0, "protected deconfiguration helper settled");
    if (kind == DeconfigurationCase::MissingAuthority || kind == DeconfigurationCase::MissingLock ||
        kind == DeconfigurationCase::WrongSession || kind == DeconfigurationCase::OversizedReview)
        Require(Read(fixture.calls).empty(), "invalid authority, lock or initial shape never starts native queries");
    closureObserver = {};
}

}
int main(int argc, char **argv) {
    // The protected index fixture uses this executable through a retained
    // absolute decoder path; no optional host compression tool is assumed.
    if (argc == 3 && std::string(argv[1]) == "-d" && std::string(argv[2]) == "-c") {
        bool first = true, corrupt = false; unsigned char bytes[8192];
        for (;;) {
            const auto count = read(STDIN_FILENO, bytes, sizeof(bytes));
            if (count == 0) return corrupt ? 2 : 0;
            if (count < 0) { if (errno == EINTR) continue; return 3; }
            std::size_t offset = 0;
            if (first && bytes[0] == '!') { corrupt = true; offset = 1; }
            first = false;
            while (offset < static_cast<std::size_t>(count)) {
                const auto amount = write(STDOUT_FILENO, bytes + offset, count - offset);
                if (amount < 0 && errno == EINTR) continue;
                if (amount <= 0) return 3;
                offset += amount;
            }
        }
    }
    char *absolute = realpath(argv[0], nullptr); Require(absolute, "absolute fixture executable");
    fixtureExecutable = absolute; free(absolute);
    NativeCompleteStateQueries(); SnapshotCancellation();
    for (unsigned variant = 0; variant != 6; ++variant) Run(variant);
    for (const auto kind : {DeconfigurationCase::Less, DeconfigurationCase::Greater, DeconfigurationCase::Equal,
        DeconfigurationCase::NoVictims, DeconfigurationCase::MissingAuthority, DeconfigurationCase::MissingLock,
        DeconfigurationCase::StaleReview, DeconfigurationCase::WrongSession, DeconfigurationCase::DuplicateArchive,
        DeconfigurationCase::OversizedReview, DeconfigurationCase::NativeError, DeconfigurationCase::NativeOutput,
        DeconfigurationCase::NativeConfigurationChange, DeconfigurationCase::NativeStateChange,
        DeconfigurationCase::IndexChange, DeconfigurationCase::SourceChange, DeconfigurationCase::RetainedScriptChange,
        DeconfigurationCase::CachedStateChange, DeconfigurationCase::CancelledQuery, DeconfigurationCase::QueryTimeout,
        DeconfigurationCase::AmbiguousScript, DeconfigurationCase::EmptyScript, DeconfigurationCase::CompressedIndex,
        DeconfigurationCase::CorruptCompressedIndex}) Deconfiguration(kind);
    std::cout << "AptProviderTriggerCapture tests passed\n";
}
