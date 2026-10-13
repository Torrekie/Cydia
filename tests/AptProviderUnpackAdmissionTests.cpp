/* Protected pre-unpack facts with real disposable status/index/archive files,
 * retained Store copies, kernel frontend locks and native read-only queries.
 * The existing TransactionFiles fixture substitutes Darwin declaration/loader
 * and distributor policy producers. Those doubles are explicitly NOT proof of
 * real distribution policy or whole-child native execution acceptance.
 * No dpkg mutation, host database, device or additional executable is used.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef CYDIA_TRANSACTION_OWNER_TESTING
#error Use the existing labelled native producer test seam, never a product build.
#endif
#define main CydiaUnusedTransactionFilesFixtureMain
#include "tests/AptProviderTransactionFilesTests.cpp"
#undef main
#include "Cydia/AptProviderUnpackAdmission.hpp"

namespace {
namespace V = CydiaRuntime::Privileged;
namespace N = P::NativeEffectPolicy;
std::string AdmissionRead(const std::string &path) {
    std::ifstream input(path, std::ios::binary); Require(input.good(), "open retained admission fixture");
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
struct AdmissionFixture : Fixture {
    P::BrokerEnvironment selected;
    std::vector<P::InstalledComponentEvidence> components;
    std::string configuration;
    int frontend = -1, statusRead = -1, statusWrite = -1;
    bool forceBreaks = false, sibling = false;
    AdmissionFixture(const std::string &nativeFields, const std::string &indexFields, bool forced = false,
        const std::string &victimFields = "", bool multiple = false, bool siblingCase = false) : Fixture(), forceBreaks(forced), sibling(siblingCase) {
        selected.runtime = runtime; auto &environment = selected.environment;
        if (sibling) {
            selected.runtime.registeredArchitectures = selected.runtime.acquisitionArchitectures = {"amd64", "i386"};
            policy.environment.registeredArchitectures = policy.environment.acquisitionArchitectures = {"amd64", "i386"};
            review.transaction.registeredArchitectures = {"amd64", "i386"};
            review.transaction.installs.clear(); review.transaction.packages.clear();
            const auto identity = CydiaAPT::BuildPackageIdentity("sample", "i386", "i386", "amd64", CydiaAPT::MultiArchMode::Same);
            review.transaction.installs = {identity.routingName}; review.transaction.packages[identity.routingName] = {identity, "1", "sample"};
            for (auto &action : review.execution.actions) action.package.architecture = "i386";
        }
        environment.dpkg = "/usr/bin/dpkg"; environment.dpkgQuery = "/usr/bin/dpkg-query";
        environment.dpkgDeb = "/usr/bin/dpkg-deb"; environment.dpkgRoot = "/";
        environment.dpkgAdmin = root + "/admin"; environment.extendedStates = root + "/extended_states";
        selected.executableSearchPath = selected.archiveDecoderSearchPath = "/usr/bin:/bin";
        selected.runtime.dpkgExecutablePath = environment.dpkg; selected.runtime.dpkgQueryExecutablePath = environment.dpkgQuery;
        selected.runtime.dpkgDebExecutablePath = environment.dpkgDeb; selected.runtime.dpkgAdminDirectory = environment.dpkgAdmin;
        selected.runtime.extendedStatesPath = environment.extendedStates;
        selected.runtime.dpkgOptions = {"--root=/", "--admindir=" + environment.dpkgAdmin};
        std::filesystem::create_directories(environment.dpkgAdmin + "/info");
        std::filesystem::create_directory(environment.dpkgAdmin + "/triggers");
        Write(environment.extendedStates, ""); Write(environment.dpkgAdmin + "/lock-frontend", "", 0600);
        Write(environment.dpkgAdmin + "/triggers/Lock", "", 0600);
        Write(environment.dpkgAdmin + "/triggers/Unincorp", "");
        Write(environment.dpkgAdmin + "/info/format", "1\n");
        Write(environment.dpkgAdmin + "/status", "Package: victim-a\nVersion: 1\nArchitecture: amd64\nStatus: install ok installed\n" +
            victimFields + "\nPackage: victim-b\nVersion: 1\nArchitecture: amd64\nStatus: install ok installed\n\n");
        Write(environment.dpkgAdmin + "/info/victim-a.list", "/usr/lib/victim-a-saving-name\n");
        Write(environment.dpkgAdmin + "/info/victim-b.list", "/usr/lib/victim-b-saving-name\n");
        if (sibling) {
            Write(environment.dpkgAdmin + "/arch", "amd64\ni386\n");
            Write(environment.dpkgAdmin + "/status", "Package: sample\nVersion: 2\nArchitecture: amd64\nStatus: install ok installed\nMulti-Arch: same\n\n");
            Write(environment.dpkgAdmin + "/info/sample:amd64.list", "/usr/lib/sample-saving-name\n");
        }
        frontend = open((environment.dpkgAdmin + "/lock-frontend").c_str(), O_RDWR);
        struct flock held{}; held.l_type = F_WRLCK; held.l_whence = SEEK_SET;
        Require(frontend >= 3 && fcntl(frontend, F_SETLK, &held) == 0, "real parent retains frontend lock");
        int descriptors[2]; Require(pipe(descriptors) == 0, "real parent status descriptor scope");
        statusRead = descriptors[0]; statusWrite = descriptors[1];
        auto &archive = review.execution.archives.front();
        if (sibling) archive.package.architecture = "i386";
        const std::string raw = "Package: sample\nVersion: 1\nArchitecture: " + archive.package.architecture +
            "\nDescription: fixture\n" + (sibling ? "Multi-Arch: same\n" : "") + nativeFields;
        deb = "!<arch>\n" + Ar("debian-binary", "2.0\n") + Ar("control.tar", Tar("control", raw)) +
            Ar("data.tar", Tar("usr/lib/fixture", "retained read-only payload"));
        archive.size = deb.size(); archive.hashes = {{"SHA512", Hash(deb, Hashes::SHA512SUM)}};
        const std::string record = "Package: sample\nVersion: 1\nArchitecture: " + archive.package.architecture +
            "\nFilename: pool/sample.deb\n" + (sibling ? "Multi-Arch: same\n" : "") + "Size: " +
            std::to_string(archive.size) + "\nSHA512: " + archive.hashes["SHA512"] + "\n" + indexFields + "\n";
        archive.recordSize = record.size(); archive.sourceIndexIdentity = "SHA256:" + Hash(record);
        Write(archive.path, deb); Write(archive.sourceIndexPath, record);
        for (unsigned index = 0; index != (sibling ? 1u : 2u); ++index) {
            P::ReviewedAction restore; restore.identifier = 3 + index; restore.action = P::ExecutionAction::Configure;
            restore.package = {sibling ? "sample" : index ? "victim-b" : "victim-a", sibling ? "2" : "1", "amd64"};
            review.execution.actions.push_back(restore); policy.additionalActionsReviewed.insert(restore.identifier);
        }
        if (multiple) {
            P::ArchiveManifest second = archive; second.identifier = "sample-two"; second.package.package = "sample-two";
            second.filename = "pool/sample-two.deb"; second.path = root + "/sample-two.deb";
            const std::string bytes = "!<arch>\n" + Ar("debian-binary", "2.0\n") +
                Ar("control.tar", Tar("control", "Package: sample-two\nVersion: 1\nArchitecture: all\n")) +
                Ar("data.tar", Tar("usr/lib/fixture-two", "second retained payload"));
            second.size = bytes.size(); second.hashes = {{"SHA512", Hash(bytes, Hashes::SHA512SUM)}};
            const std::string recordTwo = "Package: sample-two\nVersion: 1\nArchitecture: all\nFilename: pool/sample-two.deb\nSize: " +
                std::to_string(second.size) + "\nSHA512: " + second.hashes["SHA512"] + "\n\n";
            second.recordOffset = record.size(); second.recordSize = recordTwo.size();
            const std::string index = record + recordTwo; second.sourceIndexIdentity = "SHA256:" + Hash(index);
            review.execution.archives.front().sourceIndexIdentity = second.sourceIndexIdentity;
            Write(second.sourceIndexPath, index); Write(second.path, bytes); review.execution.archives.push_back(second);
            auto unpack = review.execution.actions.front(); unpack.identifier = 5; unpack.package = second.package; unpack.archive = second.identifier;
            review.execution.actions.insert(review.execution.actions.begin() + 1, unpack);
            unpack.identifier = 6; unpack.action = P::ExecutionAction::Configure; unpack.archive.clear(); review.execution.actions.push_back(unpack);
            const auto package = CydiaAPT::BuildPackageIdentity("sample-two", "amd64", "all", "amd64", CydiaAPT::MultiArchMode::None);
            review.transaction.installs.push_back(package.routingName); review.transaction.packages[package.routingName] = {package, "1", "sample-two"};
        }
        policy.environment.paths.dpkgAdmin = environment.dpkgAdmin;
        policy.protectedDpkgOptions = selected.runtime.dpkgOptions;
        configuration = root + "/native-fixture-input"; Write(configuration, "labelled policy producer fixture input\n");
        fixtureAuthority = P::NativeDpkgAuthority(); fixtureAuthorityAvailable = true;
        fixtureAuthority.configurationIdentity = Hash("admission-config"); fixtureAuthority.platformIdentity = Hash("admission-platform");
        fixtureAuthority.dpkgRoot = environment.dpkgRoot; fixtureAuthority.dpkgAdmin = environment.dpkgAdmin;
        fixtureAuthority.executableSearchPath = selected.executableSearchPath;
        fixtureAuthority.componentPaths = {environment.dpkg, environment.dpkgQuery};
        fixtureAuthority.effectRecordState = P::NativeEffectRecordState::Parsed;
        Require(CydiaRuntime::NativeLaunchEnvironment::FromEntries({"PATH=/usr/bin:/bin", "LANG=C", "LC_ALL=C", "DPKG_FRONTEND_LOCKED=1"},
            &fixtureAuthority.launchEnvironment), "owned query/launch environment");
        fixtureAuthority.launchEnvironmentBytes = V::SerializeFields(fixtureAuthority.launchEnvironment.entries());
        V::Evidence graph; V::Error failure;
        Require(V::CaptureEvidence(configuration, false, false, &graph, &failure), "actual protected fixture input");
        fixtureAuthority.configurationEvidence = {graph};
        for (const auto &path : fixtureAuthority.componentPaths) {
            P::InstalledComponentEvidence file; std::string error;
            Require(P::CaptureTransactionComponent(path, &file, &error), "actual native read-only executor bytes");
            fixtureAuthority.executorGenerations[path] = {file.file.sha256}; components.push_back(std::move(file));
        }
        Require(V::RuntimeSnapshot(environment, &review.binding.packageStateIdentity, &failure), "fresh exact initial native state");
        selected.runtime.binding.packageStateIdentity = policy.environment.packageStateIdentity = review.binding.packageStateIdentity;
        fixturePolicyProducer = [](const P::NativeDpkgAuthority &authority, const std::string &executable,
            const std::vector<P::InstalledComponentEvidence> &files, const std::string &profile, N::Role role,
            const std::vector<std::string> &prefix, N::Inputs *output, std::string *, const std::function<bool()> &cancelled) {
            if (cancelled && cancelled()) return false;
            N::Inputs inputs; inputs.semanticProfile = profile; inputs.executorPath = executable;
            inputs.platformIdentity = authority.platformIdentity; inputs.environment = authority.launchEnvironment;
            inputs.dpkgRoot = authority.dpkgRoot; inputs.dpkgAdmin = authority.dpkgAdmin;
            inputs.executableSearchPath = authority.executableSearchPath; inputs.role = role; inputs.optionPrefix = prefix;
            const auto &evidence = authority.configurationEvidence.front();
            N::ContentInput config; config.path = evidence.path; config.present = true; config.size = evidence.bytes.size();
            config.sha256 = Hash(evidence.bytes); inputs.configuration.push_back(std::move(config));
            for (const auto &file : files) {
                inputs.components.push_back({file.file.metadata.path, file.file.sha256});
                if (file.file.metadata.path == executable) inputs.executorSHA256 = file.file.sha256;
            }
            std::string valid; if (!N::EncodeInputs(inputs, &valid)) return false;
            *output = std::move(inputs); return true;
        };
    }
    ~AdmissionFixture() {
        if (frontend >= 0) close(frontend);
        if (statusRead >= 0) close(statusRead);
        if (statusWrite >= 0) close(statusWrite);
        fixturePolicyProducer = FixturePolicyProducer();
    }
};
enum class AdmissionCheck { Ready, Blocked, EarlyBlocked, TwoGroups, Forced, Boundary, SiblingBlocked, StaleSource, StaleNative, StaleOwnership, StaleScript, WrongLaunch, WrongPrivatePath, WrongBatchAction, Cancelled };
void AdmissionChild(AdmissionFixture &fixture, AdmissionCheck check) {
    close(fixture.frontend); fixture.frontend = -1;
    std::string error; std::shared_ptr<const P::ProtectedDeconfigurationReview> approved;
    Require(P::CaptureReviewedDeconfiguration(CydiaRuntime::PackageDatabasePaths::Current(), fixture.selected, fixture.review,
        &approved, &error), error.c_str());
    P::TransactionArchiveStore store;
    Require(store.Begin(fixture.root + "/private", fixture.selected.runtime, fixture.review, fixture.policy,
        fixture.selected.archiveDecoderSearchPath, {}, &error, {}, true), error.c_str());
    P::AuthorizedExecution batch; batch.batch = 1; batch.action = P::ExecutionAction::Unpack; batch.actions = {1};
    batch.arguments = {"--root=/", "--admindir=" + fixture.selected.environment.dpkgAdmin,
        "--status-fd=" + std::to_string(fixture.statusWrite), "--no-triggers", "--auto-deconfigure", "--unpack",
        store.archives().front().copy.identity.file.metadata.path};
    batch.optionPrefixSize = 6; batch.statusOptionIndex = 2;
    if (fixture.sibling) { batch.arguments.erase(batch.arguments.begin() + 4); --batch.optionPrefixSize; }
    batch.archives = {store.archives().front().source};
    if (check == AdmissionCheck::WrongPrivatePath) batch.arguments.back() = fixture.review.execution.archives.front().path;
    if (check == AdmissionCheck::WrongBatchAction) batch.actions.front() = 3;
    if (check == AdmissionCheck::Boundary) {
        Require(store.archives().size() == 2, "two actual retained archive copies");
        batch.arguments.push_back(store.archives()[1].copy.identity.file.metadata.path);
        batch.actions.push_back(5); batch.archives.push_back(store.archives()[1].source);
    }
    std::vector<std::string> final;
    Require(P::FinalizeNativeChildArguments(batch.arguments, batch.optionPrefixSize, batch.statusOptionIndex,
        fixture.statusWrite, &final), "actual fd3 finalized native arguments");
    N::Inputs inputs;
    Require(P::BuildNativeEffectPolicyInputs(fixtureAuthority, fixture.selected.environment.dpkg, fixture.components,
        "dpkg-1.23.7-effects-1", N::Role::Unpack, {final.begin(), final.begin() + batch.optionPrefixSize}, &inputs, &error), error.c_str());
    N::Record record; record.semanticProfile = inputs.semanticProfile; record.executorPath = inputs.executorPath;
    record.executorSHA256 = inputs.executorSHA256; record.role = inputs.role; record.optionPrefix = inputs.optionPrefix;
    Require(N::InputIdentity(inputs, [](const std::string &bytes) { return Hash(bytes); }, &record.inputIdentity), "actual policy input identity");
    record.settings.autoDeconfigure = !fixture.sibling; record.settings.triggers = N::TriggerMode::Disabled; record.settings.statusDescriptors = {3};
    if (fixture.forceBreaks) record.settings.forces = {N::Force::Breaks};
    fixtureAuthority.effectRecords = {record};
    P::TriggerCaptureLock lock; lock.parent = getppid();
    std::shared_ptr<const P::ProtectedUnpackAdmission> facts;
    const auto cancelled = check == AdmissionCheck::Cancelled ? std::function<bool()>([] { return true; }) : std::function<bool()>();
    if (check == AdmissionCheck::WrongLaunch) final.push_back("unreviewed-operand");
    const bool captured = P::ProtectedUnpackAdmission::Capture(fixture.selected, fixtureAuthority, fixture.components,
        store, *approved, batch, final, fixture.statusWrite, lock, &facts, &error, cancelled);
    if (check == AdmissionCheck::WrongLaunch || check == AdmissionCheck::WrongPrivatePath ||
        check == AdmissionCheck::WrongBatchAction || check == AdmissionCheck::Cancelled) {
        Require(!captured && !facts, "wrong launch/private copy/primary action/cancellation cannot publish opaque facts"); return;
    }
    Require(captured && facts && !facts->identity().empty(), error.c_str());
    const bool blocked = check == AdmissionCheck::Blocked || check == AdmissionCheck::EarlyBlocked || check == AdmissionCheck::SiblingBlocked;
    Require(facts->readiness() == (blocked ? P::UnpackAdmissionReadiness::Blocked : check == AdmissionCheck::Boundary ?
        P::UnpackAdmissionReadiness::RequiresFreshBoundary : P::UnpackAdmissionReadiness::FactsVerified),
        "actual archive ordering decides queued native Pre-Depends eligibility");
    const auto expected = check == AdmissionCheck::Forced || check == AdmissionCheck::EarlyBlocked ? 0u :
        check == AdmissionCheck::TwoGroups ? 2u : 1u;
    Require(facts->causes().size() == expected, "unused/future allowances do not invent queued deconfiguration causes");
    if (check == AdmissionCheck::SiblingBlocked)
        Require(facts->causes().front().cause.kind == P::DeconfigurationCauseKind::SiblingVersionMismatch &&
            facts->causes().front().installed.package == "sample" && facts->causes().front().installed.architecture == "amd64",
            "native coinstalled sibling is queued before the first Pre-Depends without auto-deconfigure");
    if (check == AdmissionCheck::TwoGroups)
        Require(facts->causes()[0].cause.group == 0 && facts->causes()[1].cause.group == 1 &&
            facts->causes()[0].installed.package == "victim-a" && facts->causes()[1].installed.package == "victim-b",
            "actual comma-node order and initial approval ordinals are retained");
    Require(fixture.components.size() == 2 && AdmissionRead(store.archives().front().copy.identity.file.metadata.path) == fixture.deb,
        "readiness used actual unchanged private archive copies and native executor identities");
    if (blocked || check == AdmissionCheck::Boundary) {
        Require(!facts->Revalidate(fixture.selected, fixtureAuthority, fixture.components, store, final, lock, &error),
            "blocked facts or unavailable multiarchive continuity cannot become a reusable admission");
        return;
    }
    Require(facts->Revalidate(fixture.selected, fixtureAuthority, fixture.components, store, final, lock, &error), error.c_str());
    if (check == AdmissionCheck::StaleSource)
        Write(fixture.review.execution.archives.front().sourceIndexPath, "changed selected record\n");
    else if (check == AdmissionCheck::StaleNative) Write(fixture.configuration, "changed native graph\n");
    else if (check == AdmissionCheck::StaleOwnership)
        Write(fixture.selected.environment.dpkgAdmin + "/info/victim-a.list", "/usr/lib/replaced-saving-name\n");
    else if (check == AdmissionCheck::StaleScript)
        Write(fixture.selected.environment.dpkgAdmin + "/info/victim-a.prerm", "#!/bin/sh\nexit 0\n", 0755);
    else return;
    Require(!facts->Revalidate(fixture.selected, fixtureAuthority, fixture.components, store, final, lock, &error),
        "changed actual source/native/list/script evidence cannot reuse captured facts");
}
void CheckAdmission(const std::string &nativeFields, const std::string &indexFields, AdmissionCheck check,
    bool forced = false, const std::string &victimFields = "") {
    AdmissionFixture fixture(nativeFields, indexFields, forced, victimFields, check == AdmissionCheck::Boundary, check == AdmissionCheck::SiblingBlocked);
    const pid_t child = fork(); Require(child >= 0, "fork isolated authenticated parent-capture fixture");
    if (child == 0) { AdmissionChild(fixture, check); _exit(0); }
    int status; Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "protected admission child completed without dpkg mutation");
}
}
int main() {
    Require(geteuid() == 0, "run disposable protected fixtures only under fakeroot"); alarm(180);
    const std::string early = "Pre-Depends: victim-a\nBreaks: victim-a (<< 2)\n";
    const std::string late = "Breaks: victim-a (<< 2)\nPre-Depends: victim-a\n";
    CheckAdmission(early, late, AdmissionCheck::Ready);
    CheckAdmission(late, early, AdmissionCheck::Blocked);
    CheckAdmission("Pre-Depends: missing-first\nBreaks: victim-a (<< 2)\n",
        "Breaks: victim-a (<< 2)\nPre-Depends: missing-first\n", AdmissionCheck::EarlyBlocked);
    CheckAdmission("Breaks: victim-a (<< 2), victim-b (<< 2)\nPre-Depends: sample\n",
        "Pre-Depends: sample\nBreaks: victim-a (<< 2), victim-b (<< 2)\n", AdmissionCheck::TwoGroups);
    CheckAdmission(late, early, AdmissionCheck::Forced, true);
    CheckAdmission("Provides: virtual-target\nBreaks: victim-a (<< 2)\nPre-Depends: victim-b\n",
        "Pre-Depends: victim-b\nBreaks: victim-a (<< 2)\nProvides: virtual-target\n", AdmissionCheck::EarlyBlocked, false,
        "Conflicts: virtual-target\n");
    CheckAdmission("Breaks: victim-a (<< 2)\nProvides: virtual-target\nPre-Depends: victim-b\n",
        "Pre-Depends: victim-b\nProvides: virtual-target\nBreaks: victim-a (<< 2)\n", AdmissionCheck::Ready, false,
        "Conflicts: virtual-target\n");
    CheckAdmission("Provides: unrelated-virtual\nBreaks: victim-a (<< 2)\n",
        "Breaks: victim-a (<< 2)\nProvides: unrelated-virtual\n", AdmissionCheck::Ready, false, "Conflicts: sample\n");
    CheckAdmission(early, late, AdmissionCheck::Boundary);
    CheckAdmission("Pre-Depends: sample:amd64\n", "Pre-Depends: sample:amd64\n", AdmissionCheck::SiblingBlocked);
    for (const auto check : {AdmissionCheck::StaleSource, AdmissionCheck::StaleNative, AdmissionCheck::StaleOwnership,
        AdmissionCheck::StaleScript, AdmissionCheck::WrongLaunch, AdmissionCheck::WrongPrivatePath,
        AdmissionCheck::WrongBatchAction, AdmissionCheck::Cancelled}) CheckAdmission(early, late, check);
    alarm(0); std::cout << "[protected-unpack-facts] native ordered read-only gate fixtures passed\n";
}
