/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDiscovery.hpp"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <map>
#include <set>

using namespace CydiaAPT;

namespace {
void Expect(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "[source-discovery][FAIL] " << message << std::endl;
    std::exit(1);
}
std::string Release(const std::string &architecture = "iphoneos-arm64", const std::string &components = "main testing") {
    return "Origin: Example Repository\nLabel: Example\nSuite: stable\nCodename: stable\nArchitectures: " + architecture +
        "\nComponents: " + components + "\nSHA256:\n " + std::string(64, 'a') + " 123 main/binary-" + architecture + "/Packages.xz\n";
}
struct Fixture {
    std::map<std::string, std::string> bodies;
    std::vector<std::string> requests;
    SourceResourceResult Fetch(const SourceResourceRequest &request, const std::function<bool()> &cancelled) {
        Expect(request.maximumBytes == 2 * 1024 * 1024 && request.timeoutSeconds > 0 && request.timeoutSeconds <= 20,
               "every request receives response and time limits");
        requests.push_back(request.uri);
        SourceResourceResult response;
        if (cancelled && cancelled()) { response.status = SourceCheckStatus::Cancelled; return response; }
        const auto found(bodies.find(request.uri));
        response.status = found == bodies.end() ? SourceCheckStatus::Unavailable : SourceCheckStatus::Complete;
        if (found != bodies.end()) response.bytes = found->second;
        return response;
    }
    SourceDiscoveryResult Run(const std::string &uri = "https://repo.example/", const std::function<bool()> &cancelled = std::function<bool()>()) {
        return DiscoverSourceOptionsWithFetcher(uri, "/task-private-temp", [this](const SourceResourceRequest &request,
            const std::function<bool()> &stop) { return Fetch(request, stop); }, cancelled);
    }
    bool Requested(const std::string &uri) const { return std::find(requests.begin(), requests.end(), uri) != requests.end(); }
};
void PublishedNestedOptions() {
    Fixture fixture;
    fixture.bodies["https://repo.example/"] = "<html><a href='signing-key.asc'>Repository key</a><a href='Release.gpg'>signature</a></html>";
    fixture.bodies["https://repo.example/dists/"] = "<a href='iphoneos-arm64/'>Build target</a><a href='iphoneos-arm64-rootless/'>Rootless target</a>";
    fixture.bodies["https://repo.example/dists/iphoneos-arm64/"] = "<a href='1800/'>1800</a>";
    fixture.bodies["https://repo.example/dists/iphoneos-arm64-rootless/"] = "<a href='1800/'>1800</a><a href='1800/'>repeat</a>";
    fixture.bodies["https://repo.example/dists/iphoneos-arm64/1800/Release"] = Release("iphoneos-arm");
    fixture.bodies["https://repo.example/dists/iphoneos-arm64-rootless/1800/InRelease"] =
        "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n" + Release() +
        "-----BEGIN PGP SIGNATURE-----\nsignature-data-is-not-trust\n-----END PGP SIGNATURE-----\n";
    const SourceDiscoveryResult result(fixture.Run());
    Expect(result.status == SourceCheckStatus::Complete && !result.discoveryUnavailable && result.suites.size() == 2,
           "published nested suite directories are discovered");
    const DiscoveredSourceSuite *rootless(NULL), *rooted(NULL);
    for (const auto &suite : result.suites)
        if (suite.suitePath == "iphoneos-arm64-rootless/1800") rootless = &suite;
        else if (suite.suitePath == "iphoneos-arm64/1800") rooted = &suite;
    Expect(rootless != NULL && rooted != NULL && rooted->architectures[0] == "iphoneos-arm" &&
           rootless->architectures[0] == "iphoneos-arm64", "Release architecture is independent of directory naming");
    Expect(rootless->clearSigned && rootless->components == std::vector<std::string>({"main", "testing"}),
           "clear-signed metadata supplies advertised choices without establishing authentication");
    Expect(result.keyLinks.size() == 1 && result.keyLinks[0].uri == "https://repo.example/signing-key.asc",
           "publisher key links are candidates while Release.gpg is recognized as a signature");
    Expect(std::set<std::string>(fixture.requests.begin(), fixture.requests.end()).size() == fixture.requests.size(),
           "each resource is visited only once");
    Expect(!fixture.Requested("https://repo.example/dists/iphoneos-arm64-rootless/1800/"),
           "finding Release metadata stops traversal before component/index directories");
}
void LinkBoundaries() {
    Fixture fixture;
    fixture.bodies["https://repo.example/base/"] = "<a href='/outside/key.gpg'>outside</a><a href='https://else.example/key.asc'>cross-origin</a>";
    fixture.bodies["https://repo.example/base/dists/"] =
        "<base href='https://else.example/'><a href='good/'>good</a>"
        "<a href='../'>parent</a><a href='good/../hidden/'>normalized parent</a>"
        "<a href='https://else.example/base/dists/foreign/'>foreign</a>"
        "<a href='//else.example/base/dists/foreign/'>network origin</a>"
        "<a href='http://repo.example/base/dists/downgrade/'>scheme</a>"
        "<a href='https://repo.example:444/base/dists/port/'>port</a>"
        "<a href='/outside/'>outside</a><a href='query/?x=1'>query</a><a href='frag/#x'>fragment</a>"
        "<a href='%2e%2e/'>encoded parent</a><a href='hidden%2fchild/'>encoded slash</a>"
        "<a href='%252e%252e/'>double encoding</a><a href='javascript:alert(1)'>script</a>";
    fixture.bodies["https://repo.example/base/dists/good/Release"] = Release();
    const SourceDiscoveryResult result(fixture.Run("https://repo.example/base/"));
    Expect(result.suites.size() == 1 && result.suites[0].suitePath == "good" && result.keyLinks.empty(),
           "only published in-root same-origin paths enter discovery");
    for (const std::string &request : fixture.requests)
        Expect(request.compare(0, 26, "https://repo.example/base/") == 0 && request.find("hidden") == std::string::npos &&
               request.find("query") == std::string::npos && request.find("foreign") == std::string::npos,
               "rejected links cause no network requests");
}
void ManualFallback() {
    Fixture unavailable;
    const SourceDiscoveryResult absent(unavailable.Run());
    Expect(absent.status == SourceCheckStatus::Complete && absent.discoveryUnavailable && !absent.warnings.empty(),
           "missing directory listings report unavailable options rather than an invalid repository");
    Fixture custom;
    Expect(custom.Run("mirror+https://repo.example/").discoveryUnavailable && custom.requests.empty(),
           "unsupported discovery transports retain manual configuration without probing");
    Fixture query;
    Expect(query.Run("https://repo.example/?secret=value").discoveryUnavailable && query.requests.empty(),
           "query-bearing repository roots do not leak tokens through discovery");
    Fixture flat;
    flat.bodies["https://repo.example/Release"] = Release();
    const SourceDiscoveryResult result(flat.Run());
    Expect(result.flatMetadataAvailable && !result.discoveryUnavailable && result.suites.empty(),
           "a root Release identifies flat metadata without inventing suite names");
}
void MalformedMetadata() {
    Fixture fixture;
    fixture.bodies["https://repo.example/dists/"] = "<a href='bad/'>bad</a><a href='large/'>large</a>";
    fixture.bodies["https://repo.example/dists/bad/Release"] = "<html>Architectures: iphoneos-arm64</html>";
    fixture.bodies["https://repo.example/dists/large/Release"] = std::string(2 * 1024 * 1024 + 1, 'x');
    const SourceDiscoveryResult result(fixture.Run());
    Expect(result.suites.empty() && result.discoveryUnavailable && result.warnings.size() >= 2,
           "HTML or oversized metadata is never presented as repository options");
}
void BoundsAndCancellation() {
    Fixture fixture;
    std::string listing;
    for (unsigned i(0); i < 100; ++i) listing += "<a href='suite" + std::to_string(i) + "/'>suite</a>";
    fixture.bodies["https://repo.example/dists/"] = listing;
    const SourceDiscoveryResult limited(fixture.Run());
    Expect(limited.requestsPerformed == 64 && fixture.requests.size() == 64 && limited.status == SourceCheckStatus::SizeLimit,
           "published large listings cannot exceed the global request budget");
    Fixture depth;
    depth.bodies["https://repo.example/dists/"] = "<a href='one/two/three/four/'>four</a><a href='one/two/three/four/five/'>five</a>";
    depth.bodies["https://repo.example/dists/one/two/three/four/Release"] = Release();
    const SourceDiscoveryResult bounded(depth.Run());
    Expect(bounded.suites.size() == 1 && bounded.suites[0].suitePath == "one/two/three/four" &&
           !depth.Requested("https://repo.example/dists/one/two/three/four/five/InRelease"),
           "suite directory depth is bounded even when links skip intermediate directories");
    Fixture cancelled;
    const SourceDiscoveryResult stopped(cancelled.Run("https://repo.example/", []() { return true; }));
    Expect(stopped.status == SourceCheckStatus::Cancelled && cancelled.requests.empty(), "cancellation before discovery performs no requests");
}
} // namespace

int main() {
    PublishedNestedOptions(); LinkBoundaries(); ManualFallback(); MalformedMetadata(); BoundsAndCancellation();
    std::cout << "[source-discovery] PASS\n";
    return 0;
}
