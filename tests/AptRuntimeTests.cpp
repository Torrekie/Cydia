/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptRuntime.hpp"
#include "Cydia/PackageDatabasePaths.hpp"

#include <apt-pkg/configuration.h>
#include <apt-pkg/pkgsystem.h>

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

Configuration *_config(NULL);
pkgSystem *_system(NULL);

namespace {

const CydiaAPT::InitializationOptions *gExpectedOptions(NULL);
const char *gExpectedLayout(NULL);
int gConfigInitCalls(0);
int gSystemInitCalls(0);
pkgSystem gTestSystem;

void Fail(const std::string &message) {
    std::cerr << "[verify-apt-runtime][FAIL] " << message << std::endl;
    std::exit(1);
}

void Expect(bool condition, const std::string &message) {
    if (!condition)
        Fail(message);
}

std::string JoinPath(const std::string &directory, const char *leaf) {
    return directory + '/' + leaf;
}

void ExpectValue(const Configuration &configuration, const char *key,
                 const std::string &expected, const char *stage) {
    const std::string actual(configuration.Find(key));
    if (actual != expected)
        Fail(std::string(gExpectedLayout) + ' ' + stage + " expected " + key + " = " + expected +
             ", got " + actual);
}

void ExpectBootstrapConfiguration(const Configuration &configuration, const char *stage) {
    const CydiaAPT::InitializationOptions &options(*gExpectedOptions);
    ExpectValue(configuration, "APT::Architecture", options.architecture, stage);
    ExpectValue(configuration, "Dir::Etc", options.aptConfigDirectory, stage);
    ExpectValue(configuration, "Dir::State::status", options.dpkgStatusPath, stage);
    ExpectValue(configuration, "Dir::Bin::dpkg", options.dpkgPath, stage);
    ExpectValue(configuration, "Dir::dpkg::cputable",
                JoinPath(options.dpkgDataDirectory, "cputable"), stage);
    ExpectValue(configuration, "Dir::dpkg::tupletable",
                JoinPath(options.dpkgDataDirectory, "tupletable"), stage);
    ExpectValue(configuration, "Dir::dpkg::triplettable",
                JoinPath(options.dpkgDataDirectory, "triplettable"), stage);
    ExpectValue(configuration, "DPkg::Path", options.dpkgExecutableSearchPath, stage);
}

void ExpectArchitectures(const Configuration &configuration,
                         const std::vector<std::string> &expected,
                         const char *stage) {
    const std::vector<std::string> actual(configuration.FindVector("APT::Architectures"));
    if (actual != expected)
        Fail(std::string(gExpectedLayout) + ' ' + stage + " architecture vector mismatch");
}

void OverrideBootstrapConfiguration(Configuration &configuration) {
    configuration.Set("APT::Architecture", "apt-conf-override");
    configuration.Set("Dir::Etc", "/apt-conf-override");
    configuration.Set("Dir::State::status", "/apt-conf-override/status");
    configuration.Set("Dir::Bin::dpkg", "/apt-conf-override/dpkg");
    configuration.Set("Dir::dpkg::cputable", "/apt-conf-override/cputable");
    configuration.Set("Dir::dpkg::tupletable", "/apt-conf-override/tupletable");
    configuration.Set("Dir::dpkg::triplettable", "/apt-conf-override/triplettable");
    configuration.Set("DPkg::Path", "/apt-conf-override/bin");
    configuration.Set("APT::Architectures::configured", "iphoneos-foreign-test");
}

CydiaAPT::InitializationOptions OptionsForLayout(
    const CydiaRuntime::PackageDatabasePaths &paths) {
    CydiaAPT::InitializationOptions options;
    options.architecture = paths.AptArchitecture();
    options.aptConfigDirectory = paths.AptConfigDirectory();
    options.methodsDirectory = paths.CydiaApplicationDirectory();
    options.cacheDirectory = "/tmp/cydia-apt-runtime/cache";
    options.stateDirectory = "/tmp/cydia-apt-runtime/state";
    options.listsDirectory = "/tmp/cydia-apt-runtime/state/lists";
    options.logDirectory = "/tmp/cydia-apt-runtime/log";
    options.dpkgStatusPath = paths.DpkgStatusPath();
    options.dpkgPath = paths.CydoPath();
    options.dpkgDataDirectory = paths.DpkgDataDirectory();
    options.dpkgExecutableSearchPath = paths.DpkgExecutableSearchPath();
    options.languages = "en";
    return options;
}

void VerifyLayout(CydiaRuntime::PackageDatabaseLayout layout, const char *name) {
    const CydiaRuntime::PackageDatabasePaths paths(
        CydiaRuntime::PackageDatabasePaths::ForLayout(layout));
    const CydiaAPT::InitializationOptions options(OptionsForLayout(paths));
    Configuration configuration;
    configuration.Set("APT::Architectures::stale", "stale-rootful-architecture");
    _config = &configuration;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = name;
    gConfigInitCalls = 0;
    gSystemInitCalls = 0;

    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture), std::string(name) + " initialization");
    Expect(gConfigInitCalls == 1, std::string(name) + " pkgInitConfig call count");
    Expect(gSystemInitCalls == 1, std::string(name) + " pkgInitSystem call count");
    Expect(_system == &gTestSystem, std::string(name) + " selected package system");
    Expect(architecture == options.architecture, std::string(name) + " reported architecture");
    ExpectBootstrapConfiguration(configuration, "after initialization");
    ExpectArchitectures(configuration, {"iphoneos-foreign-test"}, "after initialization");
}

} // namespace

bool pkgInitConfig(Configuration &configuration) {
    ++gConfigInitCalls;
    ExpectBootstrapConfiguration(configuration, "before pkgInitConfig");
    ExpectArchitectures(configuration, {}, "before pkgInitConfig");
    OverrideBootstrapConfiguration(configuration);
    return true;
}

bool pkgInitSystem(Configuration &configuration, pkgSystem *&system) {
    ++gSystemInitCalls;
    ExpectBootstrapConfiguration(configuration, "before pkgInitSystem");
    ExpectArchitectures(configuration, {"iphoneos-foreign-test"}, "before pkgInitSystem");
    system = &gTestSystem;
    return true;
}

int main() {
    const char *existingRoot(getenv("DPKG_ROOT"));
    const bool hadRoot(existingRoot != NULL);
    const std::string savedRoot(hadRoot ? existingRoot : "");
    setenv("DPKG_ROOT", "cydia-test-sentinel", 1);

    VerifyLayout(CydiaRuntime::PackageDatabaseLayout::Rootful, "rootful");
    VerifyLayout(CydiaRuntime::PackageDatabaseLayout::Rootless, "rootless");
    Expect(getenv("DPKG_ROOT") != NULL && strcmp(getenv("DPKG_ROOT"), "cydia-test-sentinel") == 0,
           "APT initialization must not change DPKG_ROOT");

    if (hadRoot)
        setenv("DPKG_ROOT", savedRoot.c_str(), 1);
    else
        unsetenv("DPKG_ROOT");

    std::cout << "[verify-apt-runtime][ ok ] bootstrap paths precede both APT initialization stages"
              << std::endl;
    return 0;
}
