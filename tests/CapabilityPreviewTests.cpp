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
    broken = document; broken.insert(broken.find("\nreview\t") + 1, "candidate\tfirmware\t17.0\tcreate\tmissing\t\t\t\t\t\n");
    assert(!CydiaRuntime::ParseCapabilityPreview(broken, &preview));
    std::string legacy = document;
    legacy.insert(legacy.find("\nreview\t") + 1,
        "candidate\tgsc.legacy_capability\t1\tpreserve\tretained-provider\tall\tinstall ok installed\t1\t\tgsc.legacy_capability\n");
    legacy.replace(legacy.find("zebra-firmware"), 14, "legacy_provider");
    assert(CydiaRuntime::ParseCapabilityPreview(legacy, &preview));
    assert(preview.preserved.size() == 2);
    assert(preview.preserved[0].providerPackage == "legacy_provider");
    assert(preview.preserved[1].package == "gsc.legacy_capability");
    for (const char *action : {"create", "update"}) {
        broken = document;
        const std::string row("candidate\tfirmware\t");
        broken.replace(broken.find(row), row.size(), "candidate\tgsc.legacy_capability\t");
        if (std::string(action) == "update") {
            broken.replace(broken.find("\tcreate\tmissing\t"), 16, "\tupdate\towned-update\t");
        }
        assert(!CydiaRuntime::ParseCapabilityPreview(broken, &preview));
    }
    broken = legacy; broken.replace(broken.find("gsc.legacy_capability"), 21, "../legacy");
    assert(!CydiaRuntime::ParseCapabilityPreview(broken, &preview));
    std::cout << "Capability preview framing, provider identities and review validation passed\n";
}
