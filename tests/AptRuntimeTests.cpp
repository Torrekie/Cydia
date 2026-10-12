/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptRuntime.hpp"
#include "Cydia/PackageDatabasePaths.hpp"

#include <apt-pkg/configuration.h>
#include <apt-pkg/aptconfiguration.h>
#include <apt-pkg/pkgsystem.h>

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__APPLE__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <Security/SecureTransport.h>
// Deterministic SecureTransport results exercise the public record API without
// depending on a live server, socket timing or a device network policy.
struct TLSRecordFixture {
    OSStatus status;
    size_t processed;
    size_t pending;
    OSStatus pendingStatus;
};
static TLSRecordFixture tlsRecordFixture = {noErr, 0, 0, noErr};
static OSStatus FixtureSSLRead(SSLContextRef, void *data, size_t length, size_t *processed) {
    *processed = tlsRecordFixture.processed;
    std::memset(data, 'x', length < *processed ? length : *processed);
    return tlsRecordFixture.status;
}
static OSStatus FixtureSSLWrite(SSLContextRef, const void *, size_t, size_t *processed) {
    *processed = tlsRecordFixture.processed;
    return tlsRecordFixture.status;
}
static OSStatus FixtureSSLHandshake(SSLContextRef) { return tlsRecordFixture.status; }
static OSStatus FixtureSSLGetBufferedReadSize(SSLContextRef, size_t *pending) {
    *pending = tlsRecordFixture.pending;
    return tlsRecordFixture.pendingStatus;
}
#define SSLRead FixtureSSLRead
#define SSLWrite FixtureSSLWrite
#define SSLHandshake FixtureSSLHandshake
#define SSLGetBufferedReadSize FixtureSSLGetBufferedReadSize
#include "apt-extra/gnutls/gnutls.h"
#undef SSLRead
#undef SSLWrite
#undef SSLHandshake
#undef SSLGetBufferedReadSize
#endif

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
enum class RuntimeFixture {
    Default,
    CoherentOptions,
    ContradictoryAdmin,
    CoherentRoot,
    ContradictoryRoot,
    UnsupportedChroot,
    NativeQuery,
    NativeQueryConfigured,
    QueryFailure,
    MalformedOptions,
    InvalidStatus,
    InvalidExecutableOverrides,
};
RuntimeFixture gRuntimeFixture(RuntimeFixture::Default);
bool gRuntimeDescriptorFixture(false);
std::vector<std::string> gConfiguredArchitectures({"iphoneos-foreign-test"});
std::string gFakeDpkgExecutable;
enum class VerifierFixture { Defaults, NativeSearchPath, ConfiguredPaths, ConfiguredCommands };
VerifierFixture gVerifierFixture(VerifierFixture::Defaults);
std::string gCompressionToolsDirectory;
std::string gConfiguredPackagePrefix;
bool gExplicitCompressionTools(false);
int gCompressorRefreshes(0), gCompressionTypeRefreshes(0);

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
    const bool beforeConfig(std::strcmp(stage, "before pkgInitConfig") == 0);
    const bool queried(gRuntimeDescriptorFixture && gRuntimeFixture != RuntimeFixture::QueryFailure &&
                       std::getenv("CYDIA_TEST_ARCH_QUERY_FAILURE") == NULL);
    ExpectValue(configuration, "APT::Architecture",
                beforeConfig ? options.architecture : queried ? "native-dpkg-test" : "apt-conf-override", stage);
    ExpectValue(configuration, "Dir::Etc", expectedEtc, stage);
    if (gRuntimeFixture == RuntimeFixture::Default || beforeConfig)
        ExpectValue(configuration, "Dir::State::status",
                    beforeConfig ? options.dpkgStatusPath : "/apt-conf-override/status", stage);
    ExpectValue(configuration, "Dir::Bin::dpkg", options.dpkgPath, stage);
    ExpectValue(configuration, "Dir::dpkg::cputable",
                beforeConfig ? JoinPath(options.dpkgDataDirectory, "cputable") : "/apt-conf-override/cputable", stage);
    ExpectValue(configuration, "Dir::dpkg::tupletable",
                beforeConfig ? JoinPath(options.dpkgDataDirectory, "tupletable") : "/apt-conf-override/tupletable", stage);
    ExpectValue(configuration, "Dir::dpkg::triplettable",
                beforeConfig ? JoinPath(options.dpkgDataDirectory, "triplettable") : "/apt-conf-override/triplettable", stage);
    ExpectValue(configuration, "DPkg::Path",
                beforeConfig || gVerifierFixture == VerifierFixture::NativeSearchPath ? options.dpkgExecutableSearchPath :
                    gCompressionToolsDirectory.empty() ? "/apt-conf-override/bin" : gCompressionToolsDirectory + "/invalid:" + gCompressionToolsDirectory, stage);
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
    if (!gConfiguredPackagePrefix.empty())
        configuration.Set("Cydia::Package-Install-Prefix", gConfiguredPackagePrefix);
    configuration.Set("Dir::Bin::dpkg", gRuntimeDescriptorFixture ?
                      gFakeDpkgExecutable : "/apt-conf-override/dpkg");
    configuration.Set("Dir::Bin::dpkg-query", "/apt-conf-override/dpkg-query");
    configuration.Set("Dir::Bin::dpkg-deb", "/apt-conf-override/dpkg-deb");
    configuration.Set("Dir::dpkg::cputable", "/apt-conf-override/cputable");
    configuration.Set("Dir::dpkg::tupletable", "/apt-conf-override/tupletable");
    configuration.Set("Dir::dpkg::triplettable", "/apt-conf-override/triplettable");
    if (gVerifierFixture != VerifierFixture::NativeSearchPath)
        configuration.Set("DPkg::Path", gCompressionToolsDirectory.empty() ? "/apt-conf-override/bin" :
            gCompressionToolsDirectory + "/invalid:" + gCompressionToolsDirectory);
    if (gExplicitCompressionTools) {
        configuration.Set("Dir::Bin::xz", "/configured-but-missing/xz");
        configuration.Set("Dir::Bin::gzip", "/dev/null");
        configuration.Set("APT::Compressor::gzip::UncompressArg::0", "--configured-decompress");
        configuration.Set("APT::Compressor::xz::Binary", "configured-xz-decoder");
        configuration.Set("Acquire::CompressionTypes::Order::0", "gz");
    }
    for (std::size_t index(0); index != gConfiguredArchitectures.size(); ++index)
        configuration.Set(("APT::Architectures::" + std::to_string(index)).c_str(),
                          gConfiguredArchitectures[index]);
    configuration.Set("Dir::Bin::Methods", "/bootstrap/methods");
    configuration.Set("Dir::State::extended_states", "/bootstrap/extended_states");
    configuration.Set("Dir::Etc::trusted", "bootstrap-trusted.gpg");
    configuration.Set("Dir::Etc::trustedparts", "bootstrap-trusted.gpg.d");
    if (gVerifierFixture == VerifierFixture::ConfiguredPaths || gVerifierFixture == VerifierFixture::ConfiguredCommands) {
        configuration.Set("Dir::Bin::apt-key", "/configured-tools/apt-key");
        configuration.Set("Dir::Bin::gpgv", "/configured-tools/gpgv");
        configuration.Set("Dir::Bin::gpg", "/configured-tools/gpg");
        if (gVerifierFixture == VerifierFixture::ConfiguredCommands) {
            configuration.Set("Apt::Key::gpgvcommand", "/configured-commands/gpgv");
            configuration.Set("Apt::Key::gpgcommand", "/configured-commands/gpg");
        }
    }
    if (gRuntimeFixture == RuntimeFixture::CoherentOptions ||
        gRuntimeFixture == RuntimeFixture::ContradictoryAdmin) {
        configuration.Set("Dir::State::status", "/selected-admin/status");
        configuration.Set("DPkg::Options::0", "--instdir=/selected-install-root");
        configuration.Set("DPkg::Options::1", "--admindir");
        configuration.Set("DPkg::Options::2", gRuntimeFixture == RuntimeFixture::CoherentOptions ?
                          "/selected-admin" : "/another-admin");
        configuration.Set("DPkg::Options::3", "--force-confold");
    } else if (gRuntimeFixture == RuntimeFixture::CoherentRoot ||
               gRuntimeFixture == RuntimeFixture::ContradictoryRoot) {
        configuration.Set("DPkg::Options::0", "--root=/selected-root");
        configuration.Set("Dir::State::status", gRuntimeFixture == RuntimeFixture::CoherentRoot ?
                          "/selected-root/var/lib/dpkg/status" : "/another-admin/status");
    } else if (gRuntimeFixture == RuntimeFixture::MalformedOptions)
        configuration.Set("DPkg::Options::0", "--admindir");
    else if (gRuntimeFixture == RuntimeFixture::InvalidStatus)
        configuration.Set("Dir::State::status", "/selected-admin/snapshot");
    else if (gRuntimeFixture == RuntimeFixture::UnsupportedChroot)
        configuration.Set("DPkg::Chroot-Directory", "/selected-chroot");
    else if (gRuntimeFixture == RuntimeFixture::NativeQuery ||
             gRuntimeFixture == RuntimeFixture::NativeQueryConfigured ||
             gRuntimeFixture == RuntimeFixture::QueryFailure) {
        configuration.Set("Dir::Bin::dpkg", gRuntimeFixture == RuntimeFixture::NativeQueryConfigured ?
                          gFakeDpkgExecutable : gExpectedOptions->dpkgPath);
        if (gRuntimeFixture == RuntimeFixture::NativeQuery)
            configuration.Clear("APT::Architectures");
    }
}

CydiaAPT::InitializationOptions OptionsForLayout(
    const CydiaRuntime::PackageDatabasePaths &paths) {
    CydiaAPT::InitializationOptions options;
    options.architecture = paths.AptArchitecture();
    options.packageInstallPrefix = paths.layout() == CydiaRuntime::PackageDatabaseLayout::Rootless ? "/var/jb" : "/";
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
    Expect(architecture == "apt-conf-override", std::string(name) + " reported bootstrap architecture");
    ExpectBootstrapConfiguration(configuration, "after initialization",
                                 ExpectedEtcDirectory());
    ExpectRootDirectory(configuration, "after initialization");
    ExpectSourceConfiguration(configuration, "after initialization");
    ExpectArchitectures(configuration, {"iphoneos-foreign-test"},
                        "after initialization");
    Expect(CydiaAPT::Architectures() ==
               std::vector<std::string>({"apt-conf-override", "iphoneos-foreign-test"}),
           std::string(name) + " materialized architecture vector");
    Expect(CydiaAPT::RegisteredArchitectures().empty(),
           std::string(name) + " unavailable dpkg cannot establish registration");
    Expect(!CydiaAPT::IsArchitectureSupported("apt-conf-override"),
           std::string(name) + " APT native fallback does not prove dpkg registration");
    Expect(!CydiaAPT::IsArchitectureSupported("iphoneos-foreign-test"),
           std::string(name) + " acquisition policy does not prove foreign registration");
    Expect(!CydiaAPT::MutationEnvironmentValid(),
           std::string(name) + " unavailable architecture discovery blocks mutations");
    Expect(CydiaAPT::IsArchitectureSupported("all"),
           std::string(name) + " Architecture: all support");
    Expect(!CydiaAPT::IsArchitectureSupported("iphoneos-unsupported-test"),
           std::string(name) + " unsupported architecture rejection");
    Expect(!CydiaAPT::IsArchitectureSupported("any"),
           std::string(name) + " dependency proxy is not a dpkg architecture");
    Expect(CydiaAPT::SourceArchitectureOption() ==
               "[arch=apt-conf-override,iphoneos-foreign-test]",
           std::string(name) + " managed source architecture option");
    Expect(CydiaAPT::SourceListPath() == ExpectedSourceListPath(),
           std::string(name) + " maintainer source list resolution");
    Expect(CydiaAPT::SourcePartsDirectory() == ExpectedSourcePartsDirectory(),
           std::string(name) + " maintainer sourceparts resolution");
    Expect(CydiaAPT::ManagedSourceListPath() ==
               ExpectedSourcePartsDirectory() + "/cydia-managed.list",
           std::string(name) + " managed source leaf resolution");
}

void VerifyVerifierConfiguration(CydiaRuntime::PackageDatabaseLayout layout, VerifierFixture fixture) {
    const auto paths(CydiaRuntime::PackageDatabasePaths::ForLayout(layout));
    CydiaAPT::InitializationOptions options(OptionsForLayout(paths));
    options.nativeDpkgPath = paths.DpkgBinaryPath();
    Configuration configuration;
    configuration.Set("Dir::Bin::apt-key", "/stale-layout/apt-key");
    configuration.Set("Apt::Key::gpgvcommand", "/stale-layout/gpgv");
    configuration.Set("Apt::Key::gpgcommand", "/stale-layout/gpg");
    _config = &configuration; _system = NULL;
    gExpectedOptions = &options; gExpectedLayout = "verifier-tools";
    gExpectedRootDir = ""; gSourceFixture = SourceFixture::Relative;
    gRuntimeFixture = RuntimeFixture::Default; gVerifierFixture = fixture;
    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture), "verifier configuration remains readable");
    const auto slash(options.nativeDpkgPath.rfind('/'));
    const std::string bin(fixture == VerifierFixture::Defaults || fixture == VerifierFixture::NativeSearchPath ?
        options.nativeDpkgPath.substr(0, slash + 1) : "/configured-tools/");
    for (const char *tool : {"apt-key", "gpgv", "gpg"})
        ExpectValue(configuration, (std::string("Dir::Bin::") + tool).c_str(), bin + tool, "verifier defaults and overrides");
    const std::string commands(fixture == VerifierFixture::ConfiguredCommands ? "/configured-commands/" : bin);
    ExpectValue(configuration, "Apt::Key::gpgvcommand", commands + "gpgv", "apt-key verifier command");
    ExpectValue(configuration, "Apt::Key::gpgcommand", commands + "gpg", "apt-key key command");
    Expect(CydiaAPT::GpgExecutablePath() == commands + "gpg", "native key discovery follows the effective apt-key command");
    Expect(std::getenv("PATH") != NULL && std::string(std::getenv("PATH")) ==
        (fixture == VerifierFixture::NativeSearchPath ? options.dpkgExecutableSearchPath : "/apt-conf-override/bin"),
        "acquisition child PATH follows selected native or explicitly configured tool policy");
    gVerifierFixture = VerifierFixture::Defaults;
}

void VerifyCompressionToolDiscovery(bool configured, bool rooted) {
    char directoryTemplate[] = "/tmp/cydia-compression-tools-XXXXXX";
    char *directory(mkdtemp(directoryTemplate));
    Expect(directory != NULL, "disposable compressor directory created");
    char *executable(realpath(gFakeDpkgExecutable.c_str(), NULL));
    Expect(executable != NULL, "test executable identified without saved host paths");
    const std::string root(directory);
    Expect(mkdir((root + "/invalid").c_str(), 0700) == 0 &&
           mkdir((root + "/invalid/xz").c_str(), 0700) == 0,
           "executable directory is not a compressor file");
    for (const char *tool : {"gzip", "bzip2", "xz", "lzma", "lz4", "zstd"})
        Expect(symlink(executable, (root + "/" + tool).c_str()) == 0, "compressor discovery fixture created");
    free(executable);
    const auto options(RootedOptions());
    Configuration configuration;
    configuration.Set("APT::Compressor::gzip::UncompressArg::stale", "--stale-layout");
    configuration.Set("APT::Compressor::xz::Binary", "stale-xz-decoder");
    configuration.Set("Acquire::CompressionTypes::Order::stale", "stale-format");
    _config = &configuration; _system = NULL;
    gExpectedOptions = &options; gExpectedLayout = "compression-tools";
    gExpectedRootDir = rooted ? "/cydia-test-root" : "";
    gSourceFixture = rooted ? SourceFixture::RootedRelative : SourceFixture::Relative;
    gCompressionToolsDirectory = root; gExplicitCompressionTools = configured;
    gCompressorRefreshes = 0; gCompressionTypeRefreshes = 0;
    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture), "compressor configuration initialized");
    for (const char *tool : {"gzip", "bzip2", "xz", "lzma", "lz4", "zstd"}) {
        const std::string expected(configured && std::strcmp(tool, "xz") == 0 ? "/configured-but-missing/xz" :
            configured && std::strcmp(tool, "gzip") == 0 ? "/dev/null" : root + "/" + tool);
        ExpectValue(configuration, (std::string("Dir::Bin::") + tool).c_str(), expected, "native compressor discovery and configured disablement");
    }
    Expect(configuration.FindVector("APT::Compressor::gzip::UncompressArg") ==
        (configured ? std::vector<std::string>{"--configured-decompress"} : std::vector<std::string>{}),
        "compressor options follow current configuration without stale defaults");
    Expect(configuration.FindVector("Acquire::CompressionTypes::Order") ==
        (configured ? std::vector<std::string>{"gz"} : std::vector<std::string>{}),
        "compression preference preserves configured order without stale formats");
    Expect(configuration.Find("APT::Compressor::xz::Binary") == (configured ? "configured-xz-decoder" : ""),
           "explicit compressor command survives while stale commands are removed");
    Expect(std::getenv("PATH") != NULL && std::string(std::getenv("PATH")) == root + "/invalid:" + root,
           "compressor execution PATH remains physical even when RootDir relocates APT data");
    Expect(gCompressorRefreshes == 1 && gCompressionTypeRefreshes == 1,
           "compressor caches refresh for the selected environment");
    for (const char *tool : {"gzip", "bzip2", "xz", "lzma", "lz4", "zstd"}) unlink((root + "/" + tool).c_str());
    rmdir((root + "/invalid/xz").c_str()); rmdir((root + "/invalid").c_str()); rmdir(root.c_str());
    gCompressionToolsDirectory.clear(); gExplicitCompressionTools = false;
    gSourceFixture = SourceFixture::Relative; gExpectedRootDir = "";
}

#if defined(__APPLE__)
struct TLSIOFixture {
    ssize_t result;
    int error;
    unsigned interrupted;
    unsigned calls;
};
ssize_t FixtureTLSRead(gnutls_transport_ptr_t pointer, void *, size_t) {
    auto &fixture(*static_cast<TLSIOFixture *>(pointer));
    ++fixture.calls;
    if (fixture.interrupted) { --fixture.interrupted; errno = EINTR; return -1; }
    errno = fixture.error; return fixture.result;
}
ssize_t FixtureTLSWrite(gnutls_transport_ptr_t pointer, const void *, size_t length) {
    return FixtureTLSRead(pointer, NULL, length);
}
void VerifyNativeTLSStreaming() {
    gnutls_session_t session(NULL);
    Expect(gnutls_init(&session, GNUTLS_CLIENT | GNUTLS_NONBLOCK) == 0, "native TLS streaming session allocated");
    TLSIOFixture fixture = {3, 0, 0, 0};
    gnutls_transport_set_ptr(session, &fixture);
    gnutls_transport_set_pull_function(session, FixtureTLSRead);
    gnutls_transport_set_push_function(session, FixtureTLSWrite);
    char data[16] = {};
    size_t count(8);
    Expect(cydia_gnutls_read(session, data, &count) == errSSLWouldBlock && count == 3,
           "short transport reads retain progress and report incomplete TLS I/O");
    Expect(gnutls_record_get_direction(session) == 0, "read backpressure waits for readable socket");
    fixture = {-1, EAGAIN, 0, 0}; count = 8;
    Expect(cydia_gnutls_read(session, data, &count) == errSSLWouldBlock && count == 0,
           "read backpressure reports no consumed bytes");
    fixture = {8, 0, 1, 0}; count = 8;
    Expect(cydia_gnutls_read(session, data, &count) == noErr && count == 8 && fixture.calls == 2,
           "interrupted transport reads retry without fatal TLS errors");
    fixture = {0, 0, 0, 0}; count = 8;
    Expect(cydia_gnutls_read(session, data, &count) == errSSLClosedGraceful && count == 0,
           "transport EOF closes TLS rather than reporting an incomplete successful read");
    fixture = {4, 0, 0, 0}; count = 8;
    Expect(cydia_gnutls_write(session, data, &count) == errSSLWouldBlock && count == 4,
           "short transport writes retain progress and report incomplete TLS I/O");
    Expect(gnutls_record_get_direction(session) == 1, "write backpressure waits for writable socket");
    fixture = {-1, EAGAIN, 0, 0}; count = 8;
    Expect(cydia_gnutls_write(session, data, &count) == errSSLWouldBlock && count == 0,
           "write backpressure reports no consumed bytes");
    fixture = {8, 0, 1, 0}; count = 8;
    Expect(cydia_gnutls_write(session, data, &count) == noErr && count == 8 && fixture.calls == 2,
           "interrupted transport writes retry without duplicate transfer");
    fixture = {-1, EPIPE, 0, 0}; count = 8;
    Expect(cydia_gnutls_write(session, data, &count) == errSSLClosedAbort && count == 0,
           "fatal transport writes return a real SecureTransport closure status");
    tlsRecordFixture = {errSSLWouldBlock, 5, 0, noErr};
    Expect(gnutls_record_recv(session, data, sizeof(data)) == 5 && data[0] == 'x' && data[4] == 'x',
           "partial decrypted bytes are delivered once even when more TLS I/O would block");
    Expect(gnutls_record_send(session, data, sizeof(data)) == 5,
           "partial encrypted write progress prevents resending consumed application bytes");
    tlsRecordFixture.processed = 0;
    Expect(gnutls_record_recv(session, data, sizeof(data)) == GNUTLS_E_AGAIN &&
           gnutls_record_send(session, data, sizeof(data)) == GNUTLS_E_AGAIN,
           "zero-progress TLS operations request a retry");
    tlsRecordFixture = {errSSLClosedGraceful, 3, 0, noErr};
    Expect(gnutls_record_recv(session, data, sizeof(data)) == 3, "final decrypted bytes precede EOF");
    tlsRecordFixture.processed = 0;
    Expect(gnutls_record_recv(session, data, sizeof(data)) == 0, "clean TLS receive closure is EOF");
    Expect(gnutls_record_send(session, data, sizeof(data)) < 0 && gnutls_handshake(session) < 0,
           "closed TLS session cannot claim a successful write or handshake");
    tlsRecordFixture = {errSSLPeerAuthCompleted, 0, 9, noErr};
    Expect(gnutls_handshake(session) != 0, "peer authentication event alone is not a completed handshake");
    Expect(gnutls_record_check_pending(session) == 9, "buffered plaintext remains readable without new socket readiness");
    tlsRecordFixture.pendingStatus = errSSLClosedAbort;
    Expect(gnutls_record_check_pending(session) == 0, "failed pending-byte query cannot invent readable data");
    Expect(std::strstr(gnutls_strerror(errSSLClosedAbort), "-9806") != NULL,
           "TLS diagnostics preserve the native status code");
    gnutls_deinit(session);
}
void VerifyNativeTLSTrust() {
    gnutls_certificate_credentials_t credentials(NULL);
    Expect(gnutls_certificate_allocate_credentials(&credentials) == 0, "native TLS credentials allocated");
    Expect(gnutls_certificate_set_x509_system_trust(credentials) > 0,
           "Apple system trust must not report an empty PEM store");
    Expect(gnutls_certificate_set_x509_trust_file(credentials, "/unused-ca.pem", GNUTLS_X509_FMT_PEM) == GNUTLS_E_UNIMPLEMENTED_FEATURE,
           "unsupported custom trust must fail explicitly");
    Expect(gnutls_certificate_set_x509_key_file(credentials, "/unused-client.pem", "/unused-key.pem", GNUTLS_X509_FMT_PEM) == GNUTLS_E_UNIMPLEMENTED_FEATURE,
           "unsupported client credentials must fail explicitly");
    Expect(gnutls_certificate_set_x509_crl_file(credentials, "/unused-crl.pem", GNUTLS_X509_FMT_PEM) == GNUTLS_E_UNIMPLEMENTED_FEATURE,
           "unsupported custom revocation must fail explicitly");
    gnutls_session_t session(NULL);
    Expect(gnutls_init(&session, GNUTLS_CLIENT) == 0, "native TLS session allocated");
    Boolean manualTrust(true);
    Expect(SSLGetSessionOption(session->context, kSSLSessionOptionBreakOnServerAuth, &manualTrust) == noErr && !manualTrust,
           "native TLS keeps SecureTransport automatic peer verification enabled");
    gnutls_deinit(session); gnutls_certificate_free_credentials(credentials);
}
#pragma clang diagnostic pop
#endif

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

void VerifyRuntimeEnvironment(RuntimeFixture fixture) {
    CydiaAPT::InitializationOptions options(OptionsForLayout(
        CydiaRuntime::PackageDatabasePaths::ForLayout(CydiaRuntime::PackageDatabaseLayout::Rootful)));
    if (fixture == RuntimeFixture::NativeQuery)
        options.nativeDpkgPath = gFakeDpkgExecutable;
    else if (fixture == RuntimeFixture::NativeQueryConfigured || fixture == RuntimeFixture::QueryFailure)
        options.nativeDpkgPath = "/unavailable-dpkg";
    options.checkValidUntil = false;
    options.helperPath = "/selected-helper";
    if (fixture == RuntimeFixture::InvalidExecutableOverrides)
        options.privateRuntimeConfigurationPath = "/dev/null";
    Configuration configuration;
    configuration.Set("DPkg::Options::stale", "--root=/stale-root");
    configuration.Set("APT::Get::AllowUnauthenticated", "maintainer-setting");
    _config = &configuration;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = "runtime-descriptor";
    gExpectedRootDir = "";
    gSourceFixture = SourceFixture::Relative;
    gRuntimeFixture = fixture;
    gRuntimeDescriptorFixture = true;
    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture), "runtime descriptor remains readable");
    Expect(CydiaAPT::MethodsDirectory() == "/bootstrap/methods", "loaded methods must survive initialization");
    Expect(CydiaAPT::ExtendedStatesPath() == "/bootstrap/extended_states", "loaded shared extended state path");
    Expect(CydiaAPT::TrustedKeyringDirectory() == ExpectedEtcDirectory() + "/bootstrap-trusted.gpg",
           "relative legacy keyring follows bootstrap Dir::Etc");
    Expect(CydiaAPT::TrustedKeyringPartsDirectory() == ExpectedEtcDirectory() + "/bootstrap-trusted.gpg.d",
           "relative keyring parts follow bootstrap Dir::Etc");
    ExpectValue(configuration, "Dir::Bin::dpkg", options.dpkgPath, "privileged execution wrapper");
    Expect(CydiaAPT::DpkgQueryExecutablePath() == "/apt-conf-override/dpkg-query",
           "loaded dpkg-query executable survives initialization");
    Expect(CydiaAPT::DpkgDebExecutablePath() == "/apt-conf-override/dpkg-deb",
           "loaded dpkg-deb executable survives initialization");
    Expect(CydiaAPT::PrivilegedHelperPath() == options.helperPath, "explicit trusted helper endpoint");
    const char *aptConfig = std::getenv("APT_CONFIG");
    Expect(CydiaAPT::AptConfigOverride() == (aptConfig == NULL ? std::string() : aptConfig),
           "review descriptor retains declared APT_CONFIG");

    const bool valid(fixture == RuntimeFixture::Default || fixture == RuntimeFixture::CoherentOptions ||
                     fixture == RuntimeFixture::CoherentRoot || fixture == RuntimeFixture::NativeQuery ||
                     fixture == RuntimeFixture::NativeQueryConfigured);
    Expect(CydiaAPT::MutationEnvironmentValid() == valid, "descriptor mutation capability");
    Expect(CydiaAPT::RuntimeError().empty() == valid, "invalid mutation environment needs a diagnostic");
    Expect(CydiaAPT::RuntimeErrorCode().empty() == valid, "invalid mutation environment needs a stable code");
    if (fixture == RuntimeFixture::ContradictoryAdmin || fixture == RuntimeFixture::ContradictoryRoot)
        Expect(CydiaAPT::RuntimeErrorCode() == "contradictory_dpkg_admin", "mismatched database code");
    if (fixture == RuntimeFixture::InvalidExecutableOverrides)
        Expect(CydiaAPT::RuntimeErrorCode() == "invalid_executable_overrides",
               "invalid private authority blocks mutation without blocking reads");
    if (fixture == RuntimeFixture::UnsupportedChroot) {
        Expect(CydiaAPT::DpkgChrootDirectory() == "/selected-chroot", "chroot is distinct from install root");
        Expect(CydiaAPT::DpkgRootDirectory() == "/", "chroot must not become --root");
    }
    if (fixture == RuntimeFixture::CoherentOptions) {
        Expect(CydiaAPT::DpkgAdminDirectory() == "/selected-admin", "selected admin directory");
        Expect(CydiaAPT::DpkgRootDirectory() == "/selected-install-root", "instdir installation root");
        Expect(CydiaAPT::DpkgOptions() == std::vector<std::string>({
            "--instdir=/selected-install-root", "--admindir", "/selected-admin", "--force-confold"}),
            "exact loaded option order and values survive");
    }
    if (fixture == RuntimeFixture::CoherentRoot) {
        Expect(CydiaAPT::DpkgRootDirectory() == "/selected-root", "explicit dpkg root");
        Expect(CydiaAPT::DpkgAdminDirectory() == "/selected-root/var/lib/dpkg", "root-selected default admin directory");
    }
    if (fixture == RuntimeFixture::NativeQuery || fixture == RuntimeFixture::NativeQueryConfigured) {
        Expect(CydiaAPT::DpkgExecutablePath() == gFakeDpkgExecutable, "real executable selected without cydo");
        Expect(architecture == "native-dpkg-test", "native architecture comes from real dpkg query");
        Expect(CydiaAPT::RegisteredArchitectures() ==
                   std::vector<std::string>({"native-dpkg-test", "foreign-dpkg-test"}),
               "dpkg registration survives an independent acquisition policy");
        Expect(CydiaAPT::IsArchitectureSupported("foreign-dpkg-test"),
               "registered foreign architecture remains installable when omitted from acquisition");
        Expect(!CydiaAPT::IsArchitectureSupported("iphoneos-foreign-test"),
               "APT-only foreign architecture is not registered with dpkg");
    }
    Expect(!CydiaAPT::CachedRepositoryTrustValid(), "initialization cannot authenticate cached indexes");
    CydiaAPT::SetCachedRepositoryTrustValid(true);
    for (CydiaAPT::RepositorySecurityMode mode : { CydiaAPT::RepositorySecurityMode::Allow,
                                                  CydiaAPT::RepositorySecurityMode::Warning,
                                                  CydiaAPT::RepositorySecurityMode::Error }) {
        CydiaAPT::SetRepositorySecurityMode(mode);
        Expect(CydiaAPT::CachedRepositoryTrustValid(), "changing security mode must preserve the existing proof flag");
        const char *expected(CydiaAPT::AllowsInsecureRepositories(mode) ? "true" : "false");
        ExpectValue(configuration, "Cydia::RepositorySecurityMode", RepositorySecurityModeName(mode), "security mode");
        ExpectValue(configuration, "Acquire::AllowInsecureRepositories", expected, "security mode");
        ExpectValue(configuration, "Acquire::AllowWeakRepositories", expected, "security mode");
        ExpectValue(configuration, "Acquire::AllowDowngradeToInsecureRepositories", expected, "security mode");
        ExpectValue(configuration, "Acquire::Check-Valid-Until", "false", "separate freshness policy");
        ExpectValue(configuration, "APT::Get::AllowUnauthenticated", "maintainer-setting", "archive source preference");
    }
    CydiaAPT::SetCachedRepositoryTrustValid(false);
    CydiaAPT::SetRepositorySecurityMode(CydiaAPT::RepositorySecurityMode::Error);
    Expect(!CydiaAPT::CachedRepositoryTrustValid(), "changing to Error cannot establish trust proof");
    gRuntimeFixture = RuntimeFixture::Default;
    gRuntimeDescriptorFixture = false;
}

class ScopedEnvironment {
    const char *name_;
    bool existed_;
    std::string value_;
  public:
    explicit ScopedEnvironment(const char *name) : name_(name), existed_(std::getenv(name) != NULL),
        value_(existed_ ? std::getenv(name) : "") { unsetenv(name_); }
    ~ScopedEnvironment() {
        if (existed_) setenv(name_, value_.c_str(), 1);
        else unsetenv(name_);
    }
};

void VerifyArchitectureRefresh(const std::vector<std::string> &acquisition,
                               bool unrelatedError = false, bool initialFailure = false) {
    ScopedEnvironment native("CYDIA_TEST_NATIVE_ARCH");
    ScopedEnvironment foreign("CYDIA_TEST_FOREIGN_ARCHES");
    ScopedEnvironment failure("CYDIA_TEST_ARCH_QUERY_FAILURE");
    CydiaAPT::InitializationOptions options(OptionsForLayout(
        CydiaRuntime::PackageDatabasePaths::ForLayout(CydiaRuntime::PackageDatabaseLayout::Rootful)));
    options.nativeDpkgPath = gFakeDpkgExecutable;
    Configuration configuration;
    _config = &configuration;
    _system = NULL;
    gExpectedOptions = &options;
    gExpectedLayout = "architecture-refresh";
    gExpectedRootDir = "";
    gSourceFixture = SourceFixture::Relative;
    gRuntimeDescriptorFixture = true;
    gRuntimeFixture = unrelatedError ? RuntimeFixture::UnsupportedChroot : acquisition.empty() ?
        RuntimeFixture::NativeQuery : RuntimeFixture::NativeQueryConfigured;
    gConfiguredArchitectures = acquisition;
    if (initialFailure) setenv("CYDIA_TEST_ARCH_QUERY_FAILURE", "foreign", 1);
    std::string architecture;
    Expect(CydiaAPT::Initialize(options, &architecture), "architecture refresh runtime initialized");
    if (initialFailure) {
        Expect(CydiaAPT::RegisteredArchitectures().empty(), "failed initial foreign query publishes no registration");
        Expect(architecture == "apt-conf-override", "failed initial foreign query preserves APT native fallback");
        ExpectArchitectures(configuration, acquisition, "failed initial discovery leaves acquisition policy untouched");
        Expect(!CydiaAPT::MutationEnvironmentValid(), "failed initial discovery disables mutation");
        unsetenv("CYDIA_TEST_ARCH_QUERY_FAILURE");
        Expect(CydiaAPT::RefreshArchitectures(), "failed initial discovery can recover on reload");
    }
    Expect(CydiaAPT::RegisteredArchitectures() ==
               std::vector<std::string>({"native-dpkg-test", "foreign-dpkg-test"}),
           "initial verified registration is independent of acquisition subset or superset");
    Expect(CydiaAPT::IsArchitectureSupported("foreign-dpkg-test"), "registered foreign installation support");
    Expect(!CydiaAPT::IsArchitectureSupported("apt-only-test"), "acquiring an index cannot register an architecture");
    Expect(CydiaAPT::MutationEnvironmentValid() == !unrelatedError, "initial mutation validity");
    const std::string unrelatedCode(CydiaAPT::RuntimeErrorCode());
    const std::string unrelatedMessage(CydiaAPT::RuntimeError());

    setenv("CYDIA_TEST_FOREIGN_ARCHES", "foreign-dpkg-test\nsecond-dpkg-test\nforeign-dpkg-test\nnative-dpkg-test", 1);
    Expect(CydiaAPT::RefreshArchitectures(), "foreign registration refresh succeeds");
    Expect(CydiaAPT::RegisteredArchitectures() ==
               std::vector<std::string>({"native-dpkg-test", "foreign-dpkg-test", "second-dpkg-test"}),
           "registration refresh normalizes repeated native and foreign architectures");
    ExpectArchitectures(configuration, acquisition.empty() ? CydiaAPT::RegisteredArchitectures() : acquisition,
                        "added registration follows generated defaults but preserves explicit acquisition policy");
    Expect(CydiaAPT::IsArchitectureSupported("second-dpkg-test"), "new registration is supported immediately");

    setenv("CYDIA_TEST_FOREIGN_ARCHES", "", 1);
    Expect(CydiaAPT::RefreshArchitectures(), "removing the last foreign architecture succeeds");
    Expect(CydiaAPT::RegisteredArchitectures() == std::vector<std::string>({"native-dpkg-test"}),
           "empty foreign output is a valid native-only registration");
    Expect(!CydiaAPT::IsArchitectureSupported("foreign-dpkg-test"), "removed registration no longer allows installation");
    const auto registered(CydiaAPT::RegisteredArchitectures());
    const auto acquired(CydiaAPT::Architectures());
    const auto configured(configuration.FindVector("APT::Architectures"));
    auto expectUnpublished = [&]() {
        Expect(CydiaAPT::RegisteredArchitectures() == registered, "failed discovery retains verified registration");
        Expect(CydiaAPT::Architecture() == "native-dpkg-test", "failed discovery retains verified native architecture");
        Expect(CydiaAPT::Architectures() == acquired, "failed discovery retains acquisition view");
        ExpectValue(configuration, "APT::Architecture", "native-dpkg-test", "failed architecture discovery");
        ExpectArchitectures(configuration, configured, "failed discovery leaves configured acquisition policy untouched");
        Expect(!CydiaAPT::MutationEnvironmentValid(), "failed discovery disables mutation");
        Expect(CydiaAPT::RuntimeErrorCode() == (unrelatedError ? unrelatedCode : "architecture_query_failed"),
               "query failure preserves earlier unrelated diagnostic");
    };
    setenv("CYDIA_TEST_NATIVE_ARCH", "replacement-native", 1);
    setenv("CYDIA_TEST_FOREIGN_ARCHES", "new-foreign", 1);
    for (const char *probe : {"native", "foreign"}) {
        setenv("CYDIA_TEST_ARCH_QUERY_FAILURE", probe, 1);
        Expect(!CydiaAPT::RefreshArchitectures(), "failed dpkg probe rejects refresh");
        expectUnpublished();
    }
    unsetenv("CYDIA_TEST_ARCH_QUERY_FAILURE");
    for (const char *malformed : {"valid-foreign\nINVALID", "all", "any"}) {
        setenv("CYDIA_TEST_FOREIGN_ARCHES", malformed, 1);
        Expect(!CydiaAPT::RefreshArchitectures(), "malformed foreign query rejects refresh");
        expectUnpublished();
    }
    setenv("CYDIA_TEST_FOREIGN_ARCHES", "new-foreign", 1);
    setenv("CYDIA_TEST_NATIVE_ARCH", "replacement-native excess", 1);
    Expect(!CydiaAPT::RefreshArchitectures(), "multiple native architectures reject refresh");
    expectUnpublished();

    setenv("CYDIA_TEST_NATIVE_ARCH", "replacement-native", 1);
    Expect(CydiaAPT::RefreshArchitectures(), "complete valid discovery recovers after query failures");
    Expect(CydiaAPT::RegisteredArchitectures() == std::vector<std::string>({"replacement-native", "new-foreign"}),
           "successful recovery publishes both probes together");
    Expect(CydiaAPT::Architecture() == "replacement-native", "native architecture refresh reaches APT consumers");
    Expect(CydiaAPT::Architectures().front() == "replacement-native", "acquisition view refreshes native default");
    ExpectArchitectures(configuration, acquisition.empty() ? CydiaAPT::RegisteredArchitectures() : acquisition,
                        "recovery preserves explicit policy or refreshes generated default");
    Expect(CydiaAPT::MutationEnvironmentValid() == !unrelatedError, "query recovery cannot clear unrelated errors");
    Expect(CydiaAPT::RuntimeErrorCode() == unrelatedCode && CydiaAPT::RuntimeError() == unrelatedMessage,
           "recovery clears only the query diagnostic");
    Expect(CydiaAPT::IsArchitectureSupported("all"), "Architecture all remains valid independently of acquisition");
    gRuntimeFixture = RuntimeFixture::Default;
    gRuntimeDescriptorFixture = false;
    gConfiguredArchitectures = {"iphoneos-foreign-test"};
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
    if (gRuntimeFixture != RuntimeFixture::NativeQuery)
        ExpectArchitectures(configuration, gConfiguredArchitectures, "before pkgInitSystem");
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

std::vector<Compressor> const getCompressors(bool cached) {
    Expect(!cached, "compressor list must refresh after environment selection");
    ++gCompressorRefreshes; return {};
}
std::vector<std::string> const getCompressionTypes(bool const &cached) {
    Expect(!cached, "compression types must refresh after environment selection");
    ++gCompressionTypeRefreshes; return {};
}

std::vector<std::string> getArchitectures(bool cached) {
    Expect(!cached, "architecture acquisition cache must be refreshed");
    Expect(_system == &gTestSystem,
           std::string(gExpectedLayout) + " architecture discovery preceded pkgInitSystem");
    std::vector<std::string> result(_config->FindVector("APT::Architectures"));
    result.push_back(_config->Find("APT::Architecture"));
    result.push_back("");
    result.push_back("all");
    result.push_back("any");
    return result;
}

} // namespace Configuration
} // namespace APT

void VerifyPackageLayoutPrefix() {
    struct Case { bool rootless; const char *configured; bool relocated; const char *expected; };
    for (const Case &test : {
        Case{false, "", false, "/"}, Case{true, "", false, "/var/jb"},
        Case{true, "/custom-prefix/", false, "/custom-prefix"},
        Case{true, "/selected-install-root", true, "/"},
        Case{true, "/selected-install-root/bootstrap", true, "/bootstrap"},
        Case{true, "relative-prefix", false, ""}}) {
        CydiaAPT::InitializationOptions options(OptionsForLayout(CydiaRuntime::PackageDatabasePaths::ForLayout(
            test.rootless ? CydiaRuntime::PackageDatabaseLayout::Rootless : CydiaRuntime::PackageDatabaseLayout::Rootful)));
        // Architecture and database/tool paths cannot establish package layout.
        options.architecture = "unrelated-architecture";
        Configuration configuration;
        _config = &configuration; _system = NULL;
        gExpectedOptions = &options; gExpectedLayout = "package-prefix"; gExpectedRootDir = "";
        gSourceFixture = SourceFixture::Relative;
        gConfiguredPackagePrefix = test.configured;
        gRuntimeFixture = test.relocated ? RuntimeFixture::CoherentOptions : RuntimeFixture::Default;
        gRuntimeDescriptorFixture = true;
        Expect(CydiaAPT::Initialize(options, NULL), "layout prefix preserves read-only initialization");
        Expect(CydiaAPT::PackageInstallPrefix() == test.expected,
            "archive layout prefix must follow explicit layout and selected installation root");
        if (*test.expected == '\0')
            Expect(!CydiaAPT::MutationEnvironmentValid() && CydiaAPT::RuntimeErrorCode() == "invalid_package_prefix",
                "relative layout prefix must not silently become rooted");
    }
    gConfiguredPackagePrefix.clear();
    gRuntimeDescriptorFixture = false; gRuntimeFixture = RuntimeFixture::Default;
}

int main(int argc, char **argv) {
    /* The same portable test binary acts as an unprivileged dpkg fixture;
     * executable paths are discovered at runtime, never saved in the repo. */
    if (argc == 4 && std::strncmp(argv[1], "--root=", 7) == 0 &&
        std::strncmp(argv[2], "--admindir=", 11) == 0) {
        const char *failure(std::getenv("CYDIA_TEST_ARCH_QUERY_FAILURE"));
        if (std::strcmp(argv[3], "--print-architecture") == 0) {
            if (failure != NULL && std::strcmp(failure, "native") == 0) return 1;
            const char *native(std::getenv("CYDIA_TEST_NATIVE_ARCH"));
            std::cout << (native == NULL ? "native-dpkg-test" : native) << '\n';
            return 0;
        }
        if (std::strcmp(argv[3], "--print-foreign-architectures") == 0) {
            if (failure != NULL && std::strcmp(failure, "foreign") == 0) return 1;
            const char *foreign(std::getenv("CYDIA_TEST_FOREIGN_ARCHES"));
            if (foreign == NULL || foreign[0] != '\0')
                std::cout << (foreign == NULL ? "foreign-dpkg-test" : foreign) << '\n';
            return 0;
        }
    }
    if (argc != 1) return 64;
    gFakeDpkgExecutable = argv[0];
    const char *originalPath(std::getenv("PATH"));
    const bool hadPath(originalPath != NULL);
    const std::string savedPath(hadPath ? originalPath : "");
    VerifyCompressionToolDiscovery(false, false);
    VerifyCompressionToolDiscovery(true, false);
    VerifyCompressionToolDiscovery(false, true);
#if defined(__APPLE__)
    VerifyNativeTLSTrust();
    VerifyNativeTLSStreaming();
#endif
    for (auto layout : {CydiaRuntime::PackageDatabaseLayout::Rootful, CydiaRuntime::PackageDatabaseLayout::Rootless})
        for (auto fixture : {VerifierFixture::Defaults, VerifierFixture::NativeSearchPath, VerifierFixture::ConfiguredPaths, VerifierFixture::ConfiguredCommands})
            VerifyVerifierConfiguration(layout, fixture);
    for (RuntimeFixture fixture : { RuntimeFixture::Default, RuntimeFixture::CoherentOptions,
                                    RuntimeFixture::ContradictoryAdmin, RuntimeFixture::CoherentRoot,
                                    RuntimeFixture::ContradictoryRoot, RuntimeFixture::UnsupportedChroot,
                                    RuntimeFixture::NativeQuery, RuntimeFixture::NativeQueryConfigured,
                                    RuntimeFixture::QueryFailure, RuntimeFixture::MalformedOptions,
                                    RuntimeFixture::InvalidStatus, RuntimeFixture::InvalidExecutableOverrides })
        VerifyRuntimeEnvironment(fixture);
    VerifyArchitectureRefresh({});
    VerifyArchitectureRefresh({"native-dpkg-test"});
    VerifyArchitectureRefresh({"native-dpkg-test", "foreign-dpkg-test", "apt-only-test"});
    VerifyArchitectureRefresh({"native-dpkg-test"}, true);
    VerifyArchitectureRefresh({}, false, true);
    VerifyPackageLayoutPrefix();
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
    if (hadPath) setenv("PATH", savedPath.c_str(), 1);
    else unsetenv("PATH");

    std::cout << "[verify-apt-runtime][ ok ] effective bootstrap paths, dpkg descriptors and architecture discovery"
              << std::endl;
    return 0;
}
