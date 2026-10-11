/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/CapabilityPreview.hpp"
#include <cassert>
#include <iostream>
int main() {
    std::string document = "cydia-firmware-preview\t1\nenvironment\tiphoneos-arm64\t/var/jb\t/var/jb/var/lib/dpkg\t/\n"
        "tool\tdpkg\t/var/jb/usr/bin/dpkg\ntool\tdpkg-query\t/var/jb/usr/bin/dpkg-query\ntool\tdpkg-deb\t/var/jb/usr/bin/dpkg-deb\n"
        "collector\tmobilegestalt\tcomplete\ncollector\tgssc\tunavailable\n"
        "candidate\tfirmware\t17.0\tcreate\tmissing\t\t\t\t\t\n"
        "candidate\tgsc.ipad\t1\tpreserve\tvirtual-provider\tall\thold ok unpacked\t1\texternal%25provider\tzebra-firmware\n"
        "review\t" + std::string(64, 'a') + "\n";
    CydiaRuntime::CapabilityPreview preview;
    assert(CydiaRuntime::ParseCapabilityPreview(document, &preview));
    assert(preview.changes.size() == 1 && preview.preserved.size() == 1);
    assert(preview.preserved[0].providerPackage == "zebra-firmware");
    assert(preview.preserved[0].providerOwner == "external%provider");
    assert(!CydiaRuntime::ParseCapabilityPreview(document + "extra\n", &preview));
    assert(!CydiaRuntime::ParseCapabilityPreview(document.substr(0, document.size() - 1), &preview));
    std::string broken = document; broken.replace(broken.find("%25"), 3, "%20");
    assert(!CydiaRuntime::ParseCapabilityPreview(broken, &preview));
    broken = document; broken.replace(broken.find("\tcreate\t"), 8, "\terase\t");
    assert(!CydiaRuntime::ParseCapabilityPreview(broken, &preview));
    broken = document; broken.insert(broken.find("review\t"), "candidate\tfirmware\t17.0\tcreate\tmissing\t\t\t\t\t\n");
    assert(!CydiaRuntime::ParseCapabilityPreview(broken, &preview));
    std::cout << "Capability preview framing, provider identities and review validation passed\n";
}
