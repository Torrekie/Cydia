/* Real protected disposable database/scripts/archive capture under fakeroot.
 * No native dpkg mutation or effect readiness is asserted by these fixtures.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#define CYDIA_TRANSACTION_FILES_FIXTURE_ONLY 1
#include "AptProviderTransactionFilesTests.cpp"
#include "Cydia/AptProviderRestorationCapture.hpp"
#include "Cydia/RuntimeState.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/DpkgRunner.h"
#include <chrono>
namespace {
namespace V = CydiaRuntime::Privileged;
using Captured = std::shared_ptr<const P::ProtectedRestorationCheckpoint>;
struct RestorationFixture {
    Fixture archive;
    V::Environment environment; P::TriggerCaptureLock lock;
    P::DeconfigurationAllowanceSet approval;
    std::string info, version = "0", phase = "installed", history, extra;
    explicit RestorationFixture(bool scripts = true) : archive(scripts) {
        environment.dpkg = "/usr/bin/dpkg"; environment.dpkgQuery = "/usr/bin/dpkg-query"; environment.dpkgDeb = "/usr/bin/dpkg-deb";
        environment.dpkgRoot = "/"; environment.dpkgAdmin = archive.root + "/admin";
        info = environment.dpkgAdmin + "/info";
        std::filesystem::create_directories(info); std::filesystem::create_directory(environment.dpkgAdmin + "/updates");
        std::filesystem::create_directory(environment.dpkgAdmin + "/triggers");
        Write(environment.dpkgAdmin + "/triggers/Lock", "", 0600); Write(environment.dpkgAdmin + "/triggers/Unincorp", "");
        Write(environment.dpkgAdmin + "/lock-frontend", "", 0600);
        lock.descriptor = open((environment.dpkgAdmin + "/lock-frontend").c_str(), O_RDWR);
        struct flock held = {}; held.l_type = F_WRLCK; held.l_whence = SEEK_SET;
        Require(lock.descriptor >= 3 && fcntl(lock.descriptor, F_SETLK, &held) == 0, "actual retained restoration frontend lock");
        Write(info + "/sample.prerm", "old prerm\n", 0755); Write(info + "/sample.postinst", "old postinst\n", 0755);
        approval.identity = Hash("parent-reviewed fixture allowance; not native effect proof");
        approval.primaryReview = archive.review;
        P::DeconfigurationAllowance allowance; allowance.installed = {"sample", "0", "all"};
        allowance.selection = P::DpkgSelection::Install; allowance.initialStatus = allowance.diskStatus = P::DpkgPackageStatus::Installed;
        allowance.configVersion = "0"; allowance.endpoint.action = 2; allowance.endpoint.precedingUnpack = 1;
        allowance.endpoint.kind = P::ExecutionAction::Configure; allowance.endpoint.package = {"sample", "1", "all"};
        approval.allowances.emplace("sample:all@0", allowance); Status();
    }
    ~RestorationFixture() { if (lock.descriptor >= 0) close(lock.descriptor); }
    void Status() {
        const std::string value = version.empty() ? extra : "Package: sample\nVersion: " + version +
            "\nArchitecture: all\nStatus: install ok " + phase + "\n" +
            (history.empty() ? "" : "Config-Version: " + history + "\n") + "\n" + extra;
        Write(environment.dpkgAdmin + "/status", value);
    }
    P::DpkgState State() {
        V::Error ignored; std::string identity, error;
        Require(V::RuntimeSnapshot(environment, &identity, &ignored), "fresh protected fixture state token");
        const std::string rows = version.empty() ? "" : "sample\t" + version + "\tall\tinstall ok " + phase + "\tno\t\t\n";
        P::DpkgState value;
        const std::string other = extra.empty() ? "" : "unrelated\t5\tall\tinstall ok installed\tno\t\t\n";
        Require(P::ParseDpkgState(rows + other, "amd64\n", "", identity, &value, &error), "parse explicit fixture native query rows");
        return value;
    }
    bool Capture(Captured *out, std::string *error) {
        return P::ProtectedRestorationCheckpoint::Capture(environment, State(), lock, approval, out, error);
    }
    void Incoming(const P::TransactionArchiveStore &store) {
        // Fixture-only replacement of installed files/status. This exercises
        // protected successor evidence, not actual native Unpack success.
        const auto &control = store.effectControls().front().control;
        for (const auto &item : std::vector<std::pair<std::string, CydiaPackages::ArchiveMaintainerScript>>{
            {"prerm", control.prerm}, {"postinst", control.postinst}}) {
            const auto path = info + "/sample." + item.first;
            if (item.second.present) Write(path, item.second.bytes, item.second.mode);
            else Require(unlink(path.c_str()) == 0, "remove old script absent from retained incoming control");
        }
        version = "1"; phase = "unpacked"; history = "0"; Status();
    }
    P::AuthorizedExecution Batch(const P::TransactionArchiveStore &store) {
        P::AuthorizedExecution batch; batch.batch = 1; batch.action = P::ExecutionAction::Unpack; batch.actions = {1};
        batch.archives.push_back(store.archives().front().source); return batch;
    }
};
void PhaseAndContent() {
    // Phases below are written by this fixture. The assertions establish
    // capture/projection behavior only, never a native child's outcome.
    RestorationFixture f; Captured first, changed; std::string error;
    Require(f.Capture(&first, &error), error.c_str());
    const auto original = first->observation().packages.at("sample:all");
    const auto &scripts = first->scripts().packages.at("sample:all");
    Require(original.scriptsIdentity == Hash(V::SerializeFields({scripts.evidenceIdentity,
        V::SerializeSnapshotEvidence(scripts.prerm), V::SerializeSnapshotEvidence(scripts.postinst)})),
        "phase-bound script hash exactly preserves the existing allowance builder identity");
    f.phase = "half-configured"; f.history = "0"; f.Status();
    Require(f.Capture(&changed, &error), error.c_str());
    const auto half = changed->observation().packages.at("sample:all");
    Require(half.status == P::DpkgPackageStatus::HalfConfigured && half.diskStatus == P::DpkgPackageStatus::HalfConfigured &&
        half.configVersion == "0" && half.controlIdentity != original.controlIdentity && half.scriptsIdentity != original.scriptsIdentity &&
        half.contentIdentity == original.contentIdentity && half.scriptContentIdentity == original.scriptContentIdentity,
        "real HalfConfigured transition changes phase proof without inventing Installed or changing content generation");
    f.history = "0.1"; f.Status();
    Require(f.Capture(&changed, &error), "changed historical Config-Version capture");
    const auto history = changed->observation().packages.at("sample:all");
    Require(history.scriptsIdentity != half.scriptsIdentity && history.controlIdentity != half.controlIdentity &&
        history.contentIdentity == half.contentIdentity && history.scriptContentIdentity == half.scriptContentIdentity,
        "history retained separately from generation content");
    f.extra = "Package: unrelated\nVersion: 5\nArchitecture: all\nStatus: install ok installed\n\n";
    Write(f.info + "/unrelated.prerm", "unrelated", 0755); f.Status();
    Require(f.Capture(&changed, &error) && changed->observation().identity != first->observation().identity &&
        changed->observation().packages.at("sample:all").contentIdentity == history.contentIdentity &&
        changed->observation().packages.at("sample:all").scriptContentIdentity == history.scriptContentIdentity,
        "unrelated global status/info-directory writes do not change selected content identities");
    Require(chmod((f.info + "/sample.prerm").c_str(), 0700) == 0 && f.Capture(&changed, &error) &&
        changed->observation().packages.at("sample:all").scriptContentIdentity != history.scriptContentIdentity,
        "protected script mode stays bound to content generation");
    Require(!P::ProtectedRestorationCheckpoint::Capture(f.environment, f.State(), f.lock, f.approval, &changed, &error,
        [] { return true; }) && !changed, "cancelled capture clears opaque output atomically");
    P::TriggerCaptureLock missing;
    Require(!P::ProtectedRestorationCheckpoint::Capture(f.environment, f.State(), missing, f.approval, &changed, &error) && !changed,
        "no capture without retained actual lock");
    f.extra.clear(); f.version.clear(); f.history.clear(); f.Status();
    Require(f.Capture(&changed, &error) && !changed->observation().packages.at("sample:all").present && changed->scripts().packages.empty(),
        "fully forgotten slot is actual absence, not synthesized installed state");
}
// Actual native query; no manufactured rows or native-policy producer double.
// An explicit pattern is essential: native dpkg-query --show without patterns
// skips NotInstalled records (dpkg 1.23.7 src/query/main.c:showpackages).
P::DpkgState NativeQuery(RestorationFixture &fixture, bool includeSelections = true) {
    V::Error failure; std::string before, after, rows, error;
    Require(V::RuntimeSnapshot(fixture.environment, &before, &failure), "snapshot before real native query");
    std::vector<std::string> arguments = {"--admindir=" + fixture.environment.dpkgAdmin,
        "--showformat=" + std::string(P::DpkgStateQueryFormat()), "--show"};
    if (includeSelections) arguments.push_back("*");
    Require(CydiaRuntime::Dpkg::Runner(fixture.environment.dpkgQuery).RunAndCaptureBounded(arguments,
        &rows, 65536, 4000).succeeded(), "read exact disposable status through installed native dpkg-query");
    Require(V::RuntimeSnapshot(fixture.environment, &after, &failure) && before == after,
        "native read-only query preserves protected status generation");
    P::DpkgState state;
    Require(P::ParseDpkgState(rows, "amd64\n", "", after, &state, &error), "parse real native query fields");
    return state;
}
void RetainedNotInstalled() {
    RestorationFixture f; Captured captured; std::string error;
    f.phase = "not-installed"; f.Status();
    auto state = NativeQuery(f);
    Require(state.packages.at("sample:all").status == P::DpkgPackageStatus::NotInstalled &&
        state.packages.at("sample:all").package.version == "0", "native Install selection really retains versioned NotInstalled metadata");
    Require(P::ProtectedRestorationCheckpoint::Capture(f.environment, state, f.lock, f.approval, &captured, &error), error.c_str());
    const auto value = captured->observation().packages.at("sample:all");
    Require(value.present && value.status == P::DpkgPackageStatus::NotInstalled && value.diskStatus == value.status &&
        value.package.version == "0" && value.configVersion.empty() &&
        !captured->scripts().packages.at("sample:all").prerm.absent,
        "retained row and actual orphan script remain evidence, never Installed or successful-removal proof");
    const auto omitted = NativeQuery(f, false);
    Require(omitted.packages.empty() && !P::ProtectedRestorationCheckpoint::Capture(f.environment, omitted, f.lock,
        f.approval, &captured, &error) && !captured, "omitted native selections cannot be normalized to absence despite protected status row");
    Require(unlink((f.info + "/sample.prerm").c_str()) == 0 && unlink((f.info + "/sample.postinst").c_str()) == 0,
        "remove actual retained orphan scripts");
    state = NativeQuery(f);
    Require(P::ProtectedRestorationCheckpoint::Capture(f.environment, state, f.lock, f.approval, &captured, &error) &&
        captured->scripts().packages.at("sample:all").prerm.absent && captured->scripts().packages.at("sample:all").postinst.absent &&
        captured->observation().packages.at("sample:all").scriptContentIdentity != value.scriptContentIdentity,
        "versioned NotInstalled retains real script absence distinctly from orphan content");
    f.version = "1"; f.Status();
    Require(!P::ProtectedRestorationCheckpoint::Capture(f.environment, state, f.lock, f.approval, &captured, &error) && !captured,
        "changed native retained version rejects stale query evidence");
    f.history = "0"; f.Status();
    Require(!P::ProtectedRestorationCheckpoint::Capture(f.environment, f.State(), f.lock, f.approval, &captured, &error) && !captured,
        "native not-installed Config-Version prohibition remains enforced against raw status");

    // db-ctrl-format.c:pkg_infodb_get_file has no status shortcut: the same
    // real format/Multi-Arch rule determines selected names in this phase.
    f.history.clear(); Write(f.info + "/format", "1\n");
    Write(f.environment.dpkgAdmin + "/status", "Package: sample\nVersion: 1\nArchitecture: amd64\n"
        "Multi-Arch: same\nStatus: hold ok not-installed\n\n");
    auto allowance = f.approval.allowances.begin()->second; f.approval.allowances.clear();
    allowance.installed.architecture = "amd64"; allowance.endpoint.package.architecture = "amd64";
    f.approval.allowances.emplace("sample:amd64@0", allowance);
    Write(f.info + "/sample:amd64.prerm", "retained qualified script\n", 0755);
    state = NativeQuery(f);
    Require(P::ProtectedRestorationCheckpoint::Capture(f.environment, state, f.lock, f.approval, &captured, &error) &&
        captured->observation().packages.at("sample:amd64").selection == P::DpkgSelection::Hold &&
        captured->scripts().packages.at("sample:amd64").prerm.path == f.info + "/sample:amd64.prerm",
        "actual native Hold NotInstalled selection uses architecture-qualified format-one scripts");
    Write(f.info + "/sample.prerm", "obsolete bare orphan\n", 0755); state = NativeQuery(f);
    Require(!P::ProtectedRestorationCheckpoint::Capture(f.environment, state, f.lock, f.approval, &captured, &error) && !captured,
        "conflicting stale bare and qualified scripts still refuse for NotInstalled");
    Write(f.environment.dpkgAdmin + "/status", ""); state = NativeQuery(f, false);
    Require(P::ProtectedRestorationCheckpoint::Capture(f.environment, state, f.lock, f.approval, &captured, &error) &&
        !captured->observation().packages.at("sample:amd64").present && captured->scripts().packages.empty(),
        "genuinely absent native row stays absent; orphan filenames do not manufacture installed metadata");
}
void NativeRemovalEndpointsUnavailable() {
    // dpkg_options_load(CONFIGDIR, HOME) runs before command-line --root and
    // --admindir processing. Those options and a private --log do not isolate
    // pre/post-invoke hooks, status loggers or filters in the compiled config
    // directory. Even an empty HOME or a guessed /etc/dpkg scan cannot prove
    // the actual binary's CONFIGDIR. This generic host fixture has no protected
    // complete native-configuration proof, so it must not invoke mutations.
    // Upstream removal_bulk/pkg_blank semantics remain source evidence only;
    // this skip does not claim native successful-removal endpoint coverage.
    std::cout << "SKIP native removal/purge endpoints: complete native configuration isolation is not established\n";
}
void MultiarchSharedAbsence() {
    RestorationFixture f; Captured both, one; std::string error;
    Require(unlink((f.info + "/sample.prerm").c_str()) == 0 && unlink((f.info + "/sample.postinst").c_str()) == 0,
        "remove obsolete bare scripts before native format one capture");
    Write(f.info + "/format", "1\n");
    f.approval.allowances.clear();
    for (const std::string arch : {"amd64", "arm64"}) {
        for (const char *name : {"prerm", "postinst"}) Write(f.info + "/sample:" + arch + '.' + name, "script\n", 0755);
        P::DeconfigurationAllowance allowance; allowance.installed = {"sample", "0", arch};
        allowance.endpoint.action = 2; allowance.endpoint.precedingUnpack = 1;
        allowance.endpoint.package = {"sample", "1", arch};
        f.approval.allowances.emplace("sample:" + arch + "@0", allowance);
    }
    const auto capture = [&](bool foreign, Captured *out) {
        std::string status, rows;
        for (const std::string arch : {"amd64", "arm64"}) {
            if (!foreign && arch == "arm64") continue;
            status += "Package: sample\nVersion: 0\nArchitecture: " + arch + "\nMulti-Arch: same\nStatus: install ok installed\n\n";
            rows += "sample\t0\t" + arch + "\tinstall ok installed\tsame\t\t\n";
        }
        Write(f.environment.dpkgAdmin + "/status", status);
        V::Error failure; std::string token; P::DpkgState state;
        Require(V::RuntimeSnapshot(f.environment, &token, &failure) &&
            P::ParseDpkgState(rows, "amd64\n", "arm64\n", token, &state, &error), "fresh coinstalled multiarch state");
        return P::ProtectedRestorationCheckpoint::Capture(f.environment, state, f.lock, f.approval, out, &error);
    };
    Require(capture(true, &both), error.c_str());
    const auto original = both->observation().packages.at("sample:amd64");
    f.approval.allowances.erase("sample:arm64@0");
    Require(capture(false, &one) && one->observation().packages.at("sample:amd64").contentIdentity == original.contentIdentity &&
        one->observation().packages.at("sample:amd64").scriptContentIdentity == original.scriptContentIdentity,
        "shared unused bare-name absence is canonical once and independent of coinstalled capture subset");
}
void ContendedSnapshotCancellation(const RestorationFixture &fixture, const Captured &before,
    const Captured &after, const P::TransactionArchiveStore &store, const P::AuthorizedExecution &batch) {
    int ready[2], release[2];
    Require(pipe(ready) == 0 && pipe(release) == 0, "native trigger lock synchronization pipes");
    const pid_t child = fork(); Require(child >= 0, "native trigger lock holder");
    if (child == 0) {
        close(ready[0]); close(release[1]);
        const int descriptor = open((fixture.environment.dpkgAdmin + "/triggers/Lock").c_str(), O_RDWR);
        struct flock held = {}; held.l_type = F_WRLCK; held.l_whence = SEEK_SET;
        if (descriptor < 0 || fcntl(descriptor, F_SETLK, &held) != 0 || write(ready[1], "r", 1) != 1) _exit(2);
        char released = 0;
        const bool finished = read(release[0], &released, 1) == 1;
        close(descriptor); close(ready[1]); close(release[0]); _exit(finished ? 0 : 3);
    }
    close(ready[1]); close(release[0]); char held = 0;
    Require(read(ready[0], &held, 1) == 1, "child retains native trigger lock before default snapshot recheck");
    close(ready[0]);
    std::vector<P::RestorationSuccessorProof> proofs(1); std::string error;
    const auto start = std::chrono::steady_clock::now();
    const bool verified = P::VerifyRestorationSuccessors(fixture.environment, fixture.lock, fixture.approval, batch,
        *before, *after, store, &proofs, &error, [&] {
            return std::chrono::steady_clock::now() - start >= std::chrono::milliseconds(50);
        });
    const auto elapsed = std::chrono::steady_clock::now() - start;
    Require(write(release[1], "x", 1) == 1, "release contended native trigger lock");
    close(release[1]); int status = 0;
    Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "reap trigger lock holder after cancellation");
    Require(!verified && proofs.empty() && elapsed >= std::chrono::milliseconds(50) && elapsed < std::chrono::seconds(1),
        "default restoration snapshot honors cancellation during a real native trigger lock wait");
    Require(P::VerifyRestorationSuccessors(fixture.environment, fixture.lock, fixture.approval, batch,
        *before, *after, store, &proofs, &error) && proofs.size() == 1,
        "cancelled snapshot does not corrupt retained captures or the frontend lock");
}
void SuccessorProofs() {
    // Fixture-written before/after files are compared to actual retained .deb
    // bytes. No child ran, and these proofs do not claim execution readiness
    // or successful native Unpack/removal/configuration.
    for (bool withScripts : {false, true}) {
        RestorationFixture f(withScripts); std::string error; P::TransactionArchiveStore store;
        Require(store.Begin(f.archive.root + "/private", f.archive.runtime, f.archive.review, f.archive.policy,
            "/usr/bin:/bin", {}, &error, {}, true), error.c_str());
        f.phase = "half-configured"; f.history = "0"; f.Status();
        Captured before, after; Require(f.Capture(&before, &error), error.c_str());
        f.Incoming(store); Require(f.Capture(&after, &error), error.c_str());
        const auto batch = f.Batch(store); std::vector<P::RestorationSuccessorProof> proofs;
        const auto verify = [&]() { return P::VerifyRestorationSuccessors(f.environment, f.lock, f.approval, batch,
            *before, *after, store, &proofs, &error); };
        Require(verify() && proofs.size() == 1 && proofs[0].unpackAction == 1 && proofs[0].oldGeneration == "sample:all@0" &&
            proofs[0].retainedArchiveIdentity == store.archives().front().source.fileIdentity &&
            proofs[0].installedScriptContentIdentity == after->observation().packages.at("sample:all").scriptContentIdentity,
            "successor proof binds real staged archive controls, empty/absent scripts and fresh installed generation");
        if (withScripts) ContendedSnapshotCancellation(f, before, after, store, batch);
        auto wrong = batch; wrong.archives[0].fileIdentity += "changed";
        Require(!P::VerifyRestorationSuccessors(f.environment, f.lock, f.approval, wrong, *before, *after, store, &proofs, &error) && proofs.empty(),
            "worker-shaped retained archive identity cannot stand in for actual store");
        auto altered = f.approval; altered.allowances.begin()->second.endpoint.precedingUnpack = 9;
        Require(!P::VerifyRestorationSuccessors(f.environment, f.lock, altered, batch, *before, *after, store, &proofs, &error) && proofs.empty(),
            "successor must be exact reviewed restoration endpoint Unpack");
        Write(f.info + "/sample.postinst", "unexpected installed script", 0755);
        Require(!verify() && proofs.empty(), "post-capture installed mutation fails fresh recheck");
        Require(f.Capture(&after, &error) && !verify() && proofs.empty(), "fresh mismatching script is not incoming successor proof");
        // Restore exact incoming files using actual retained bytes; captures
        // get new real inodes/metadata and must compare those new observations.
        const auto &control = store.effectControls().front().control;
        for (const auto &entry : std::vector<std::pair<std::string, CydiaPackages::ArchiveMaintainerScript>>{
            {"prerm", control.prerm}, {"postinst", control.postinst}}) {
            const auto path = f.info + "/sample." + entry.first;
            if (entry.second.present) Write(path, entry.second.bytes, entry.second.mode);
            else if (access(path.c_str(), F_OK) == 0) Require(unlink(path.c_str()) == 0, "restore absent script");
        }
        Require(f.Capture(&after, &error) && verify(), "exact retained replacement evidence can be freshly recaptured");
        if (withScripts) {
            Require(chmod((f.info + "/sample.prerm").c_str(), 0700) == 0 && f.Capture(&after, &error) && !verify() && proofs.empty(),
                "metadata transformation is explicitly refused despite identical script bytes");
            Require(chmod((f.info + "/sample.prerm").c_str(), 0755) == 0 && f.Capture(&after, &error) && verify(), "restore exact observed mode");
        }
        Write(store.archives().front().copy.identity.file.metadata.path, "changed retained bytes", 0600);
        Require(!verify() && proofs.empty(), "freshly rehashed retained copies cannot silently change after successor capture");
    }
}
}
int main() {
    (void)&CaptureFiles; (void)&StagedArchives;
    Require(geteuid() == 0, "run isolated protected I/O fixture under fakeroot");
    alarm(40); PhaseAndContent(); RetainedNotInstalled(); NativeRemovalEndpointsUnavailable(); MultiarchSharedAbsence(); SuccessorProofs(); alarm(0);
    std::cout << "apt-provider-restoration-capture tests passed\n";
}
