/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/DpkgStatusParser.hpp"

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace {

typedef std::map<std::string, std::string> Stanza;

void Fail(const std::string &message) {
    std::cerr << "[verify-multiarch-fixture][FAIL] " << message << std::endl;
    std::exit(1);
}

void Expect(bool condition, const std::string &message) {
    if (!condition)
        Fail(message);
}

std::vector<Stanza> ReadStanzas(const char *path) {
    std::ifstream input(path);
    if (!input)
        Fail(std::string("open fixture: ") + path);

    std::vector<Stanza> stanzas;
    Stanza stanza;
    std::string line;
    while (std::getline(input, line)) {
        if (!line.empty() && line[line.size() - 1] == '\r')
            line.resize(line.size() - 1);
        if (line.empty()) {
            if (!stanza.empty()) {
                stanzas.push_back(stanza);
                stanza.clear();
            }
            continue;
        }
        const std::string::size_type colon(line.find(':'));
        if (colon == std::string::npos || colon + 1 >= line.size())
            Fail("invalid package fixture field");
        std::string value(line.substr(colon + 1));
        if (!value.empty() && value[0] == ' ')
            value.erase(0, 1);
        stanza[line.substr(0, colon)] = value;
    }
    if (!stanza.empty())
        stanzas.push_back(stanza);
    return stanzas;
}

CydiaAPT::MultiArchMode ParseMode(const std::string &mode) {
    if (mode == "same") return CydiaAPT::MultiArchMode::Same;
    if (mode == "foreign") return CydiaAPT::MultiArchMode::Foreign;
    if (mode == "allowed") return CydiaAPT::MultiArchMode::Allowed;
    if (mode == "no") return CydiaAPT::MultiArchMode::None;
    Fail("unknown Multi-Arch fixture value");
    return CydiaAPT::MultiArchMode::None;
}

} // namespace

int main() {
    using namespace CydiaAPT;
    const std::string native("iphoneos-arm64");
    const std::vector<Stanza> stanzas(ReadStanzas("tests/fixtures/multiarch/Packages"));
    Expect(stanzas.size() == 6, "unexpected fixture stanza count");

    std::map<std::string, PackageIdentity> identities;
    std::set<std::string> routes;
    for (std::vector<Stanza>::const_iterator stanza(stanzas.begin());
         stanza != stanzas.end(); ++stanza) {
        const std::string name(stanza->at("Package"));
        const std::string architecture(stanza->at("Architecture"));
        const std::string packageArchitecture(architecture == "all" ? native : architecture);
        PackageIdentity identity(BuildPackageIdentity(name, packageArchitecture, architecture,
                                                      native, ParseMode(stanza->at("Multi-Arch"))));
        Expect(identity.valid(), "fixture produced invalid identity");
        identities[name + ":" + architecture] = identity;
        Expect(routes.insert(identity.routingName).second,
               "coinstallable package instances collided in route storage");
    }

    Expect(identities.at("coinstallable-runtime:iphoneos-arm64").dpkgName ==
               "coinstallable-runtime:iphoneos-arm64",
           "native Multi-Arch: same dpkg identity is ambiguous");
    Expect(identities.at("coinstallable-runtime:iphoneos-arm").routingName ==
               "coinstallable-runtime:iphoneos-arm",
           "foreign coinstallable route is ambiguous");
    Expect(identities.at("independent-essential:all").routingName ==
               "independent-essential",
           "Architecture: all route changed");
    Expect(IsNativeOrArchitectureIndependent("all", native),
           "Architecture: all Essential fixture was rejected");
    Expect(stanzas.back().at("Depends") ==
               "coinstallable-runtime:any, foreign-provider:iphoneos-arm",
           "dependency qualifiers were not preserved in fixture input");
    Expect(BuildPackageRouteName("coinstallable-runtime", "any", native) ==
               "coinstallable-runtime:any",
           "versionless :any proxy route lost its qualifier");

    std::ifstream status("tests/fixtures/multiarch/progress-status");
    Expect(static_cast<bool>(status), "open progress fixture");
    std::string line;
    std::vector<std::string> packages;
    while (std::getline(status, line)) {
        CydiaRuntime::Dpkg::PackageManagerProgressRecord record;
        Expect(CydiaRuntime::Dpkg::ParsePackageManagerProgress(line, &record),
               "parse progress fixture record");
        packages.push_back(record.package);
    }
    Expect(packages.size() == 3, "unexpected progress fixture count");
    Expect(packages[0] == "coinstallable-runtime:iphoneos-arm64",
           "native qualified progress identity changed");
    Expect(packages[1] == "coinstallable-runtime:iphoneos-arm",
           "foreign qualified progress identity changed");
    Expect(packages[2] == "allowed-consumer:any",
           ":any error identity changed");

    std::cout << "[verify-multiarch-fixture][ ok ] package, dependency, and progress fixtures"
              << std::endl;
    return 0;
}
