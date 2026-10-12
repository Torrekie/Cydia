/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryAuthority.hpp"
#include "Cydia/AptRecoverySnapshot.hpp"
#include "Cydia/AptRecoveryInstalledAuthority.hpp"
#include "Cydia/AptRecoveryInitialization.hpp"
#include <apt-pkg/acquire-method.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

#ifndef CYDIA_RECOVERY_AUTHORITY_TESTING
#error This driver requires the isolated protected-environment fixture seam.
#endif

namespace {
namespace R = CydiaAPT::Recovery;
namespace P = CydiaRuntime::Privileged;
void Require(bool value, const char *message) {
    if (value) return;
    std::fprintf(stderr, "[apt-recovery-authority] %s\n", message); std::exit(1);
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file << bytes; file.close();
    Require(file.good() && chmod(path.c_str(), mode) == 0, "write isolated fixture input");
}
void MethodConfigurationCases() {
    char name[] = "/tmp/cydia-method-policy.XXXXXX";
    const int fd(mkstemp(name)); Require(fd >= 0, "create ambient method configuration"); close(fd);
    Write(name, "Cydia::MethodAmbient \"must-not-load\";\n");
    const char *ambient(std::getenv("APT_CONFIG")); const bool hadAmbient(ambient != nullptr);
    const std::string previous(ambient ? ambient : "");
    _config->Set("Cydia::OldMethodState", "must-not-retain");
    setenv("APT_CONFIG", name, 1);
    Require(CydiaAPT::InitializeRecoveryMethodConfiguration() && !std::getenv("APT_CONFIG") &&
        !_config->Exists("Cydia::OldMethodState") && !_config->Exists("Cydia::MethodAmbient"),
        "fresh method clears ambient options before protocol configuration");
    struct Method : pkgAcqMethod {
        Method() : pkgAcqMethod("1.0", SendConfig) {}
        bool Apply(const std::string &message) { return Configuration(message); }
    } method;
    Require(method.Apply("601 Configuration\nConfig-Item: Acquire::http::Timeout=37\n"
        "Config-Item: Dir::Etc::main=" + std::string(name) + "\n\n") &&
        _config->FindI("Acquire::http::Timeout") == 37 && _config->Find("Dir::Etc::main") == name,
        "real APT method protocol accepts owner-supplied configuration");
    Require(!ReadConfigFile(*_config, name) && !_config->Exists("Cydia::MethodAmbient"),
        "method cannot reread ambient files after protocol configuration");
    SetConfigurationReadValidator(nullptr, nullptr); _error->Discard(); _config->Clear();
    unlink(name);
    if (hadAmbient) setenv("APT_CONFIG", previous.c_str(), 1);
}
struct Fixture {
    std::string root;
    std::vector<std::string> files, directories;
    CydiaAPT::InitializationOptions startup;
    R::BundleInputs bundle;
    P::Environment environment;
    Fixture() {
        char cwd[4096]; Require(getcwd(cwd, sizeof(cwd)) != nullptr, "read fixture working directory");
        std::string pattern(std::string(cwd) + "/cydia-recovery-authority.XXXXXX");
        std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
        const char *created(mkdtemp(name.data())); Require(created != nullptr, "create fixture directory");
        root = created; directories.push_back(root);
        for (const char *directory : {"apt", "apt/apt.conf.d", "apt/sources.list.d", "apt/preferences.d",
             "apt/trusted.gpg.d", "bin", "methods", "data", "cache", "cache/archives", "state", "lists", "log", "admin", "install"})
            Directory(root + '/' + directory);
        startup.architecture = "iphoneos-arm"; startup.aptConfigDirectory = root + "/apt";
        startup.methodsDirectory = root + "/methods"; startup.cacheDirectory = root + "/cache";
        startup.stateDirectory = root + "/state"; startup.listsDirectory = root + "/lists";
        startup.logDirectory = root + "/log"; startup.dpkgStatusPath = root + "/admin/status";
        startup.bootstrapExtendedStatesPath = root + "/state/extended_states";
        startup.dpkgPath = startup.helperPath = root + "/bin/cydo";
        startup.nativeDpkgPath = root + "/bin/dpkg"; startup.packageInstallPrefix = "/var/jb";
        startup.privateRuntimeConfigurationPath = root + "/runtime.conf";
        startup.dpkgDataDirectory = root + "/data"; startup.dpkgExecutableSearchPath = root + "/bin:/usr/bin:/bin";
        startup.translation = "en"; startup.languages = "en"; startup.maxParallel = 4;
        environment.dpkgRoot = root + "/install"; environment.dpkgAdmin = root + "/admin";
        environment.dpkg = startup.nativeDpkgPath; environment.dpkgQuery = root + "/bin/dpkg-query";
        environment.dpkgDeb = root + "/bin/dpkg-deb"; environment.gpg = root + "/bin/gpg";
        environment.extendedStates = startup.bootstrapExtendedStatesPath;
        environment.sourceList = root + "/apt/sources.list"; environment.sourceParts = root + "/apt/sources.list.d";
        environment.preferences = root + "/apt/preferences"; environment.preferencesParts = root + "/apt/preferences.d";
        environment.trusted = root + "/apt/trusted.gpg"; environment.trustedParts = root + "/apt/trusted.gpg.d";
        bundle.executable = root + "/bin/recovery"; bundle.libraries = {root + "/private-library"};
        bundle.dataFiles = {root + "/private-data"}; bundle.requiredMethods = {"http", "https"};
        for (const char *name : {"cydo", "recovery", "dpkg", "dpkg-query", "dpkg-deb", "gpg"})
            File(root + "/bin/" + name, "#!/bin/sh\nexit 0\n", 0755);
        for (const char *name : {"http", "https"}) File(root + "/methods/" + name, "#!/bin/sh\nexit 0\n", 0755);
        for (const auto &path : {root + "/private-library", root + "/private-data", root + "/data/cputable", root + "/data/tupletable", startup.dpkgStatusPath})
            File(path, "fixture data\n");
        File(root + "/apt/apt.conf", Configuration());
        Dpkg("iphoneos-arm64", "iphoneos-arm64e");
    }
    ~Fixture() {
        for (const auto &file : files) unlink(file.c_str());
        for (auto i = directories.rbegin(); i != directories.rend(); ++i) rmdir(i->c_str());
    }
    void Directory(const std::string &path) {
        Require(mkdir(path.c_str(), 0755) == 0, "create fixture subdirectory"); directories.push_back(path);
    }
    void File(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
        Write(path, bytes, mode); files.push_back(path);
    }
    std::string Configuration() const {
        return "APT::Architecture \"configured-foreign\";\n"
            "APT::Architectures { \"apt-only-arch\"; \"all\"; };\n"
            "Acquire::Check-Valid-Until \"false\";\n"
            "Acquire::AllowWeakRepositories \"true\";\n"
            "DPkg::Options { \"--instdir=" + environment.dpkgRoot + "\"; \"--force-confdef\"; };\n"
            "Cydia::Package-Install-Prefix \"" + environment.dpkgRoot + "/var/jb\";\n"
            "Cydia::APT::ManagedSourceList \"local.list\";\n";
    }
    void Dpkg(const std::string &native, const std::string &foreign) {
        // Only the module's two bounded, read-only architecture invocations
        // are accepted. No system package database or network is involved.
        Write(environment.dpkg, "#!/bin/sh\ncase \"$3\" in\n"
            "--print-architecture) printf '%s\\n' '" + native + "' ;;\n"
            "--print-foreign-architectures) " + (foreign.empty() ? std::string(":") : "printf '%s\\n' '" + foreign + "'") + " ;;\n"
            "*) exit 71 ;;\nesac\n", 0755);
    }
    R::FixtureResolver Resolver() const {
        return [this](const CydiaRuntime::PackageDatabasePaths &, const std::string &overridePath, P::Environment *result, P::Error *error) {
            *result = environment; result->aptConfigOverride = overridePath;
            for (const auto &path : {environment.dpkgRoot, environment.dpkgAdmin}) {
                P::Evidence evidence;
                if (!P::CapturePathIdentity(path, true, false, &evidence, error)) return false;
                result->evidence.push_back(evidence);
            }
            for (const auto &path : {environment.dpkg, environment.dpkgQuery, environment.dpkgDeb}) {
                P::Evidence evidence;
                if (!P::CapturePathIdentity(path, false, true, &evidence, error)) return false;
                result->evidence.push_back(evidence);
            }
            return true;
        };
    }
};
R::DependencyProof FixtureProof(const R::Authority &authority, const std::string &inventory,
                              const std::function<bool()> &) {
    // A synthetic trusted-inspector fixture, deliberately not a production
    // architecture/dependency checker. Real activation must supply that check.
    Require(!authority.configuration.empty() && authority.runtime.architecture == "iphoneos-arm64",
        "inspector receives exact configuration and selected architecture");
    R::DependencyProof proof; proof.inventoryIdentity = inventory; proof.loaderIdentity = "fixture-inspector-v1";
    for (const auto &component : authority.components) proof.nonPlatformDependencies.push_back(component.path);
    return proof;
}
bool Resolve(Fixture &fixture, const std::string &preference, const R::Identity *expected,
             R::Authority *authority, P::Error *error,
             const R::DependencyInspector &inspect = FixtureProof,
             const std::function<bool()> &cancelled = {}) {
    return R::ResolveAuthorityForTesting(CydiaRuntime::PackageDatabasePaths::ForLayout(CydiaRuntime::PackageDatabaseLayout::Rootful),
        fixture.startup, "", preference, fixture.bundle, expected, authority, error,
        fixture.Resolver(), inspect, 4000, cancelled);
}
void AdmissionCases() {
    R::Identity first; first.configuration = "first"; auto second(first);
    Require(R::SameIdentity(first, second), "exact identity comparison"); second.dependencies = "changed";
    Require(!R::SameIdentity(first, second), "closure changes invalidate authority");
    R::Authority result; result.executable = "stale"; P::Error error;
    Require(!R::ResolveAuthority(CydiaRuntime::PackageDatabasePaths::ForLayout(CydiaRuntime::PackageDatabaseLayout::Rootful),
        {}, "", "", {}, nullptr, &result, &error) && error.code == "recovery_invalid_request" && result.executable.empty(),
        "untrusted or incomplete seeds clear prior authority without reading host files");
    const auto inventory = [](const std::vector<std::string> &libraries, const std::vector<std::string> &data,
            const std::vector<std::string> &methods) {
        return P::SerializeFields({"CYDIA-RECOVERY-PAYLOAD-1", P::SerializeFields(libraries),
            P::SerializeFields(data), P::SerializeFields(methods)});
    };
    R::BundleInputs bundle;
    Require(R::ParsePayloadInventory(inventory({"/fixture/libprivate.dylib"}, {"/fixture/data"}, {"http", "https"}),
        "/fixture/cydia-recovery", &bundle, &error) && bundle.executable == "/fixture/cydia-recovery", "payload inventory uses fixed parent executable");
    Require(!R::ParsePayloadInventory(inventory({"/fixture/duplicate"}, {"/fixture/duplicate"}, {"http"}),
        "/fixture/cydia-recovery", &bundle, &error), "duplicate cross-role payload path rejected");
    Require(!R::ParsePayloadInventory(inventory({}, {}, {"../http"}), "/fixture/cydia-recovery", &bundle, &error) &&
        !R::ParsePayloadInventory(inventory({}, {}, {}), "/fixture/cydia-recovery", &bundle, &error), "invalid or missing required methods rejected");
    Require(!R::ParsePayloadInventory(std::string(128 * 1024 + 1, 'x'), "/fixture/cydia-recovery", &bundle, &error) &&
        !R::ParsePayloadInventory(P::SerializeFields({"CYDIA-PROVIDER-REGISTRATION-1"}), "/fixture/cydia-recovery", &bundle, &error),
        "oversized or other-authority inventory rejected");
}
void InitializationCases() {
    Fixture fixture; R::Authority authority; P::Error error; R::Snapshot snapshot;
    unsetenv("APT_CONFIG");
    Require(Resolve(fixture, "warning", nullptr, &authority, &error) &&
        R::MakeSnapshot(authority, std::string(64, 'a'), &snapshot), "prepare real captured initializer capsule");
    const std::string marker(fixture.root + "/unexpected-query"); fixture.files.push_back(marker);
    Write(fixture.environment.dpkg, "#!/bin/sh\nprintf probe > '" + marker + "'\nexit 71\n", 0755);
    fixture.File(fixture.root + "/ambient.conf", "APT::Architecture \"wrong-ambient\";\n");
    setenv("APT_CONFIG", (fixture.root + "/ambient.conf").c_str(), 1);
    std::string code;
    Require(CydiaAPT::InitializeRecoverySnapshot(snapshot, &code), "initialize solely from captured native APT configuration");
    Require(CydiaAPT::Architecture() == snapshot.runtime.architecture &&
        CydiaAPT::Architectures() == snapshot.runtime.acquisitionArchitectures &&
        CydiaAPT::RegisteredArchitectures() == snapshot.runtime.registeredArchitectures &&
        CydiaAPT::SourceListPath() == snapshot.runtime.sourceListPath &&
        CydiaAPT::DpkgOptions() == snapshot.runtime.dpkgOptions && CydiaAPT::MutationEnvironmentValid(), "complete captured runtime is published coherently");
    Require(access(marker.c_str(), F_OK) != 0 && getenv("APT_CONFIG") == nullptr &&
        _config->Find("Dir::Bin::dpkg") == "/dev/null" &&
        _config->Find("Acquire::Check-Valid-Until") == "false" &&
        CydiaAPT::GetRepositorySecurityMode() == CydiaAPT::RepositorySecurityMode::Warning &&
        !CydiaAPT::CachedRepositoryTrustValid() && !CydiaAPT::ActiveRuntimeDescriptor(),
        "no architecture child, ambient read, direct dpkg endpoint, invented trust or external adoption");
    auto invalid(snapshot); invalid.configuration += "\n#include \"" + fixture.root + "/ambient.conf\";\n";
    Require(!CydiaAPT::InitializeRecoverySnapshot(invalid, &code) && code == "recovery_configuration_invalid" &&
        !CydiaAPT::MutationEnvironmentValid(), "captured parser denies include reads and fails closed");
    _error->Discard();
    invalid = snapshot; invalid.configuration += "\nDir::State::Lists \"/unexpected/lists\";\n";
    Require(!CydiaAPT::InitializeRecoverySnapshot(invalid, &code) && code == "recovery_environment_mismatch",
        "parsed paths cannot contradict parent descriptor");
    _error->Discard();
    Require(CydiaAPT::InitializeRecoverySnapshot(snapshot, &code), "fresh valid capsule may initialize after parser refusal");
}
void ProtectedCases() {
    Fixture fixture; R::Authority authority, before; P::Error error;
    Require(P::ValidateRootOwnedPath(fixture.root, true, false, &error), "fixture needs protected working-directory ancestry under fakeroot");
    const char *ambient(std::getenv("APT_CONFIG")); const bool hadAmbient(ambient != nullptr);
    const std::string previousAmbient(ambient ? ambient : ""); unsetenv("APT_CONFIG");
    _config->Set("Cydia::AuthorityFixtureSentinel", "keep");
    Require(!Resolve(fixture, "", nullptr, &authority, &error, {}) &&
        error.code == "recovery_dependency_closure_unverified" && !authority.runtime.mutationEnvironmentValid &&
        authority.unresolvedFields == std::vector<std::string>({"dependencyClosure", "componentLoadability", "configuredCommandClosure"}),
        "file presence cannot fabricate dependency closure or executable readiness");
    Require(Resolve(fixture, "", nullptr, &authority, &error), "capture isolated protected recovery authority");
    Require(authority.runtime.origin == CydiaAPT::RuntimeDescriptorOrigin::Embedded && authority.runtime.binding.session.empty() &&
        authority.runtime.binding.packageStateIdentity.empty() && authority.runtime.mutationEnvironmentValid,
        "capture does not invent a worker session or package-state token");
    Require(authority.runtime.registeredArchitectures == std::vector<std::string>({"iphoneos-arm64", "iphoneos-arm64e"}) &&
        authority.runtime.acquisitionArchitectures == std::vector<std::string>({"iphoneos-arm64", "apt-only-arch", "all"}) &&
        authority.runtime.packageInstallPrefix == "/var/jb" && authority.runtime.dpkgRootDirectory == fixture.environment.dpkgRoot,
        "native, foreign, acquisition policy and root-relative layout remain distinct");
    Require(authority.runtime.sourceListPath == fixture.environment.sourceList &&
        authority.runtime.managedSourceListPath == fixture.environment.sourceParts + "/local.list" &&
        authority.runtime.extendedStatesPath == fixture.environment.extendedStates &&
        authority.archivesDirectory == fixture.startup.cacheDirectory + "/archives" &&
        authority.runtime.dpkgOptions == std::vector<std::string>({"--instdir=" + fixture.environment.dpkgRoot, "--force-confdef"}),
        "sources, shared state, archives and protected options survive capture");
    const std::string privateBin(fixture.root + "/bin/recovery-bin/");
    Require(authority.executableSearchPath == fixture.startup.dpkgExecutableSearchPath &&
        authority.acquisitionSearchPath == privateBin.substr(0, privateBin.size() - 1) + ':' + authority.executableSearchPath &&
        authority.runtime.gpgExecutablePath == fixture.environment.gpg,
        "private acquisition helpers do not replace the parent dpkg path or native key-import verifier");
    for (const char *tool : {"apt-key", "apt-config", "gpg", "gpgv"})
        Require(authority.configuration.find(std::string("Dir::Bin::") + tool + " \"" + privateBin + tool + "\";") != std::string::npos,
            "private helper defaults are captured before protected APT configuration");
    Require(authority.configuration.find("APT::Key::gpgcommand \"" + privateBin + "gpg\";") != std::string::npos &&
        authority.configuration.find("APT::Key::gpgvcommand \"" + privateBin + "gpgv\";") != std::string::npos,
        "signature verification uses independently captured private defaults");
    R::Authority configured;
    Write(fixture.root + "/apt/apt.conf", fixture.Configuration() +
        "Dir::Bin::apt-key \"/explicit/apt-key\"; Dir::Bin::apt-config \"/explicit/apt-config\";\n"
        "Dir::Bin::gpg \"/explicit/gpg\"; Dir::Bin::gpgv \"/explicit/gpgv\";\n"
        "Apt::Key::gpgcommand \"/explicit/signature-gpg\"; Apt::Key::gpgvcommand \"/explicit/signature-gpgv\";\n");
    Require(Resolve(fixture, "", nullptr, &configured, &error) &&
        configured.configuration.find("Dir::Bin::apt-key \"/explicit/apt-key\";") != std::string::npos &&
        configured.configuration.find("Dir::Bin::apt-config \"/explicit/apt-config\";") != std::string::npos &&
        configured.configuration.find("Dir::Bin::gpg \"/explicit/gpg\";") != std::string::npos &&
        configured.configuration.find("Dir::Bin::gpgv \"/explicit/gpgv\";") != std::string::npos &&
        configured.configuration.find("APT::Key::gpgcommand \"/explicit/signature-gpg\";") != std::string::npos &&
        configured.configuration.find("APT::Key::gpgvcommand \"/explicit/signature-gpgv\";") != std::string::npos &&
        configured.identity.configuration != authority.identity.configuration &&
        configured.runtime.gpgExecutablePath == fixture.environment.gpg,
        "protected helper choices override defaults without changing native key-import policy");
    Write(fixture.root + "/apt/apt.conf", fixture.Configuration());
    Require(Resolve(fixture, "", nullptr, &authority, &error), "recapture restored helper configuration baseline");
    Require(!authority.securityPreferenceExplicit && authority.runtime.repositorySecurityMode == CydiaAPT::RepositorySecurityMode::Warning &&
        authority.configuredSecurity.at("Acquire::Check-Valid-Until") == "false" &&
        authority.configuredSecurity.at("Acquire::AllowWeakRepositories") == "true" &&
        !authority.configuredSecurity.count("APT::Get::AllowUnauthenticated") &&
        _config->Find("Cydia::AuthorityFixtureSentinel") == "keep",
        "absence preserves recovery warning default without overwriting clean APT settings or global configuration");
    before = authority;
    const std::string externalLibrary(fixture.root + "/bootstrap-library.dylib"), externalBytes("external dependency\n");
    fixture.File(externalLibrary, externalBytes);
    Hashes externalHash(Hashes::SHA256SUM);
    Require(externalHash.Add(externalBytes.data(), externalBytes.size()), "hash discovered dependency fixture");
    const auto discoveredInspector = [&](const R::Authority &captured, const std::string &inventory,
            const std::function<bool()> &cancelled) {
        auto proof = FixtureProof(captured, inventory, cancelled);
        R::Component component; component.path = externalLibrary;
        component.sha256 = externalHash.GetHashString(Hashes::SHA256SUM).HashValue();
        proof.discoveredComponents.push_back(component); proof.nonPlatformDependencies.push_back(component.path);
        return proof;
    };
    Require(Resolve(fixture, "", nullptr, &authority, &error, discoveredInspector) &&
        authority.components.size() == before.components.size() + 1 &&
        authority.identity.dependencies != before.identity.dependencies,
        "trusted parent discovers external dpkg libraries without changing private inventory");
    const auto discoveredIdentity(authority.identity);
    Require(Resolve(fixture, "", &discoveredIdentity, &authority, &error, discoveredInspector),
        "unchanged discovered dependency is independently recaptured");
    Write(externalLibrary, "changed dependency\n");
    Require(!Resolve(fixture, "", nullptr, &authority, &error, discoveredInspector) && error.code == "recovery_component_changed",
        "reported dependency hash cannot replace parent recapture");
    Require(Resolve(fixture, "warning", nullptr, &authority, &error) && authority.securityPreferenceExplicit &&
        authority.identity.configuration == before.identity.configuration && authority.identity.policy != before.identity.policy,
        "explicit warning remains distinguishable from no saved choice");
    for (const char *preference : {"allow", "warning", "error", "distribution"})
        Require(Resolve(fixture, preference, nullptr, &authority, &error) && authority.securityPreferenceExplicit &&
            authority.runtime.repositorySecurityMode == CydiaAPT::RepositorySecurityModeFromString(preference), "saved security choices remain exact");
    Require(Resolve(fixture, "", &before.identity, &authority, &error), "unchanged protected inputs can be recaptured");
    fixture.Dpkg("iphoneos-arm64", "");
    Require(Resolve(fixture, "", nullptr, &authority, &error) &&
        authority.runtime.registeredArchitectures == std::vector<std::string>({"iphoneos-arm64"}) &&
        authority.identity.configuration != before.identity.configuration,
        "native-only dpkg registration remains exact and changes invalidate configuration identity");
    fixture.Dpkg("iphoneos-arm64", "iphoneos-arm64e");
    Require(Resolve(fixture, "", nullptr, &before, &error), "capture restored architecture baseline");
    auto invalidProof = [](const R::Authority &a, const std::string &i, const std::function<bool()> &c) {
        auto proof(FixtureProof(a, i, c)); proof.inventoryIdentity = "another-inventory"; return proof;
    };
    Require(!Resolve(fixture, "", nullptr, &authority, &error, invalidProof) && error.code == "recovery_dependency_proof_invalid" &&
        authority.components.empty(), "a proof for other component bytes cannot publish authority");
    auto missingDependency = [](const R::Authority &a, const std::string &i, const std::function<bool()> &c) {
        auto proof(FixtureProof(a, i, c)); proof.nonPlatformDependencies.push_back("/not-in-inventory"); return proof;
    };
    Require(!Resolve(fixture, "", nullptr, &authority, &error, missingDependency) && error.code == "recovery_dependency_proof_invalid",
        "an unverified non-platform dependency is never assumed available");
    auto racingDependency = [&](const R::Authority &a, const std::string &i, const std::function<bool()> &c) {
        auto proof(FixtureProof(a, i, c)); Write(fixture.bundle.libraries.front(), "replacement library\n"); return proof;
    };
    Require(!Resolve(fixture, "", nullptr, &authority, &error, racingDependency) && error.code == "recovery_component_changed",
        "component replacement during dependency inspection invalidates the capture");
    Require(!Resolve(fixture, "", &before.identity, &authority, &error) && error.code == "recovery_authority_changed",
        "changed component content cannot reuse prior authority");
    Require(Resolve(fixture, "", nullptr, &before, &error), "capture replacement baseline");
    Write(fixture.root + "/apt/apt.conf", fixture.Configuration() + "Acquire::Check-Valid-Until \"true\";\n");
    Require(!Resolve(fixture, "", &before.identity, &authority, &error) && error.code == "recovery_authority_changed",
        "protected policy edits require fresh authority");
    Write(fixture.root + "/apt/apt.conf", fixture.Configuration());
    const auto sourceParts(fixture.environment.sourceParts); fixture.environment.sourceParts += "-other";
    Require(!Resolve(fixture, "", nullptr, &authority, &error) && error.code == "recovery_environment_mismatch",
        "private APT cannot silently choose a different source environment");
    fixture.environment.sourceParts = sourceParts;
    Require(!Resolve(fixture, "", nullptr, &authority, &error, FixtureProof, [] { return true; }) && error.code == "recovery_capture_cancelled",
        "cancelled capture cannot retain a prior authority");
    fixture.Dpkg("all", "iphoneos-arm64e");
    Require(!Resolve(fixture, "", nullptr, &authority, &error) && error.code == "recovery_architecture_query_failed",
        "all cannot be misrepresented as a dpkg native architecture");
    fixture.Dpkg("iphoneos-arm64", "iphoneos-arm64e");
    Require(unlink((fixture.root + "/methods/https").c_str()) == 0, "remove required fixture method");
    Require(!Resolve(fixture, "", nullptr, &authority, &error) && error.code == "recovery_method_missing", "missing acquisition methods fail explicitly");
    Write(fixture.root + "/methods/https", "#!/bin/sh\nexit 0\n", 0755);
    Require(unlink((fixture.root + "/data/tupletable").c_str()) == 0, "remove fixture architecture table");
    Require(!Resolve(fixture, "", nullptr, &authority, &error) && error.code == "recovery_architecture_tables_unavailable",
        "architecture names alone do not prove private APT policy data is available");
    Write(fixture.root + "/data/tupletable", "fixture data\n");
    setenv("APT_CONFIG", (fixture.root + "/apt/apt.conf").c_str(), 1);
    Require(!Resolve(fixture, "", nullptr, &authority, &error) && error.code == "recovery_ambient_configuration",
        "ambient APT_CONFIG is not protected override authority"); unsetenv("APT_CONFIG");
    Write(fixture.root + "/apt/apt.conf", fixture.Configuration() + "RootDir \"" + fixture.root + "\";\n");
    Require(!Resolve(fixture, "", nullptr, &authority, &error) && error.code == "recovery_double_root", "already rooted paths cannot be rooted twice");
    Write(fixture.root + "/apt/apt.conf", fixture.Configuration() +
        "Dir::Etc::sourcelist \"-\"; Dir::Etc::sourceparts \"-\"; Cydia::APT::ManagedSourceList \"\";\n");
    fixture.environment.sourceList.clear(); fixture.environment.sourceParts.clear();
    Require(Resolve(fixture, "distribution", nullptr, &authority, &error) && authority.runtime.sourceListPath.empty() &&
        authority.runtime.sourcePartsDirectory.empty(), "disabled source inputs remain disabled");
    _config->Clear("Cydia::AuthorityFixtureSentinel");
    if (hadAmbient) setenv("APT_CONFIG", previousAmbient.c_str(), 1);
}
}
int main() {
    AdmissionCases();
    if (geteuid() == 0) { ProtectedCases(); InitializationCases(); }
    MethodConfigurationCases();
    std::cout << "[apt-recovery-authority] admission passed" <<
        (geteuid() == 0 ? "; protected capture, policy, closure and recheck fixtures passed\n" : "; protected fixtures require fakeroot\n");
    return 0;
}
