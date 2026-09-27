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
const char *gExpectedRootDir("");
int gConfigInitCalls(0);
int gSystemInitCalls(0);
pkgSystem gTestSystem;
enum class SourceFixture {
    Relative,
    CustomEtcRelative,
    Defaults,
    RootedRelative,
    RootedAbsolute,
    RootedDevNull,
    DevNull,
    InvalidManaged,
};
SourceFixture gSourceFixture(SourceFixture::Relative);

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

std::string ExpectedEtcDirectory() {
    return gSourceFixture == SourceFixture::CustomEtcRelative
        ? std::string("/maintainer-apt")
        : gExpectedOptions->aptConfigDirectory;
}

void ExpectBootstrapConfiguration(const Configuration &configuration, const char *stage,
                                  const std::string &expectedEtc) {
    const CydiaAPT::InitializationOptions &options(*gExpectedOptions);
    ExpectValue(configuration, "APT::Architecture", options.architecture, stage);
    ExpectValue(configuration, "Dir::Etc", expectedEtc, stage);
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

void ExpectRootDirectory(const Configuration &configuration, const char *stage) {
    ExpectValue(configuration, "RootDir", gExpectedRootDir, stage);
}

void ExpectArchitectures(const Configuration &configuration,
                         const std::vector<std::string> &expected,
                         const char *stage) {
    const std::vector<std::string> actual(configuration.FindVector("APT::Architectures"));
    if (actual != expected)
        Fail(std::string(gExpectedLayout) + ' ' + stage + " architecture vector mismatch");
}

std::string PrefixExpectedRoot(const std::string &path) {
    if (gExpectedRootDir[0] == '\0' || std::strcmp(gExpectedRootDir, "/") == 0)
        return path;

    std::string result(gExpectedRootDir);
    while (result.size() > 1 && result[result.size() - 1] == '/')
        result.erase(result.size() - 1);
    if (!path.empty() && path[0] != '/')
        result += '/';
    result += path;
    return result;
}

std::string ExpectedSourceListPath() {
    return PrefixExpectedRoot(
        ExpectedEtcDirectory() + "/maintainer.sources");
}

std::string ExpectedSourcePartsDirectory() {
    return PrefixExpectedRoot(
        ExpectedEtcDirectory() + "/parts");
}

std::string ExpectedDefaultSourceListPath() {
    return PrefixExpectedRoot(
        ExpectedEtcDirectory() + "/sources.list");
}

std::string ExpectedDefaultSourcePartsDirectory() {
    return PrefixExpectedRoot(
        ExpectedEtcDirectory() + "/sources.list.d/");
}

void ExpectSourceConfiguration(const Configuration &configuration, const char *stage) {
    const std::string actualList(configuration.FindFile("Dir::Etc::sourcelist", "sources.list"));
    const std::string actualParts(configuration.FindDir("Dir::Etc::sourceparts", "sources.list.d"));
    if (gSourceFixture == SourceFixture::DevNull ||
        gSourceFixture == SourceFixture::RootedDevNull) {
        if (actualList != PrefixExpectedRoot("/dev/null") ||
            actualParts != PrefixExpectedRoot("/dev/null"))
            Fail(std::string(gExpectedLayout) + ' ' + stage + " disabled source paths changed");
        return;
    }

    if (gSourceFixture == SourceFixture::Defaults) {
        if (actualList != ExpectedDefaultSourceListPath() ||
            actualParts != ExpectedDefaultSourcePartsDirectory())
            Fail(std::string(gExpectedLayout) + ' ' + stage + " default source paths changed");
        return;
    }

    std::string expectedParts(ExpectedSourcePartsDirectory());
    expectedParts += '/';
    if (actualList != ExpectedSourceListPath() || actualParts != expectedParts)
        Fail(std::string(gExpectedLayout) + ' ' + stage + " maintainer source paths changed");
}

void OverrideBootstrapConfiguration(Configuration &configuration) {
    configuration.Set("APT::Architecture", "apt-conf-override");
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

CydiaAPT::InitializationOptions RootedOptions() {
    const CydiaRuntime::PackageDatabasePaths paths(
        CydiaRuntime::PackageDatabasePaths::ForLayout(
            CydiaRuntime::PackageDatabaseLayout::Rootful));
    CydiaAPT::InitializationOptions options(OptionsForLayout(paths));
    /* APT's RootDir is a coordinate-system prefix.  This fixture deliberately
     * supplies an unrooted Dir::Etc so FindFile/FindDir can prove that the
     * maintainer prefix is applied exactly once. */
    options.aptConfigDirectory = "/etc/apt";
    return options;
}

void VerifyRootedSourceConfiguration() {
    const CydiaAPT::InitializationOptions options(RootedOptions());
    Configuration configuration;
    /* Seed values from a prior bootstrap. Initialize must discard them before
     * pkgInitConfig installs the current maintainer RootDir and source keys. */
    configuration.Set("RootDir", "/stale-root");
    configuration.Set("Dir::Etc::sourcelist", "/stale/sources.list");
    configuration.Set("Dir::Etc::sourceparts", "/stale/sources.list.d");
    configuration.Set("Cydia::APT::ManagedSourceList", "stale.list");
    _config = &configuration;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = "rootdir";
    gExpectedRootDir = "/cydia-test-root";
    gConfigInitCalls = 0;
    gSystemInitCalls = 0;
    gSourceFixture = SourceFixture::RootedAbsolute;

    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture), "rootdir initialization");
    Expect(gConfigInitCalls == 1, "rootdir pkgInitConfig call count");
    Expect(gSystemInitCalls == 1, "rootdir pkgInitSystem call count");
    ExpectRootDirectory(configuration, "rootdir after initialization");
    ExpectSourceConfiguration(configuration, "rootdir after initialization");
    Expect(CydiaAPT::SourceListPath() == ExpectedSourceListPath(),
           "rootdir maintainer source list resolution");
    Expect(CydiaAPT::SourcePartsDirectory() == ExpectedSourcePartsDirectory(),
           "rootdir maintainer sourceparts resolution");
    Expect(CydiaAPT::ManagedSourceListPath() ==
               ExpectedSourcePartsDirectory() + "/cydia-managed.list",
               "rootdir managed source leaf resolution");
}

void VerifyRootedDisabledSourceConfiguration() {
    const CydiaAPT::InitializationOptions options(RootedOptions());
    Configuration configuration;
    configuration.Set("RootDir", "/stale-root");
    configuration.Set("Dir::Etc::sourcelist", "/stale/sources.list");
    configuration.Set("Dir::Etc::sourceparts", "/stale/sources.list.d");
    _config = &configuration;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = "rootdir-dev-null";
    gExpectedRootDir = "/cydia-test-root";
    gConfigInitCalls = 0;
    gSystemInitCalls = 0;
    gSourceFixture = SourceFixture::RootedDevNull;

    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture),
           "rootdir disabled-source initialization");
    ExpectRootDirectory(configuration, "rootdir disabled-source after initialization");
    ExpectSourceConfiguration(configuration, "rootdir disabled-source after initialization");
    Expect(CydiaAPT::SourceListPath().empty(),
           "rootdir disabled source list is empty");
    Expect(CydiaAPT::SourcePartsDirectory().empty(),
           "rootdir disabled sourceparts is empty");
    Expect(CydiaAPT::ManagedSourceListPath().empty(),
           "rootdir disabled managed source is empty");
}

void VerifyDefaultSourceConfigurationClearsStaleValues() {
    const CydiaRuntime::PackageDatabasePaths paths(
        CydiaRuntime::PackageDatabasePaths::ForLayout(
            CydiaRuntime::PackageDatabaseLayout::Rootful));
    const CydiaAPT::InitializationOptions options(OptionsForLayout(paths));
    Configuration configuration;
    configuration.Set("RootDir", "/stale-root");
    configuration.Set("Dir::Etc::sourcelist", "/stale/sources.list");
    configuration.Set("Dir::Etc::sourceparts", "/stale/sources.list.d");
    configuration.Set("Cydia::APT::ManagedSourceList", "stale.list");
    _config = &configuration;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = "defaults";
    gExpectedRootDir = "";
    gConfigInitCalls = 0;
    gSystemInitCalls = 0;
    gSourceFixture = SourceFixture::Defaults;

    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture), "default source initialization");
    ExpectRootDirectory(configuration, "defaults after initialization");
    ExpectSourceConfiguration(configuration, "defaults after initialization");
    Expect(CydiaAPT::SourceListPath() == ExpectedDefaultSourceListPath(),
           "default source list resolution");
    Expect(CydiaAPT::SourcePartsDirectory() ==
               ExpectedEtcDirectory() + "/sources.list.d",
           "default sourceparts resolution");
    Expect(CydiaAPT::ManagedSourceListPath().empty(),
           "default managed source remains disabled");
}

void VerifyLayout(CydiaRuntime::PackageDatabaseLayout layout, const char *name) {
    const CydiaRuntime::PackageDatabasePaths paths(
        CydiaRuntime::PackageDatabasePaths::ForLayout(layout));
    const CydiaAPT::InitializationOptions options(OptionsForLayout(paths));
    Configuration configuration;
    configuration.Set("APT::Architectures::stale", "stale-rootful-architecture");
    configuration.Set("Cydia::APT::ManagedSourceList", "stale.list");
    _config = &configuration;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = name;
    gExpectedRootDir = "";
    gConfigInitCalls = 0;
    gSystemInitCalls = 0;
    gSourceFixture = SourceFixture::Relative;

    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture), std::string(name) + " initialization");
    Expect(gConfigInitCalls == 1, std::string(name) + " pkgInitConfig call count");
    Expect(gSystemInitCalls == 1, std::string(name) + " pkgInitSystem call count");
    Expect(_system == &gTestSystem, std::string(name) + " selected package system");
    Expect(architecture == options.architecture, std::string(name) + " reported architecture");
    ExpectBootstrapConfiguration(configuration, "after initialization",
                                 ExpectedEtcDirectory());
    ExpectRootDirectory(configuration, "after initialization");
    ExpectSourceConfiguration(configuration, "after initialization");
    ExpectArchitectures(configuration, {options.architecture, "iphoneos-foreign-test"},
                        "after initialization");
    Expect(CydiaAPT::Architectures() ==
               std::vector<std::string>({options.architecture, "iphoneos-foreign-test"}),
           std::string(name) + " materialized architecture vector");
    Expect(CydiaAPT::IsArchitectureSupported(options.architecture),
           std::string(name) + " native architecture support");
    Expect(CydiaAPT::IsArchitectureSupported("iphoneos-foreign-test"),
           std::string(name) + " foreign architecture support");
    Expect(CydiaAPT::IsArchitectureSupported("all"),
           std::string(name) + " Architecture: all support");
    Expect(!CydiaAPT::IsArchitectureSupported("iphoneos-unsupported-test"),
           std::string(name) + " unsupported architecture rejection");
    Expect(!CydiaAPT::IsArchitectureSupported("any"),
           std::string(name) + " dependency proxy is not a dpkg architecture");
    Expect(CydiaAPT::SourceArchitectureOption() ==
               "[arch=" + options.architecture + ",iphoneos-foreign-test]",
           std::string(name) + " managed source architecture option");
    Expect(CydiaAPT::SourceListPath() == ExpectedSourceListPath(),
           std::string(name) + " maintainer source list resolution");
    Expect(CydiaAPT::SourcePartsDirectory() == ExpectedSourcePartsDirectory(),
           std::string(name) + " maintainer sourceparts resolution");
    Expect(CydiaAPT::ManagedSourceListPath() ==
               ExpectedSourcePartsDirectory() + "/cydia-managed.list",
           std::string(name) + " managed source leaf resolution");
}

void VerifyCustomEtcRelativeSourceConfiguration() {
    const CydiaRuntime::PackageDatabasePaths paths(
        CydiaRuntime::PackageDatabasePaths::ForLayout(
            CydiaRuntime::PackageDatabaseLayout::Rootful));
    const CydiaAPT::InitializationOptions options(OptionsForLayout(paths));
    Configuration configuration;
    configuration.Set("Dir", "/stale-root-prefix");
    configuration.Set("Dir::Etc", "/stale-etc");
    configuration.Set("Dir::Etc::sourcelist", "/stale/sources.list");
    configuration.Set("Dir::Etc::sourceparts", "/stale/sources.list.d");
    _config = &configuration;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = "custom-etc";
    gExpectedRootDir = "";
    gConfigInitCalls = 0;
    gSystemInitCalls = 0;
    gSourceFixture = SourceFixture::CustomEtcRelative;

    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture),
           "custom Dir::Etc source initialization");
    Expect(gConfigInitCalls == 1, "custom Dir::Etc pkgInitConfig call count");
    Expect(gSystemInitCalls == 1, "custom Dir::Etc pkgInitSystem call count");
    ExpectBootstrapConfiguration(configuration, "custom Dir::Etc after initialization",
                                 ExpectedEtcDirectory());
    ExpectValue(configuration, "Dir::Etc", "/maintainer-apt",
                "custom Dir::Etc after initialization");
    ExpectValue(configuration, "Dir", "/",
                "custom Dir::Etc after initialization");
    ExpectSourceConfiguration(configuration, "custom Dir::Etc after initialization");
    Expect(CydiaAPT::SourceListPath() == "/maintainer-apt/maintainer.sources",
           "relative source list follows maintainer Dir::Etc");
    Expect(CydiaAPT::SourcePartsDirectory() == "/maintainer-apt/parts",
           "relative sourceparts follows maintainer Dir::Etc");
    Expect(CydiaAPT::ManagedSourceListPath() ==
               "/maintainer-apt/parts/cydia-managed.list",
           "managed source follows maintainer Dir::Etc");
}

void VerifyIncompatibleRootedOptionsRejected() {
    CydiaAPT::InitializationOptions options(RootedOptions());
    /* This is a physical path, not a path in RootDir's coordinate system. */
    options.aptConfigDirectory = "/cydia-test-root/etc/apt";
    Configuration configuration;
    _config = &configuration;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = "incompatible-root";
    gExpectedRootDir = "/cydia-test-root";
    gConfigInitCalls = 0;
    gSystemInitCalls = 0;
    gSourceFixture = SourceFixture::RootedRelative;

    std::string architecture;
    Expect(!CydiaAPT::Initialize(options, &architecture),
           "already-rooted initialization paths are rejected");
    Expect(gConfigInitCalls == 1, "incompatible RootDir pkgInitConfig call count");
    Expect(gSystemInitCalls == 0, "incompatible RootDir skips pkgInitSystem");
    Expect(_system == NULL, "incompatible RootDir leaves package system unset");
    Expect(CydiaAPT::SourceListPath().empty(),
           "incompatible RootDir clears source list state");
    Expect(CydiaAPT::SourcePartsDirectory().empty(),
           "incompatible RootDir clears sourceparts state");
    Expect(CydiaAPT::ManagedSourceListPath().empty(),
           "incompatible RootDir clears managed source state");
}

} // namespace

bool pkgInitConfig(Configuration &configuration) {
    ++gConfigInitCalls;
    ExpectBootstrapConfiguration(configuration, "before pkgInitConfig",
                                 gExpectedOptions->aptConfigDirectory);
    ExpectArchitectures(configuration, {}, "before pkgInitConfig");
    /* Mirror apt's CndSet("Dir", "/") default.  A stale parent value must
     * not survive a prior rootful/rootless initialization. */
    configuration.CndSet("Dir", "/");
    ExpectValue(configuration, "Dir", "/", "before pkgInitConfig");
    OverrideBootstrapConfiguration(configuration);
    if (gSourceFixture == SourceFixture::RootedRelative ||
        gSourceFixture == SourceFixture::RootedAbsolute ||
        gSourceFixture == SourceFixture::RootedDevNull)
        configuration.Set("RootDir", "/cydia-test-root");

    if (gSourceFixture == SourceFixture::DevNull ||
        gSourceFixture == SourceFixture::RootedDevNull) {
        /* APT treats /dev/null and descendants as the disabled sentinel when
         * resolving a file option. Keep a suffix here to exercise that exact
         * boundary rather than only the shortest spelling. */
        configuration.Set("Dir::Etc::sourcelist", "/dev/null/ignored");
        configuration.Set("Dir::Etc::sourceparts", "/dev/null/ignored");
        configuration.Set("Cydia::APT::ManagedSourceList", "cydia-managed.list");
    } else if (gSourceFixture == SourceFixture::Defaults) {
        /* Leave source keys absent so pkgInitConfig's defaults are the only
         * values carried into the second stage. */
    } else {
        if (gSourceFixture == SourceFixture::CustomEtcRelative)
            configuration.Set("Dir::Etc", "/maintainer-apt");
        configuration.Set("Dir::Etc::sourcelist", "maintainer.sources");
        configuration.Set("Dir::Etc::sourceparts", "parts");
        if (gSourceFixture == SourceFixture::InvalidManaged)
            configuration.Set("Cydia::APT::ManagedSourceList", "cydia managed.list");
        else if (gSourceFixture == SourceFixture::RootedAbsolute)
            configuration.Set("Cydia::APT::ManagedSourceList",
                              "/etc/apt/parts/cydia-managed.list");
        else
            configuration.Set("Cydia::APT::ManagedSourceList", "cydia-managed.list");
    }
    return true;
}

bool pkgInitSystem(Configuration &configuration, pkgSystem *&system) {
    ++gSystemInitCalls;
    ExpectBootstrapConfiguration(configuration, "before pkgInitSystem",
                                 ExpectedEtcDirectory());
    ExpectArchitectures(configuration, {}, "before pkgInitSystem");
    ExpectValue(configuration, "Dir", "/", "before pkgInitSystem");
    ExpectRootDirectory(configuration, "before pkgInitSystem");
    ExpectSourceConfiguration(configuration, "before pkgInitSystem");
    if (gSourceFixture == SourceFixture::DevNull ||
        gSourceFixture == SourceFixture::RootedDevNull) {
        ExpectValue(configuration, "Dir::Etc::sourcelist", "/dev/null/ignored",
                    "before pkgInitSystem");
        ExpectValue(configuration, "Dir::Etc::sourceparts", "/dev/null/ignored",
                    "before pkgInitSystem");
    } else if (gSourceFixture == SourceFixture::Defaults) {
        ExpectValue(configuration, "Dir::Etc::sourcelist", "sources.list",
                    "before pkgInitSystem");
        ExpectValue(configuration, "Dir::Etc::sourceparts", "sources.list.d",
                    "before pkgInitSystem");
    } else {
        ExpectValue(configuration, "Dir::Etc::sourcelist", "maintainer.sources",
                    "before pkgInitSystem");
        ExpectValue(configuration, "Dir::Etc::sourceparts", "parts",
                    "before pkgInitSystem");
    }
    if (gSourceFixture == SourceFixture::CustomEtcRelative)
        configuration.Set("Dir::Etc", "/pkg-system-redirect");
    system = &gTestSystem;
    return true;
}

namespace APT {
namespace Configuration {

std::vector<std::string> getArchitectures(bool cached) {
    (void) cached;
    Expect(_system == &gTestSystem,
           std::string(gExpectedLayout) + " architecture discovery preceded pkgInitSystem");
    return {gExpectedOptions->architecture, "iphoneos-foreign-test",
            gExpectedOptions->architecture, "", "all", "any"};
}

} // namespace Configuration
} // namespace APT

int main() {
    const char *existingRoot(getenv("DPKG_ROOT"));
    const bool hadRoot(existingRoot != NULL);
    const std::string savedRoot(hadRoot ? existingRoot : "");
    setenv("DPKG_ROOT", "cydia-test-sentinel", 1);

    VerifyCustomEtcRelativeSourceConfiguration();
    VerifyRootedSourceConfiguration();
    VerifyRootedDisabledSourceConfiguration();
    VerifyLayout(CydiaRuntime::PackageDatabaseLayout::Rootful, "rootful");
    VerifyLayout(CydiaRuntime::PackageDatabaseLayout::Rootless, "rootless");
    VerifyDefaultSourceConfigurationClearsStaleValues();
    VerifyIncompatibleRootedOptionsRejected();

    /* An explicit /dev/null source configuration remains disabled through the
     * second APT stage and cannot inherit the prior layout's paths. */
    const CydiaRuntime::PackageDatabasePaths paths(
        CydiaRuntime::PackageDatabasePaths::ForLayout(
            CydiaRuntime::PackageDatabaseLayout::Rootful));
    const CydiaAPT::InitializationOptions options(OptionsForLayout(paths));
    Configuration disabled;
    _config = &disabled;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = "disabled";
    gExpectedRootDir = "";
    gConfigInitCalls = 0;
    gSystemInitCalls = 0;
    gSourceFixture = SourceFixture::DevNull;
    disabled.Set("Dir::Etc::sourcelist", "/old/sources.list");
    disabled.Set("Dir::Etc::sourceparts", "/old/sources.list.d");
    std::string disabledArchitecture;
    Expect(CydiaAPT::Initialize(options, &disabledArchitecture),
           "disabled source initialization");
    ExpectSourceConfiguration(disabled, "disabled after initialization");
    Expect(CydiaAPT::SourceListPath().empty(), "disabled source list is empty");
    Expect(CydiaAPT::SourcePartsDirectory().empty(), "disabled sourceparts is empty");
    Expect(CydiaAPT::ManagedSourceListPath().empty(), "disabled managed source is empty");

    /* Invalid managed values (including a whitespace-bearing leaf) are
     * ignored without changing the effective distro source locations. */
    Configuration invalid;
    _config = &invalid;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = "invalid-managed";
    gExpectedRootDir = "";
    gConfigInitCalls = 0;
    gSystemInitCalls = 0;
    gSourceFixture = SourceFixture::InvalidManaged;
    std::string invalidArchitecture;
    Expect(CydiaAPT::Initialize(options, &invalidArchitecture),
           "invalid managed source initialization");
    Expect(CydiaAPT::SourceListPath() == ExpectedSourceListPath(),
           "invalid managed source list remains effective");
    Expect(CydiaAPT::SourcePartsDirectory() == ExpectedSourcePartsDirectory(),
           "invalid managed sourceparts remains effective");
    Expect(CydiaAPT::ManagedSourceListPath().empty(),
           "invalid managed source is disabled");
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
