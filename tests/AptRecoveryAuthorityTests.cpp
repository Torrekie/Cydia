/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryAuthority.hpp"
#include <apt-pkg/configuration.h>
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
    Require(!authority.securityPreferenceExplicit && authority.runtime.repositorySecurityMode == CydiaAPT::RepositorySecurityMode::Warning &&
        authority.configuredSecurity.at("Acquire::Check-Valid-Until") == "false" &&
        authority.configuredSecurity.at("Acquire::AllowWeakRepositories") == "true" &&
        !authority.configuredSecurity.count("APT::Get::AllowUnauthenticated") &&
        _config->Find("Cydia::AuthorityFixtureSentinel") == "keep",
        "absence preserves recovery warning default without overwriting clean APT settings or global configuration");
    before = authority;
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
    if (geteuid() == 0) ProtectedCases();
    std::cout << "[apt-recovery-authority] admission passed" <<
        (geteuid() == 0 ? "; protected capture, policy, closure and recheck fixtures passed\n" : "; protected fixtures require fakeroot\n");
    return 0;
}
