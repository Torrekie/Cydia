/* Cydia Refurbished package identity tests.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptCompatibility.hpp"

#include <cstdlib>
#include <iostream>

namespace {

void Require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << message << std::endl;
        std::exit(1);
    }
}

} // namespace

int main() {
    using namespace CydiaAPT;

    const std::string native("iphoneos-arm64");

    PackageIdentity normal(BuildPackageIdentity("example", native, native, native,
                                                MultiArchMode::None));
    Require(normal.valid(), "native identity is invalid");
    Require(normal.routingName == "example", "native route changed");
    Require(normal.aptName == "example:iphoneos-arm64", "native APT name is not qualified");
    Require(normal.dpkgName == "example", "ordinary native dpkg name is qualified");

    PackageIdentity same(BuildPackageIdentity("same", native, native, native,
                                              MultiArchMode::Same));
    Require(same.routingName == "same", "native Multi-Arch: same route changed");
    Require(same.dpkgName == "same:iphoneos-arm64",
            "native Multi-Arch: same dpkg name is ambiguous");

    PackageIdentity foreign(BuildPackageIdentity("same", "iphoneos-arm", "iphoneos-arm",
                                                 native, MultiArchMode::Same));
    Require(foreign.routingName == "same:iphoneos-arm", "foreign route is ambiguous");
    Require(foreign.aptName == "same:iphoneos-arm", "foreign APT name is wrong");
    Require(foreign.dpkgName == "same:iphoneos-arm", "foreign dpkg name is wrong");

    PackageIdentity all(BuildPackageIdentity("capability", native, "all", native,
                                             MultiArchMode::Foreign));
    Require(all.architectureIndependent, "Architecture: all was not preserved");
    Require(all.routingName == "capability", "Architecture: all route is qualified");
    Require(all.dpkgName == "capability", "Architecture: all dpkg name is qualified");

    PackageIdentity allowed(BuildPackageIdentity("runtime", "iphoneos-arm", "iphoneos-arm",
                                                 native, MultiArchMode::Allowed));
    Require(allowed.routingName == "runtime:iphoneos-arm", "foreign allowed route is ambiguous");
    Require(allowed.dpkgName == "runtime:iphoneos-arm", "foreign allowed dpkg name is ambiguous");

    Require(BuildPackageRouteName("dependency", "any", native) == "dependency:any",
            "versionless :any dependency proxy lost its qualifier");
    Require(BuildPackageRouteName("dependency", "all", native) == "dependency",
            "Architecture: all route was qualified");

    PackageIdentity anyNative(BuildPackageIdentity("runtime", "any", native, native,
                                                   MultiArchMode::Allowed));
    Require(anyNative.routingName == "runtime:any", ":any route was normalized away");
    Require(anyNative.dpkgName == "runtime", "native :any target has a qualified dpkg name");

    PackageIdentity anyForeign(BuildPackageIdentity("runtime", "any", "iphoneos-arm", native,
                                                    MultiArchMode::Allowed));
    Require(anyForeign.routingName == "runtime:any", "foreign :any route was normalized away");
    Require(anyForeign.dpkgName == "runtime:iphoneos-arm",
            "foreign :any target lost its concrete dpkg architecture");

    PackageIdentity invalid(BuildPackageIdentity("", native, native, native,
                                                 MultiArchMode::None));
    Require(!invalid.valid(), "empty package identity is valid");

    std::cout << "package identity policy: PASS" << std::endl;
    return 0;
}
