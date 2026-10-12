/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderSelection.hpp"
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

namespace {
namespace P = CydiaAPT::Provider;
namespace V = CydiaRuntime::Privileged;
void Require(bool condition, const char *message) {
    if (condition) return;
    std::fprintf(stderr, "[apt-provider-selection] %s\n", message); std::exit(1);
}
std::string Read(const std::string &path) {
    std::ifstream file(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
struct Fixture {
    std::string root, registration;
    Fixture() {
        char cwd[4096]; Require(getcwd(cwd, sizeof(cwd)) != nullptr, "read fixture parent");
        std::string pattern(std::string(cwd) + "/cydia-provider-selection.XXXXXX");
        std::vector<char> bytes(pattern.begin(), pattern.end()); bytes.push_back('\0');
        const char *created(mkdtemp(bytes.data())); Require(created != nullptr, "create private fixture directory");
        root = created; registration = root + "/provider.conf";
    }
    ~Fixture() { unlink(registration.c_str()); rmdir(root.c_str()); }
    void Write(const std::string &bytes, mode_t mode = 0644) {
        std::ofstream file(registration, std::ios::binary | std::ios::trunc); file << bytes; file.close();
        Require(file.good() && chmod(registration.c_str(), mode) == 0, "write fixture registration");
    }
};
P::RegisteredProviderSnapshot Snapshot(const std::string &registration) {
    P::RegisteredProviderSnapshot s;
    s.identity = {registration, "fixture-provider", "configuration-v1", "policy-v1", "methods-v1", "library-v1", "frontend-v1"};
    s.executable = "/fixture/bin/provider"; s.executableSearchPath = "/fixture/bin:/usr/bin:/bin";
    s.packageStateIdentity = "parent-owned-package-state";
    auto &d(s.runtime);
    d.architecture = "iphoneos-arm64"; d.registeredArchitectures = {d.architecture, "iphoneos-arm64e"};
    d.acquisitionArchitectures = {d.architecture, "apt-only-test", "all"};
    d.sourceListPath = "/fixture/etc/apt/sources.list"; d.sourcePartsDirectory = "/fixture/etc/apt/sources.list.d";
    d.managedSourceListPath = d.sourcePartsDirectory + "/cydia.list";
    d.dpkgExecutablePath = "/fixture/bin/dpkg"; d.dpkgQueryExecutablePath = "/fixture/bin/dpkg-query";
    d.dpkgDebExecutablePath = "/fixture/bin/dpkg-deb"; d.gpgExecutablePath = "/fixture/bin/gpg";
    d.aptConfigOverride = "/fixture/etc/apt/apt.conf"; d.privilegedHelperPath = "/fixture/libexec/cydo";
    d.dpkgRootDirectory = "/"; d.dpkgAdminDirectory = "/fixture/state/dpkg"; d.packageInstallPrefix = "/fixture";
    d.dpkgChrootDirectory = "/"; d.dpkgOptions = {"--force-confdef", "--pre-invoke=printf 'configuration policy'"};
    d.extendedStatesPath = "/fixture/state/extended_states"; d.methodsDirectory = "/fixture/libexec/apt/methods";
    d.listsDirectory = "/fixture/state/lists"; d.trustedKeyringPath = "/fixture/etc/apt/trusted.gpg";
    d.trustedKeyringPartsDirectory = "/fixture/etc/apt/trusted.gpg.d";
    d.repositorySecurityMode = CydiaAPT::RepositorySecurityMode::Distribution; d.mutationEnvironmentValid = true;
    return s;
}
P::Environment Expected(const P::RegisteredProviderSnapshot &s) {
    P::Environment environment;
    const auto &d(s.runtime);
    environment.paths = {d.aptConfigOverride, d.dpkgRootDirectory, d.dpkgAdminDirectory,
        d.dpkgExecutablePath, d.dpkgQueryExecutablePath, d.dpkgDebExecutablePath, d.sourceListPath, d.sourcePartsDirectory};
    environment.configurationIdentity = s.identity.configurationIdentity; environment.policyIdentity = s.identity.policyIdentity;
    environment.methodsIdentity = s.identity.methodsIdentity; environment.packageStateIdentity = s.packageStateIdentity;
    environment.nativeArchitecture = d.architecture; environment.registeredArchitectures = d.registeredArchitectures;
    environment.acquisitionArchitectures = d.acquisitionArchitectures; return environment;
}
void CodecCases(const std::string &path) {
    auto snapshot(Snapshot(path)); P::RegisteredProviderSnapshot decoded;
    const std::string bytes(P::SerializeRegisteredProviderSnapshot(snapshot));
    Require(!bytes.empty() && P::ParseRegisteredProviderSnapshot(bytes, &decoded), "snapshot codec preserves a complete verified runtime");
    Require(P::SerializeRegisteredProviderSnapshot(decoded) == bytes && decoded.runtime.dpkgOptions == snapshot.runtime.dpkgOptions &&
        decoded.runtime.acquisitionArchitectures == snapshot.runtime.acquisitionArchitectures && decoded.runtime.binding.session.empty() &&
        decoded.runtime.binding.packageStateIdentity == snapshot.packageStateIdentity,
        "snapshot retains exact options, acquisition policy and parent state without inventing a session");
    auto before(decoded);
    Require(!P::ParseRegisteredProviderSnapshot(bytes.substr(0, bytes.size() - 1), &decoded) &&
        P::SerializeRegisteredProviderSnapshot(decoded) == P::SerializeRegisteredProviderSnapshot(before),
        "truncated snapshot cannot partially overwrite a valid value");
    Require(!P::ParseRegisteredProviderSnapshot(bytes + "0:,", &decoded), "snapshot trailing fields rejected");
    Require(!P::ParseRegisteredProviderSnapshot("999999999999999999999999999999999:", &decoded), "netstring length overflow rejected");
    snapshot.runtime.dpkgAdminDirectory = "/fixture/../other";
    Require(P::SerializeRegisteredProviderSnapshot(snapshot).empty(), "unresolved parent paths cannot cross the authority boundary");
    snapshot = Snapshot(path); snapshot.runtime.registeredArchitectures.push_back("all");
    Require(P::SerializeRegisteredProviderSnapshot(snapshot).empty(), "Architecture all is not a registered foreign architecture");
    snapshot = Snapshot(path); snapshot.runtime.sourceListPath.clear(); snapshot.runtime.sourcePartsDirectory.clear(); snapshot.runtime.managedSourceListPath.clear();
    Require(!P::SerializeRegisteredProviderSnapshot(snapshot).empty(), "explicitly disabled source inputs remain representable");
    P::RegistrationIdentity identity;
    Require(P::ParseRegistrationIdentity(P::SerializeRegistrationIdentity(snapshot.identity), &identity) &&
        P::SameRegistrationIdentity(identity, snapshot.identity), "registration identity codec");
    identity.policyIdentity += "-changed";
    Require(!P::SameRegistrationIdentity(identity, snapshot.identity), "compiled or configured policy changes invalidate authority");
    snapshot.identity.providerIdentifier = "https://repo.invalid/?secret=private";
    Require(!P::ParseRegistrationIdentity(P::SerializeRegistrationIdentity(snapshot.identity), &identity), "identities reject diagnostic URL payloads");
}
void DiscoveryCases() {
    const auto paths(CydiaRuntime::PackageDatabasePaths::ForLayout(CydiaRuntime::PackageDatabaseLayout::Rootless));
    const auto candidates(P::ProviderRegistrationCandidates(paths));
    Require(candidates.size() == 2 && candidates[0] == paths.CydiaStateDirectory() + "/apt-provider.conf" &&
        candidates[1] == "/var/jb/usr/share/cydia/apt-provider.conf", "private override precedes selected bootstrap share registration");
    CydiaAPT::InitializationOptions options;
    unsigned calls = 0;
    auto result(P::DiscoverProvider(paths, options, "", [&](const std::string &path, const P::RegistrationIdentity *,
        P::RegisteredProviderSnapshot *, V::Error *error, unsigned, const std::function<bool()> &) {
        Require(path == candidates[calls++], "candidate order is deterministic"); error->code = "provider_registration_missing"; return false;
    }));
    Require(result.availability == P::Availability::Missing && calls == 2, "absence checks both declared registration locations");
    calls = 0;
    result = P::DiscoverProvider(paths, options, "warning", [&](const std::string &, const P::RegistrationIdentity *,
        P::RegisteredProviderSnapshot *, V::Error *error, unsigned, const std::function<bool()> &) {
        ++calls; error->code = "provider_registration_invalid"; return false;
    });
    Require(result.availability == P::Availability::Broken && calls == 1, "invalid explicit registration cannot fall through to another provider");
    calls = 0;
    result = P::DiscoverProvider(paths, options, "", [&](const std::string &path, const P::RegistrationIdentity *,
        P::RegisteredProviderSnapshot *snapshot, V::Error *, unsigned, const std::function<bool()> &) {
        ++calls; *snapshot = Snapshot(path); snapshot->runtime.dpkgExecutablePath = "relative/dpkg"; return true;
    });
    Require(result.availability == P::Availability::Broken && result.errorCode == "provider_registration_invalid" && calls == 1,
        "malformed authoritative response is rejected before launching any provider");
    calls = 0;
    result = P::DiscoverProvider(paths, options, "", [&](const std::string &, const P::RegistrationIdentity *,
        P::RegisteredProviderSnapshot *snapshot, V::Error *, unsigned, const std::function<bool()> &) {
        ++calls; *snapshot = Snapshot("/different/provider.conf"); return true;
    });
    Require(result.availability == P::Availability::Broken && calls == 1, "response cannot redirect selected registration");
    result = P::DiscoverProvider(paths, options, "", [](const std::string &, const P::RegistrationIdentity *,
        P::RegisteredProviderSnapshot *, V::Error *error, unsigned, const std::function<bool()> &) {
        error->code = "https://repo.invalid/private?token=secret"; return false;
    });
    Require(result.errorCode == "provider_registration_failed", "untrusted diagnostics never become stable error identifiers");
    calls = 0;
    result = P::DiscoverProvider(paths, options, "", [&](const std::string &, const P::RegistrationIdentity *,
        P::RegisteredProviderSnapshot *, V::Error *, unsigned, const std::function<bool()> &) { ++calls; return true; }, 4000, []() { return true; });
    Require(calls == 0 && result.errorCode == "provider_cancelled", "cancelled discovery does not invoke authority or provider");
}
int ProbeFixture(int argc, char **argv) {
    if (argc != 3 || std::strncmp(argv[2], "--cydia-provider-registration=", 30) != 0) return 71;
    std::string bytes; char buffer[4096];
    for (;;) {
        const ssize_t count(read(STDIN_FILENO, buffer, sizeof(buffer)));
        if (count > 0) { bytes.append(buffer, count); if (bytes.size() > 256 * 1024) return 72; }
        else if (count < 0 && errno == EINTR) continue;
        else if (count == 0) break;
        else return 73;
    }
    P::Message query; P::Environment expected;
    if (!P::DecodeFrame(bytes, &query) || query.kind != P::MessageKind::Request || query.operation != P::Operation::Hello ||
        query.sequence != 1 || !P::Decode(query.payload, &expected) || !P::ValidEnvironment(expected)) return 74;
    const std::string mode(Read(argv[2] + 30));
    P::Info info; info.availability = P::Availability::Ready; info.capabilities = P::RequiredCapabilities | P::ExplicitSecurityOverrides;
    info.identifier = "fixture-provider"; info.implementationVersion = "1"; info.libraryIdentity = "library-v1"; info.frontendIdentity = "frontend-v1";
    info.environment = expected;
    if (mode == "mismatch") info.environment.paths.dpkgAdmin = "/changed/database";
    P::Message reply; reply.kind = P::MessageKind::Response; reply.operation = P::Operation::Hello; reply.sequence = 1; reply.succeeded = true;
    if (!P::Encode(info, &reply.payload) || !P::EncodeFrame(reply, &bytes)) return 75;
    std::cout.write(bytes.data(), bytes.size()); return std::cout.good() ? 0 : 76;
}
void ProtectedCases(Fixture &fixture, const std::string &executable) {
    const auto paths(CydiaRuntime::PackageDatabasePaths::ForLayout(CydiaRuntime::PackageDatabaseLayout::Rootful));
    V::Error error; P::RegisteredProviderEnvironment environment;
    fixture.Write(V::SerializeFields({"unsupported-version"}));
    Require(!P::ResolveRegisteredProviderEnvironment(paths, fixture.registration, nullptr, &environment, &error) &&
        error.code == "provider_registration_invalid", "protected registration rejects an unknown schema");
    fixture.Write(V::SerializeFields({"CYDIA-APT-PROVIDER-1", "Identifier", "first", "Identifier", "second"}));
    Require(!P::ResolveRegisteredProviderEnvironment(paths, fixture.registration, nullptr, &environment, &error) &&
        error.code == "provider_registration_invalid", "protected registration rejects duplicate authority fields");
    fixture.Write(V::SerializeFields({"CYDIA-APT-PROVIDER-1", "Identifier", "only"}));
    Require(!P::ResolveRegisteredProviderEnvironment(paths, fixture.registration, nullptr, &environment, &error) &&
        error.code == "provider_registration_invalid", "incomplete registration never inherits embedded defaults");
    fixture.Write("", 0666);
    Require(!P::ResolveRegisteredProviderEnvironment(paths, fixture.registration, nullptr, &environment, &error) && error.code == "unsafe_path",
        "non-root-writable registration cannot become authority");
    Require(unlink(fixture.registration.c_str()) == 0, "remove fixture registration");
    Require(!P::ResolveRegisteredProviderEnvironment(paths, fixture.registration, nullptr, &environment, &error) &&
        error.code == "provider_registration_missing", "protected missing registration has a distinct result");
    auto snapshot(Snapshot(fixture.registration)); const auto expected(Expected(snapshot));
    fixture.Write("normal");
    const auto good(P::Probe(executable, expected, 2000, {}, fixture.registration));
    Require(good.compatible() && good.registrationPath == fixture.registration &&
        good.info.environment.packageStateIdentity == snapshot.packageStateIdentity,
        "probe supplies framed parent expectation with exact argv and opaque package state");
    fixture.Write("mismatch");
    const auto mismatch(P::Probe(executable, expected, 2000, {}, fixture.registration));
    Require(mismatch.availability == P::Availability::Unsupported && mismatch.errorCode == "provider_environment_changed",
        "adapter path claims cannot replace independently constructed expectation");
}
}
int main(int argc, char **argv) {
    if (argc > 1 && std::strcmp(argv[1], "--cydia-provider-info") == 0) return ProbeFixture(argc, argv);
    Require(argc == 1, "unexpected test arguments");
    Fixture fixture; CodecCases(fixture.registration); DiscoveryCases();
    if (geteuid() == 0) {
        char *resolved(realpath(argv[0], nullptr)); Require(resolved != nullptr, "resolve fixture executable");
        const std::string executable(resolved); std::free(resolved);
        V::Error error;
        Require(V::ValidateRootOwnedPath(fixture.root, true, false, &error), "fakeroot fixture needs a protected working-directory ancestry");
        ProtectedCases(fixture, executable);
    }
    std::cout << "[apt-provider-selection] snapshot codecs and discovery admission passed" <<
        (geteuid() == 0 ? "; protected registration and framed probe passed\n" : "; protected fixtures require fakeroot\n");
    return 0;
}
