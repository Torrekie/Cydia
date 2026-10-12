/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourcePreflight.hpp"
#include "Cydia/RepositorySecurityPolicy.hpp"
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/init.h>
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <limits.h>
#include <set>
#include <sstream>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

/* Only the frontend's runtime policy getters are supplied by the fixture.
 * Source parsing, metadata/hash validation, acquisition and file methods all
 * come from the production embedded APT and SourcePreflight implementation. */
namespace CydiaAPT {
RepositorySecurityMode GetRepositorySecurityMode() {
    const std::string policy(_config->Find("Cydia::RepositorySecurityMode"));
    return policy == "error" ? RepositorySecurityMode::Error :
        policy == "allow" ? RepositorySecurityMode::Allow : RepositorySecurityMode::Warning;
}
bool IsArchitectureSupported(const std::string &architecture) {
    const auto architectures(_config->FindVector("APT::Architectures"));
    return architecture == "all" || std::find(architectures.begin(), architectures.end(), architecture) != architectures.end();
}
}

namespace {
using namespace CydiaAPT;

void Expect(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
void Directory(const std::string &path) {
    if (mkdir(path.c_str(), 0700) != 0) Expect(errno == EEXIST, "create fixture directory");
}
void Write(const std::string &path, const std::string &bytes) {
    std::ofstream output(path, std::ios::binary); output.write(bytes.data(), bytes.size());
    output.close(); Expect(!output.fail(), "write fixture file");
}
std::string Read(const std::string &path) {
    std::ifstream input(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}
std::set<std::string> Children(const std::string &path) {
    DIR *directory(opendir(path.c_str())); Expect(directory != NULL, "read fixture directory");
    std::set<std::string> entries;
    while (dirent *entry = readdir(directory))
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) entries.insert(entry->d_name);
    closedir(directory); return entries;
}
void RemoveTree(const std::string &path) {
    struct stat info;
    if (lstat(path.c_str(), &info) != 0) return;
    if (!S_ISDIR(info.st_mode)) { unlink(path.c_str()); return; }
    for (const auto &child : Children(path)) RemoveTree(path + '/' + child);
    rmdir(path.c_str());
}
std::string Quoted(const std::string &value) {
    std::string result("'");
    for (char byte : value) result += byte == '\'' ? "'\\''" : std::string(1, byte);
    return result + '\'';
}
std::string Digest(const std::string &bytes) {
    Hashes hashes(Hashes::SHA256SUM);
    Expect(hashes.Add(bytes.data(), bytes.size()), "hash fixture Packages");
    return hashes.GetHashString(Hashes::SHA256SUM).HashValue();
}
std::string Packages(const std::string &architecture) {
    return "Package: preflight-fixture\nVersion: 1\nArchitecture: " + architecture +
        "\nMaintainer: Fixture <fixture@example.invalid>\nFilename: pool/fixture.deb\nSize: 1\n"
        "Description: Local source preflight fixture\n\n";
}
std::string Release(const std::string &packages, const std::string &index,
                    const std::string &architectures, bool suite) {
    const std::time_t now(std::time(NULL)); char date[128];
    std::strftime(date, sizeof(date), "%a, %d %b %Y %H:%M:%S +0000", std::gmtime(&now));
    return std::string("Origin: Preflight fixture\nLabel: Preflight fixture\nSuite: stable\nDate: ") + date +
        "\nArchitectures: " + architectures + "\n" + (suite ? "Components: main\n" : "") +
        "SHA256:\n " + Digest(packages) + " " + std::to_string(packages.size()) + " " + index + "\n";
}

struct Fixture {
    std::string root, configuration;
    Configuration *configurationPointer;
    Fixture(const char *methods) {
        const char *temporary(getenv("TMPDIR"));
        std::string pattern(std::string(temporary && *temporary ? temporary : "/tmp") + "/cydia-preflight-test.XXXXXX");
        std::vector<char> name(pattern.begin(), pattern.end()); name.push_back(0);
        Expect(mkdtemp(name.data()) != NULL, "create private fixture root"); root = name.data();
        for (const char *path : {"methods", "checks", "sources.d", "lists", "repos", "config", "keyrings"}) Directory(root + '/' + path);
        for (const char *method : {"file", "copy", "store"}) {
            char resolved[PATH_MAX];
            Expect(realpath((std::string(methods) + '/' + method).c_str(), resolved) != NULL, "resolve real APT method");
            Expect(symlink(resolved, (root + "/methods/" + method).c_str()) == 0, "create real APT method link");
        }
        Write(root + "/sources.list", "This real source file must not be parsed or rewritten.\n");
        Write(root + "/sources.d/existing.sources", "This existing source must not be read.\n");
        Write(root + "/lists/sentinel", "Existing list contents.\n");
        Write(root + "/status", "Existing package database.\n");
        Write(root + "/extended_states", "Existing automatic installation state.\n");

        unsetenv("APT_CONFIG");
        _config->Clear();
        _config->Set("Dir::Etc", root + "/config");
        _config->Set("Dir::Etc::parts", root + "/config");
        _config->Set("Dir::Etc::main", root + "/missing.conf");
        Expect(pkgInitConfig(*_config), "initialize real embedded APT defaults");
        _config->Set("Dir::Etc::sourcelist", root + "/sources.list");
        _config->Set("Dir::Etc::sourceparts", root + "/sources.d");
        _config->Set("Dir::Etc::trusted", root + "/missing.gpg");
        _config->Set("Dir::Etc::trustedparts", root + "/keyrings");
        _config->Set("Dir::State::lists", root + "/lists");
        _config->Set("Dir::State::status", root + "/status");
        _config->Set("Dir::State::extended_states", root + "/extended_states");
        _config->Set("Dir::Bin::methods", root + "/methods");
        _config->Set("APT::Architecture", "iphoneos-arm64");
        _config->Set("APT::Architectures::", "iphoneos-arm64");
        _config->Set("APT::Architectures::", "iphoneos-arm64e");
        _config->Set("APT::Sandbox::User", "");
        _config->Set("Acquire::Languages", "none");
        _config->Set("Acquire::CompressionTypes::Order::", "uncompressed");
        _config->Set("Acquire::GzipIndexes", false);
        _config->Set("Acquire::IndexTargets::deb::Packages::KeepCompressed", false);
        _config->Set("Acquire::Check-Valid-Until", true);
        _config->Set("Acquire::AllowInsecureRepositories", true);
        _config->Set("Acquire::AllowWeakRepositories", true);
        _config->Set("Cydia::RepositorySecurityMode", "warning");
        _config->Set("Cydia::CachedRepositoryTrustValid", false);
        for (const char *hook : {"APT::Update::Pre-Invoke::", "APT::Update::Post-Invoke::", "APT::Update::Post-Invoke-Success::",
                                "APT::Update::Auth-Failure::"})
            _config->Set(hook, "touch " + Quoted(root + "/hook-ran"));
        _config->Set("Methods::Mirror::ProblemReporting", root + "/mirror-report");
        _config->Set("Preflight::List::", "first"); _config->Set("Preflight::List::", "second");
        _error->Discard(); RememberConfiguration();
    }
    ~Fixture() { RemoveTree(root); }
    void RememberConfiguration() {
        std::ostringstream output; _config->Dump(output); configuration = output.str(); configurationPointer = _config;
    }
    void CheckIsolation() const {
        std::ostringstream output; _config->Dump(output);
        Expect(_config == configurationPointer && output.str() == configuration, "restore exact APT configuration and pointer");
        Expect(Read(root + "/sources.list") == "This real source file must not be parsed or rewritten.\n", "preserve real sources.list");
        Expect(Children(root + "/sources.d") == std::set<std::string>{"existing.sources"}, "do not add real source files");
        Expect(Read(root + "/sources.d/existing.sources") == "This existing source must not be read.\n", "preserve existing Deb822 source");
        Expect(Children(root + "/lists") == std::set<std::string>{"sentinel"}, "do not create or delete shared lists");
        Expect(Read(root + "/lists/sentinel") == "Existing list contents.\n", "preserve shared list contents");
        Expect(Read(root + "/status") == "Existing package database.\n", "preserve dpkg database");
        Expect(Read(root + "/extended_states") == "Existing automatic installation state.\n", "preserve package state");
        Expect(access((root + "/hook-ran").c_str(), F_OK) != 0, "do not execute update hooks");
        Expect(Children(root + "/checks").empty(), "remove every preflight temporary file");
    }
    std::string Flat(const std::string &name, const std::string &architecture, bool metadata = true,
                     const std::string &overridePackages = "") {
        const std::string directory(root + "/repos/" + name); Directory(directory);
        const std::string packages(overridePackages.empty() ? Packages(architecture) : overridePackages);
        Write(directory + "/Packages", packages);
        if (metadata) Write(directory + "/Release", Release(packages, "Packages", architecture, false));
        return "deb file://" + directory + "/ ./\n";
    }
    SourcePreflightRequest Request(const std::string &definition) const {
        SourcePreflightRequest request; request.definition = definition; request.temporaryParent = root + "/checks";
        request.timeoutSeconds = 15; return request;
    }
    SourcePreflightResult Run(const SourcePreflightRequest &request) {
        const auto result(RunSourcePreflight(request, [&]() {
            Expect(_config->FindVector("APT::Update::Auth-Failure").empty(), "disable direct authentication-failure hooks during acquisition");
            Expect(_config->Find("Methods::Mirror::ProblemReporting") != root + "/mirror-report",
                   "disable external mirror-problem reporters during acquisition");
            return false;
        })); CheckIsolation();
        return result;
    }
};

bool HasIssue(const SourcePreflightResult &result, FetchDiagnosticKind kind) {
    for (const auto &item : result.warnings) if (item.kind == kind) return true;
    for (const auto &item : result.failures) if (item.kind == kind) return true;
    return false;
}

void Outcomes(Fixture *fixture) {
    const std::string native(fixture->Flat("native", "iphoneos-arm64"));
    auto result(fixture->Run(fixture->Request(native)));
    Expect(result.status == SourceCheckStatus::Complete && result.allowed && !result.authenticated,
           "unsigned flat repository succeeds with Warning without claiming authentication");
    Expect(result.architecture == SourceArchitectureAvailability::Supported, "native package is available");
    Expect(HasIssue(result, FetchDiagnosticKind::UnsignedRepository), "real APT reports unsigned provenance");
    Expect(result.repositories.size() == 1 && !result.repositories[0].metadata.empty() &&
           !result.repositories[0].clearSigned, "retain fetched Release for key discovery");
    const std::string forced("deb [trusted=yes] " + native.substr(4));
    result = fixture->Run(fixture->Request(forced));
    Expect(result.allowed && !result.authenticated && HasIssue(result, FetchDiagnosticKind::UnsignedRepository),
           "trusted=yes does not claim signature authentication or hide unsigned provenance");
    auto previous(fixture->Request(native)); previous.previouslyAuthenticated = true;
    result = fixture->Run(previous);
    Expect(!result.allowed && HasIssue(result, FetchDiagnosticKind::RepositoryTrustDowngrade),
           "known authentication cannot silently downgrade in fresh private lists");

    for (const char *architecture : {"all", "iphoneos-arm64e"}) {
        result = fixture->Run(fixture->Request(fixture->Flat(architecture, architecture)));
        Expect(result.allowed && result.architecture == SourceArchitectureAvailability::Supported,
               "all and configured foreign packages remain eligible");
    }
    result = fixture->Run(fixture->Request(fixture->Flat("unsupported", "iphoneos-arm")));
    Expect(!result.allowed && result.architecture == SourceArchitectureAvailability::Unsupported,
           "rooted-only architecture is not eligible on the configured host");

    auto combined(fixture->Request("Types: deb\nURIs: file://" + fixture->root + "/repos/native/ file://" +
        fixture->root + "/repos/unsupported/\nSuites: ./\n"));
    combined.format = CydiaSources::Format::Deb822;
    result = fixture->Run(combined);
    Expect(!result.allowed && result.repositories.size() == 2 &&
           result.architecture == SourceArchitectureAvailability::Unsupported,
           "a supported URI cannot mask another URI containing only unsupported packages");
    combined.definition = "Types: deb\nURIs: file://" + fixture->root + "/repos/\nSuites: native/ unsupported/\n";
    result = fixture->Run(combined);
    Expect(!result.allowed && result.repositories.size() == 2 &&
           result.architecture == SourceArchitectureAvailability::Unsupported,
           "a supported suite cannot mask another suite containing only unsupported packages");
    combined.definition = "Types: deb\nURIs: file://" + fixture->root + "/repos/native/ file://" +
        fixture->root + "/repos/all/\nSuites: ./\n";
    result = fixture->Run(combined);
    Expect(result.allowed && result.repositories.size() == 2 &&
           result.architecture == SourceArchitectureAvailability::Supported,
           "multiple URIs remain supported when every repository has eligible packages");

    result = fixture->Run(fixture->Request(fixture->Flat("no-release", "all", false)));
    Expect(result.allowed && HasIssue(result, FetchDiagnosticKind::MissingReleaseFile),
           "Warning supports historical flat sources without Release metadata");

    const std::string suite(fixture->root + "/repos/suite");
    for (const std::string &path : {suite, suite + "/dists", suite + "/dists/platform",
         suite + "/dists/platform/1700", suite + "/dists/platform/1700/main",
         suite + "/dists/platform/1700/main/binary-iphoneos-arm64"}) Directory(path);
    const std::string packages(Packages("all") + Packages("iphoneos-arm64"));
    Write(suite + "/dists/platform/1700/main/binary-iphoneos-arm64/Packages", packages);
    Write(suite + "/dists/platform/1700/Release", Release(packages,
        "main/binary-iphoneos-arm64/Packages", "iphoneos-arm64", true));
    auto request(fixture->Request("Types: deb\nURIs: file://" + suite + "/\nSuites: platform/1700\nComponents: main\n"));
    request.format = CydiaSources::Format::Deb822;
    result = fixture->Run(request);
    Expect(result.allowed && result.repositories.size() == 1 && result.repositories[0].suitePath == "platform/1700",
           "Deb822 nested suite path is preserved rather than replaced with Suite stable");
    Expect(result.repositories[0].components == std::vector<std::string>{"main"}, "collect published components");

    const std::string skipped(fixture->root + "/repos/skipped");
    for (const std::string &path : {skipped, skipped + "/dists", skipped + "/dists/platform", skipped + "/dists/platform/1700"})
        Directory(path);
    std::string otherRelease(Release(packages, "other/binary-iphoneos-arm64/Packages", "iphoneos-arm64", true));
    otherRelease.replace(otherRelease.find("Components: main"), 16, "Components: other");
    Write(skipped + "/dists/platform/1700/Release", otherRelease);
    combined.definition = "Types: deb\nURIs: file://" + suite + "/ file://" + skipped +
        "/\nSuites: platform/1700\nComponents: main\n";
    result = fixture->Run(combined);
    Expect(!result.allowed && result.status == SourceCheckStatus::Unavailable && result.repositories.size() == 2,
           "a valid repository cannot mask a second repository with all requested indexes skipped");

    request.definition.replace(request.definition.find("Components: main"), 16, "Components: absent");
    result = fixture->Run(request);
    Expect(!result.allowed, "Release-only success cannot validate a missing requested component index");

    _config->Set("Cydia::RepositorySecurityMode", "error");
    _config->Set("Acquire::AllowInsecureRepositories", false); fixture->RememberConfiguration();
    result = fixture->Run(fixture->Request(native));
    Expect(!result.allowed && HasIssue(result, FetchDiagnosticKind::UnsignedRepository), "Error refuses unsigned metadata");
    result = fixture->Run(fixture->Request(forced));
    Expect(!result.allowed && !result.authenticated, "trusted=yes cannot bypass Error policy");
    _config->Set("Cydia::RepositorySecurityMode", "allow");
    _config->Set("Acquire::AllowInsecureRepositories", true); fixture->RememberConfiguration();
    const std::string tampered(fixture->Flat("tampered", "iphoneos-arm64"));
    Write(fixture->root + "/repos/tampered/Packages", Packages("iphoneos-arm"));
    result = fixture->Run(fixture->Request(tampered));
    Expect(!result.allowed && !result.failures.empty(), "Allow never accepts index hash mismatches");

    std::string large(Packages("iphoneos-arm64")); large += "Description: " + std::string(12 * 1024 * 1024, 'x') + "\n\n";
    request = fixture->Request(fixture->Flat("large", "iphoneos-arm64", true, large));
    request.maximumBytes = 10 * 1024 * 1024;
    result = fixture->Run(request);
    Expect(!result.allowed && result.status == SourceCheckStatus::SizeLimit, "bound local index acquisition as well as network downloads");
}

void CancellationAndInvalidInput(Fixture *fixture) {
    auto request(fixture->Request("deb file://" + fixture->root + "/repos/never-fetched/ ./\n"));
    _error->Warning("previous operation warning");
    const auto result(RunSourcePreflight(request, [] { return true; }));
    Expect(result.status == SourceCheckStatus::Cancelled && !result.allowed, "cancel before acquisition");
    fixture->CheckIsolation();
    std::string message;
    Expect(!_error->PopMessage(message) && message == "previous operation warning", "preserve pre-existing APT diagnostics");
    Expect(_error->empty(), "preflight does not leak diagnostics to later operations");

    request.definition = "deb file:///invalid/ stable\n";
    Expect(fixture->Run(request).status == SourceCheckStatus::InvalidDefinition, "invalid suite definition fails before acquisition");
    SourceResourceRequest resource; resource.uri = "file:///private/resource"; resource.temporaryParent = fixture->root + "/checks";
    Expect(FetchSourceResource(resource).status == SourceCheckStatus::InvalidDefinition, "raw discovery only permits HTTP(S)");
    fixture->CheckIsolation();
}
}

int main(int argc, char **argv) {
    if (argc != 2) { std::cerr << "usage: source-preflight-tests /absolute/path/to/apt/methods\n"; return 2; }
    try {
        Fixture fixture(argv[1]); Outcomes(&fixture); CancellationAndInvalidInput(&fixture);
        std::cout << "[source-preflight] real APT acquisition and isolation fixtures passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "[source-preflight] FAIL: " << error.what() << '\n'; return 1;
    }
}
