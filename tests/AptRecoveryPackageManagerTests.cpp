/* Real libapt ordering and provenance fixtures; no dpkg/provider is executed.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryPackageManager.hpp"
#include "Cydia/AptLocalStateVersion.hpp"
#include "Cydia/AptProviderArchiveEvidence.hpp"
#include <apt-pkg/cachefile.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/pkgsystem.h>
#include <apt-pkg/progress.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/strutl.h>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <unistd.h>

namespace {
using namespace CydiaAPT;
namespace P = CydiaAPT::Provider;
void Require(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "[apt-recovery-recording] " << message << '\n'; _error->DumpErrors(); std::exit(1);
}
void Write(const std::string &path, const std::string &bytes) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file << bytes;
    Require(file.good(), "write fixture");
}
std::string Read(const std::string &path) {
    std::ifstream file(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
std::string ConfigurationBytes() {
    std::ostringstream bytes; _config->Dump(bytes); return bytes.str();
}
std::string SHA256(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM); Require(hash.Add(bytes.data(), bytes.size()), "hash fixture");
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
std::string Record(const std::string &name, const std::string &version, const std::string &arch,
                   const std::string &extra = "") {
    const std::string archive = name + ':' + version + ':' + arch;
    return "Package: " + name + "\nVersion: " + version + "\nArchitecture: " + arch +
        "\nMaintainer: Fixture <fixture@example.invalid>\nDescription: fixture\nFilename: pool/" + name + '_' + arch +
        ".deb\nSize: " + std::to_string(archive.size()) + "\nSHA256: " + SHA256(archive) + '\n' + extra + '\n';
}
struct Fixture {
    std::string root, index, statusBytes;
    RuntimeDescriptor runtime;
    P::Binding binding;
    CydiaPackages::ArchiveLayout layout = {"/", {"/var/jb"}};
    pkgCacheFile cache;
    std::unique_ptr<pkgRecords> records;
    explicit Fixture(const std::string &pending = "") {
        char pattern[] = "/tmp/cydia-recovery-recording-XXXXXX";
        const char *made = mkdtemp(pattern); Require(made, "create fixture"); root = made;
        for (const char *path : {"etc", "etc/parts", "lists", "lists/partial", "archives", "archives/partial", "log"})
            std::filesystem::create_directories(root + '/' + path);
        runtime.architecture = "amd64"; runtime.registeredArchitectures = {"amd64", "i386"};
        runtime.acquisitionArchitectures = runtime.registeredArchitectures; runtime.packageInstallPrefix = "/";
        runtime.sourceListPath = root + "/etc/sources.list"; runtime.sourcePartsDirectory = root + "/etc/parts";
        runtime.listsDirectory = root + "/lists";
        binding.providerIdentifier = "recovery-fixture"; binding.session = std::string(64, 'a');
        binding.configurationIdentity = "config-1"; binding.policyIdentity = "policy-1";
        binding.packageStateIdentity = "state-1"; binding.cacheEpoch = 1; binding.selectionRevision = 1; binding.review = "review-1";
        runtime.binding.providerIdentifier = binding.providerIdentifier; runtime.binding.session = binding.session;
        runtime.binding.configurationIdentity = binding.configurationIdentity; runtime.binding.policyIdentity = binding.policyIdentity;
        runtime.binding.packageStateIdentity = binding.packageStateIdentity;
        Write(runtime.sourceListPath, "# Preserve this comment.\ndeb [trusted=yes] https://example.invalid/ ./\n");
        index = runtime.listsDirectory + '/' + URItoFileName("https://example.invalid/./Packages");
        Write(index, Record("base", "1", "amd64") + Record("top", "2", "amd64", "Pre-Depends: base (= 1)\n") +
            Record("cycle-a", "1", "amd64", "Depends: cycle-b (= 1)\n") + Record("cycle-b", "1", "amd64", "Depends: cycle-a (= 1)\n") +
            Record("portable", "1:3.0~rc1-2", "all") + Record("portable", "2", "amd64", "Pre-Depends: unselected-only\n") +
            Record("twin", "1", "amd64", "Multi-Arch: same\n") + Record("twin", "1", "i386", "Multi-Arch: same\n") +
            Record("old", "9", "amd64") + Record("purge-me", "9", "amd64") + Record("residual", "9", "amd64"));
        statusBytes = "Package: old\nStatus: install ok installed\nVersion: 1\nArchitecture: all\nDescription: old\n\n"
            "Package: purge-me\nStatus: install ok installed\nVersion: 2\nArchitecture: amd64\nDescription: old\n\n"
            "Package: legacy-other\nStatus: install ok installed\nVersion: 3\nArchitecture: armhf\nDescription: other\n\n"
            "Package: residual\nStatus: deinstall ok config-files\nVersion: 1\nArchitecture: amd64\nDescription: residual\n\n"
            "Package: residual-only\nStatus: deinstall ok config-files\nVersion: 4\nArchitecture: all\nDescription: residual\n\n";
        if (!pending.empty()) statusBytes += "Package: cache\nStatus: " + pending +
            "\nVersion: 1\nArchitecture: amd64\nDescription: cache fixture\nTriggers-Pending: refresh\n\n";
        Write(root + "/status", statusBytes); Write(root + "/extended_states", "");
        unsetenv("APT_CONFIG"); _config->Clear(); _error->Discard();
        _config->Set("Dir", "/"); _config->Set("Dir::Etc", root + "/etc");
        _config->Set("Dir::Etc::main", "/dev/null"); _config->Set("Dir::Etc::parts", "/dev/null");
        _config->Set("Dir::Etc::sourcelist", runtime.sourceListPath); _config->Set("Dir::Etc::sourceparts", runtime.sourcePartsDirectory);
        _config->Set("Dir::State", root); _config->Set("Dir::State::status", root + "/status");
        _config->Set("Dir::State::lists", runtime.listsDirectory); _config->Set("Dir::State::extended_states", root + "/extended_states");
        _config->Set("Dir::Cache", root); _config->Set("Dir::Cache::archives", root + "/archives");
        _config->Set("Dir::Cache::pkgcache", ""); _config->Set("Dir::Cache::srcpkgcache", "");
        _config->Set("Dir::Log", root + "/log");
        _config->Set("Dir::Bin::dpkg", root + "/forbidden-dpkg");
        _config->Set("APT::Architecture", "amd64");
        _config->Set("APT::Architectures::", "amd64"); _config->Set("APT::Architectures::", "i386");
        _config->Set("APT::Sandbox::User", ""); _config->Set("Debug::NoLocking", true);
        _config->Set("Acquire::Languages", "none");
        Require(pkgInitConfig(*_config) && pkgInitSystem(*_config, _system), "initialize isolated APT");
        OpProgress progress; Require(cache.Open(&progress, false), "open native cache");
        records.reset(new pkgRecords(*cache.GetPkgCache()));
    }
    ~Fixture() { records.reset(); cache.Close(); std::filesystem::remove_all(root); }
    pkgCache::PkgIterator Find(const char *name, const char *architecture = "amd64") {
        auto package = cache.GetPkgCache()->FindPkg(name, architecture); Require(!package.end(), "find fixture package"); return package;
    }
    pkgCache::VerIterator Select(const char *name, const char *architecture, const char *version = nullptr) {
        const auto package = Find(name, architecture); auto selected = package.VersionList();
        if (version) while (!selected.end() && std::string(selected.VerStr()) != version) ++selected;
        Require(!selected.end(), "find exact fixture version"); cache->SetCandidateVersion(selected);
        Require(cache->MarkInstall(package, true), "select fixture install"); return selected;
    }
    TransactionData Transaction() {
        TransactionData transaction; transaction.registeredArchitectures = runtime.registeredArchitectures;
        for (auto package = cache->PkgBegin(); !package.end(); ++package) {
            auto &state = (*cache.GetDepCache())[package];
            if (!state.Install() && !state.Delete()) continue;
            const auto version = state.Delete() ? LocalStateVersion(package) : state.InstVerIter(*cache.GetDepCache());
            Require(!version.end(), "selected exact version");
            const auto mode = version->MultiArch & pkgCache::Version::Same ? MultiArchMode::Same : MultiArchMode::None;
            const auto identity = BuildPackageIdentity(package.Name(), package.Arch(), version.Arch(), "amd64", mode);
            transaction.packages[identity.routingName] = {identity, version.VerStr(), package.Name()};
            if (state.Delete()) {
                if (state.iFlags & pkgDepCache::Purge) transaction.purges.push_back(identity.routingName);
                else transaction.removes.push_back(identity.routingName);
            } else transaction.installs.push_back(identity.routingName);
        }
        return transaction;
    }
    void Bind(AptRecoveryPackageManager &manager) {
        for (auto package = cache->PkgBegin(); !package.end(); ++package) {
            auto &state = (*cache.GetDepCache())[package]; if (!state.Install()) continue;
            const auto version = state.InstVerIter(*cache.GetDepCache());
            auto record = version.FileList(); while (!record.end() && record.File().Flagged(pkgCache::Flag::NotSource)) ++record;
            std::string error;
            Require(manager.BindArchive(version, record, root + "/archives/" + package.Name() + '_' + version.Arch() + ".deb", &error), error.c_str());
        }
    }
    RecoveryCaptureResult Capture(AptRecoveryPackageManager &manager, const std::function<bool()> &cancelled = {}, bool finiteEffects = false) {
        return manager.Capture(static_cast<pkgSourceList &>(cache), *records, runtime, Transaction(), binding, layout, cancelled, finiteEffects);
    }
    void Unchanged() {
        Require(Read(root + "/status") == statusBytes && Read(root + "/extended_states").empty(), "recording mutated package state");
        Require(std::filesystem::is_empty(root + "/log"), "recording invoked planner output/compressor");
    }
    void AcceptReview(const P::ReviewedTransaction &review) {
        P::ReviewPolicy policy; policy.layout = layout;
        auto &environment = policy.environment;
        environment.paths.dpkg = root + "/forbidden-dpkg";
        environment.paths.dpkgQuery = root + "/forbidden-dpkg-query";
        environment.paths.dpkgDeb = root + "/forbidden-dpkg-deb";
        environment.paths.dpkgRoot = "/"; environment.paths.dpkgAdmin = root;
        environment.configurationIdentity = binding.configurationIdentity;
        environment.policyIdentity = binding.policyIdentity; environment.methodsIdentity = "methods-1";
        environment.packageStateIdentity = binding.packageStateIdentity;
        environment.nativeArchitecture = runtime.architecture;
        environment.registeredArchitectures = runtime.registeredArchitectures;
        environment.acquisitionArchitectures = runtime.acquisitionArchitectures;
        P::ReviewAuthorization authorization; std::string error;
        Require(authorization.Accept(review, policy, &error), error.c_str());
    }
};
std::size_t Action(const P::ReviewedTransaction &review, const char *name, P::ExecutionAction kind,
                   const char *architecture = nullptr) {
    for (std::size_t i = 0; i < review.execution.actions.size(); ++i) {
        const auto &action = review.execution.actions[i];
        if (action.package.package == name && action.action == kind && (!architecture || action.package.architecture == architecture)) return i;
    }
    Require(false, "expected ordered action missing"); return 0;
}
void OrderedInstallAndProvenance() {
    Fixture fixture; fixture.Select("top", "amd64"); fixture.Select("portable", "amd64", "1:3.0~rc1-2");
    fixture.Select("twin", "amd64"); fixture.Select("twin", "i386");
    std::unique_ptr<pkgPackageManager> owner(new AptRecoveryPackageManager(fixture.cache.GetDepCache()));
    auto &manager = *static_cast<AptRecoveryPackageManager *>(owner.get()); fixture.Bind(manager);
    Configuration *const original = _config; const auto configuration(ConfigurationBytes());
    const auto result = fixture.Capture(manager); Require(result.status == RecoveryCaptureStatus::Recorded, result.errorCode.c_str());
    Require(_config == original && ConfigurationBytes() == configuration, "default smart ordering changed original configuration");
    const auto &review = result.review;
    Require(Action(review, "base", P::ExecutionAction::Configure) < Action(review, "top", P::ExecutionAction::Unpack), "APT Pre-Depends order changed");
    Require(result.preDependsArchives == std::set<std::string>{review.execution.actions[Action(review, "top", P::ExecutionAction::Unpack)].archive},
        "batching hints must come only from the exact selected record, not another version/architecture or ordinary Depends");
    Require(Action(review, "twin", P::ExecutionAction::Unpack, "amd64") != Action(review, "twin", P::ExecutionAction::Unpack, "i386"), "coinstalled architectures aliased");
    const auto &portable = review.execution.actions[Action(review, "portable", P::ExecutionAction::Unpack)];
    Require(portable.package.architecture == "all" && portable.package.version == "1:3.0~rc1-2", "exact all/version identity lost to native candidate");
    Require(review.execution.archives.size() == 5, "selected archive count changed");
    unsigned configured = 0;
    for (const auto &action : review.execution.actions) {
        if (action.action != P::ExecutionAction::Configure) continue;
        ++configured;
        Require(Action(review, action.package.package.c_str(), P::ExecutionAction::Unpack, action.package.architecture.c_str()) <
            Action(review, action.package.package.c_str(), P::ExecutionAction::Configure, action.package.architecture.c_str()),
            "explicit final configuration must follow exact-architecture unpack");
    }
    Require(configured == 5, "smart pending configuration was not expanded into exact reviewed actions");
    for (const auto &archive : review.execution.archives) {
        const auto record = Read(archive.sourceIndexPath).substr(archive.recordOffset, archive.recordSize);
        Require(record.find("Package: " + archive.package.package + '\n') == 0 && archive.sourceDefinitionOrdinal == 0 &&
            archive.sourceDefinitionPath == fixture.runtime.sourceListPath && archive.sourceIndexIdentity == "SHA256:" + SHA256(Read(fixture.index)),
            "manifest does not identify exact source definition/index/record");
    }
    std::string error;
    Require(P::ArchiveEvidenceSnapshot::Capture(fixture.runtime, review, "/usr/bin:/bin", {}, &error) != nullptr, error.c_str());
    fixture.AcceptReview(review);
    Require(owner->DoInstallPostFork(nullptr) == pkgPackageManager::Failed, "recording manager executed through base interface");
    Require(fixture.Capture(manager).errorCode == "recovery_capture_already_consumed", "mutable ordering reused");
    fixture.Unchanged();
}
void ConfigurationRestoration() {
    for (unsigned variant = 0; variant != 4; ++variant) {
        Fixture fixture; fixture.Select("portable", "amd64", "1:3.0~rc1-2");
        _config->Set("PackageManager::Configure", variant == 1 ? "all" : "smart");
        _config->Set("PackageManager::Configure::Fixture::", "first");
        _config->Set("PackageManager::Configure::Fixture::", "second");
        _config->Set("Dir::Log::Planner", fixture.root + "/log/unchanged.xz");
        _config->Set("Dir::Log::Planner::Fixture::", "retained");
        Configuration *const original = _config; const auto before(ConfigurationBytes());
        AptRecoveryPackageManager manager(fixture.cache.GetDepCache()); fixture.Bind(manager);
        bool threw = false;
        try {
            const auto result = fixture.Capture(manager, [&]() {
                if (_config == original) return false;
                if (variant == 3) throw std::runtime_error("cancelled ordering fixture");
                return variant == 2;
            });
            Require(variant == 2 ? result.status == RecoveryCaptureStatus::Cancelled : result.status == RecoveryCaptureStatus::Recorded,
                result.errorCode.c_str());
        } catch (const std::runtime_error &) { threw = true; }
        Require(threw == (variant == 3) && _config == original && ConfigurationBytes() == before,
            "ordering success, cancellation or exception failed to restore exact configuration object");
        fixture.Unchanged();
    }
}
void DependencyCycleRecording() {
    Fixture fixture; fixture.Select("cycle-a", "amd64");
    AptRecoveryPackageManager manager(fixture.cache.GetDepCache()); fixture.Bind(manager);
    const auto result(fixture.Capture(manager));
    Require(result.status == RecoveryCaptureStatus::Recorded, result.errorCode.c_str());
    const auto unpackA(Action(result.review, "cycle-a", P::ExecutionAction::Unpack));
    const auto unpackB(Action(result.review, "cycle-b", P::ExecutionAction::Unpack));
    const auto configureA(Action(result.review, "cycle-a", P::ExecutionAction::Configure));
    const auto configureB(Action(result.review, "cycle-b", P::ExecutionAction::Configure));
    Require(unpackA < configureA && unpackA < configureB && unpackB < configureA && unpackB < configureB &&
        (configureA + 1 == configureB || configureB + 1 == configureA),
        "cyclic Depends must retain libapt's adjacent configure group after both unpacks");
    fixture.AcceptReview(result.review); fixture.Unchanged();
}
void RemovalUsesInstalledVersion() {
    Fixture fixture; Require(fixture.cache->MarkDelete(fixture.Find("old"), false), "select removal");
    Require(fixture.cache->MarkDelete(fixture.Find("purge-me"), true), "select purge");
    Require(fixture.cache->MarkDelete(fixture.Find("legacy-other", "armhf"), false), "select unregistered installed removal");
    AptRecoveryPackageManager manager(fixture.cache.GetDepCache());
    const auto result = fixture.Capture(manager); Require(result.status == RecoveryCaptureStatus::Recorded, result.errorCode.c_str());
    const auto &old = result.review.execution.actions[Action(result.review, "old", P::ExecutionAction::Remove)];
    const auto &purge = result.review.execution.actions[Action(result.review, "purge-me", P::ExecutionAction::Purge)];
    Require(old.package.version == "1" && old.package.architecture == "all" && purge.package.version == "2" &&
        result.review.execution.archives.empty(), "remove/purge borrowed repository candidate metadata");
    Require(result.review.execution.actions[Action(result.review, "legacy-other", P::ExecutionAction::Remove)].package.architecture == "armhf",
        "an installed architecture cannot become impossible to remove after deregistration");
    fixture.AcceptReview(result.review);
    fixture.Unchanged();
}
void ResidualConfigurationPurge() {
    Fixture fixture;
    for (const char *name : {"residual", "residual-only"}) {
        const auto package(fixture.Find(name));
        Require(package->CurrentState == pkgCache::State::ConfigFiles && package.CurrentVer().end(),
            "residual fixture must have no installed CurrentVer");
        Require(fixture.cache->MarkDelete(package, true), "select residual purge");
    }
    AptRecoveryPackageManager manager(fixture.cache.GetDepCache());
    const auto result(fixture.Capture(manager));
    Require(result.status == RecoveryCaptureStatus::Recorded, result.errorCode.c_str());
    const auto &residual(result.review.execution.actions[Action(result.review, "residual", P::ExecutionAction::Purge)]);
    const auto &localOnly(result.review.execution.actions[Action(result.review, "residual-only", P::ExecutionAction::Purge)]);
    Require(residual.package.version == "1" && residual.package.architecture == "amd64" &&
        localOnly.package.version == "4" && localOnly.package.architecture == "all" &&
        result.review.execution.archives.empty(), "residual purge must retain exact local status version/arch without an archive");
    fixture.AcceptReview(result.review); fixture.Unchanged();
}
void FiniteTriggerRecording() {
    for (const char *state : {"install ok triggers-pending", "install ok triggers-awaited"}) {
        for (bool finite : {false, true}) {
            Fixture fixture(state); fixture.Select("top", "amd64");
            AptRecoveryPackageManager manager(fixture.cache.GetDepCache()); fixture.Bind(manager);
            const auto result = fixture.Capture(manager, {}, finite);
            if (!finite) Require(result.status != RecoveryCaptureStatus::Recorded &&
                result.errorCode == "recovery_pending_effects_unsupported", "legacy mode still refuses pending trigger state");
            else {
                Require(result.status == RecoveryCaptureStatus::Recorded, result.errorCode.c_str());
                Require(Action(result.review, "base", P::ExecutionAction::Configure) < Action(result.review, "top", P::ExecutionAction::Unpack),
                    "finite trigger mode preserves primary Pre-Depends barriers");
                Require(result.preDependsArchives == std::set<std::string>{result.review.execution.actions[
                    Action(result.review, "top", P::ExecutionAction::Unpack)].archive}, "finite mode retains exact local batching hints");
                for (const auto &action : result.review.execution.actions)
                    Require(action.action != P::ExecutionAction::Triggers && action.package.package != "cache",
                        "kept trigger recipient never receives a once-only primary action");
                fixture.AcceptReview(result.review);
            }
            fixture.Unchanged();
        }
    }
    {
        Fixture fixture; fixture.Select("top", "amd64"); _config->Set("DPkg::TriggersPending", true);
        AptRecoveryPackageManager manager(fixture.cache.GetDepCache()); fixture.Bind(manager);
        const auto before = ConfigurationBytes(); const auto result = fixture.Capture(manager, {}, true);
        Require(result.status == RecoveryCaptureStatus::Recorded && before == ConfigurationBytes(),
            "negotiated parent ledger replaces unqualified native pending markers without changing configuration");
        for (const auto &action : result.review.execution.actions)
            Require(action.action != P::ExecutionAction::Triggers, "no legacy trigger action survives finite mode");
        fixture.AcceptReview(result.review); fixture.Unchanged();
    }
    for (const char *state : {"install ok half-configured", "install reinstreq triggers-pending"}) {
        Fixture fixture(state); fixture.Select("top", "amd64");
        AptRecoveryPackageManager manager(fixture.cache.GetDepCache()); fixture.Bind(manager);
        const auto result = fixture.Capture(manager, {}, true);
        Require(result.status != RecoveryCaptureStatus::Recorded && result.errorCode == "recovery_pending_effects_unsupported",
            "finite trigger mode cannot admit unrelated pending configuration or reinstall-required state");
        fixture.Unchanged();
    }
}
void Refusals() {
    for (unsigned variant = 0; variant < 11; ++variant) {
        Fixture fixture; fixture.Select("portable", "amd64", "1:3.0~rc1-2");
        AptRecoveryPackageManager manager(fixture.cache.GetDepCache());
        if (variant != 0) fixture.Bind(manager);
        const char *expected = "recovery_selected_archive_unavailable";
        if (variant == 1) { _config->Set("DPkg::Pre-Invoke::", "touch " + fixture.root + "/forbidden"); expected = "recovery_hooks_unsupported"; }
        if (variant == 2) { _config->Set("APT::Planner", "external-command"); expected = "recovery_external_planner_unsupported"; }
        if (variant == 3) { _config->Set("DPkg::TriggersPending", true); expected = "recovery_unbounded_effects_unsupported"; }
        if (variant == 4) { Write(fixture.runtime.sourceListPath, "deb https://different.invalid/ ./\n"); expected = "recovery_source_association_ambiguous"; }
        if (variant == 5) { Write(fixture.runtime.sourcePartsDirectory + "/duplicate.list", "deb https://example.invalid/ ./\n"); expected = "recovery_source_association_ambiguous"; }
        if (variant == 6) { _config->Set("DPkg::Options::", "--pre-invoke=touch " + fixture.root + "/forbidden"); expected = "recovery_hooks_unsupported"; }
        if (variant == 7) expected = "recovery_cancelled";
        if (variant == 8) { _config->Set("RootDir", fixture.root); expected = "recovery_rootdir_ordering_unsupported"; }
        if (variant == 9) { _config->Set("PackageManager::Configure", "none"); expected = "recovery_configure_policy_unsupported"; }
        if (variant == 10) { _config->Set("DPkg::ConfigurePending", false); expected = "recovery_configure_policy_unsupported"; }
        const auto result = fixture.Capture(manager, variant == 7 ? std::function<bool()>([] { return true; }) : std::function<bool()>());
        const std::string reason("refusal case " + std::to_string(variant) + ": expected " + expected + ", got " + result.errorCode);
        Require(result.status != RecoveryCaptureStatus::Recorded && result.errorCode == expected &&
            result.review.execution.actions.empty() && result.preDependsArchives.empty(), reason.c_str());
        Require(!std::filesystem::exists(fixture.root + "/forbidden"), "hook was executed before refusal"); fixture.Unchanged();
    }
}
void FailedReviewDiscardsHints() {
    Fixture fixture; fixture.Select("top", "amd64");
    AptRecoveryPackageManager manager(fixture.cache.GetDepCache()); fixture.Bind(manager);
    auto transaction = fixture.Transaction(); transaction.installs.clear();
    const auto result = manager.Capture(static_cast<pkgSourceList &>(fixture.cache), *fixture.records, fixture.runtime,
        transaction, fixture.binding, fixture.layout);
    Require(result.status != RecoveryCaptureStatus::Recorded && result.errorCode == "recovery_transaction_changed" &&
        result.review.execution.archives.empty() && result.preDependsArchives.empty(),
        "post-recording coverage failure discards hints together with the exact review");
    fixture.Unchanged();
}
}
int main() {
    OrderedInstallAndProvenance(); ConfigurationRestoration(); DependencyCycleRecording();
    RemovalUsesInstalledVersion(); ResidualConfigurationPurge(); FiniteTriggerRecording(); Refusals(); FailedReviewDiscardsHints();
    std::cout << "[apt-recovery-recording] native ordering/provenance/refusal fixtures passed\n";
}
