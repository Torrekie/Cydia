/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/ExtendedState.hpp"
#include <cstdlib>
#include <iostream>

namespace {
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[extended-state] FAIL: " << message << '\n'; std::exit(1); }
}
const std::string status(
    "Package: example\nArchitecture: iphoneos-arm64\nStatus: install ok installed\n\n"
    "Package: example\nArchitecture: iphoneos-arm\nStatus: hold ok installed\n\n"
    "Package: independent\nArchitecture: all\nStatus: install ok installed\n\n"
    "Package: unpacked\nArchitecture: iphoneos-arm64\nStatus: install ok unpacked\n\n");
bool Merge(const std::string &original, const std::vector<CydiaRuntime::AutoStateDelta> &deltas,
           std::string *updated) {
    return CydiaRuntime::MergeExtendedState(original, status, "iphoneos-arm64",
        {"iphoneos-arm64", "iphoneos-arm"}, deltas, updated);
}
}
int main() {
    const std::string unrelated("# Another frontend's record\r\nPackage: other-manager\r\nArchitecture: iphoneos-arm\r\nAuto-Installed: 1\r\nX-Note: retained\r\n folded value\r\n\r\n");
    const std::string target("Package: example\nArchitecture: iphoneos-arm64\nAuto-Installed: 1\nX-Owner: keep\n continuation\n\n");
    std::string updated;
    Require(Merge(unrelated + target, {{"example", "iphoneos-arm64", false}}, &updated), "mark selected package manual");
    Require(updated == unrelated + "Package: example\nArchitecture: iphoneos-arm64\nAuto-Installed: 0\nX-Owner: keep\n continuation\n\n", "unrelated bytes and unknown folded fields preserved");
    Require(Merge(unrelated + target, {}, &updated) && updated == unrelated + target, "empty delta is byte-identical");
    Require(Merge(unrelated, {{"independent", "iphoneos-arm64", true}}, &updated) &&
        updated == unrelated + "Package: independent\nArchitecture: iphoneos-arm64\nAuto-Installed: 1\n\n", "Architecture all installation uses native identity");
    Require(Merge(unrelated, {{"removed", "iphoneos-arm64", false}}, &updated) && updated == unrelated, "removed missing record is not invented");
    const std::string legacy("Package: example\nAuto-Installed: 1\nX-Owner: another-manager\n\n");
    Require(Merge(legacy, {{"example", "iphoneos-arm64", false}}, &updated), "split legacy multiarch record");
    Require(updated.find("Architecture: iphoneos-arm\n") != std::string::npos &&
        updated.find("Auto-Installed: 1\nX-Owner: another-manager\nArchitecture: iphoneos-arm\n") != std::string::npos &&
        updated.find("Auto-Installed: 0\nX-Owner: another-manager\nArchitecture: iphoneos-arm64\n") != std::string::npos,
        "foreign held provider keeps original auto flag and unknown fields");
    Require(Merge("Package: example\nArchitecture: any\nAuto-Installed: 1\n\n", {{"example", "iphoneos-arm64", false}}, &updated) &&
        updated.find("Architecture: any") == std::string::npos && updated.find("Architecture: iphoneos-arm\nAuto-Installed: 1") != std::string::npos,
        "explicit any has APT legacy semantics");
    Require(Merge("Package: example\r\nArchitecture: iphoneos-arm64\r\nAuto-Installed: 1\r\n\r\n", {{"example", "iphoneos-arm64", false}}, &updated) &&
        updated == "Package: example\r\nArchitecture: iphoneos-arm64\r\nAuto-Installed: 0\r\n\r\n", "preserve CRLF representation");
    Require(Merge("Package: example\nArchitecture: iphoneos-arm64\nAuto-Installed: 1", {{"example", "iphoneos-arm64", false}}, &updated) &&
        updated.find("Auto-Installed: 0\n\n") != std::string::npos, "unterminated final record remains valid");
    Require(!Merge("", {{"unpacked", "iphoneos-arm64", true}}, &updated), "unconfigured package cannot gain an auto-installed record");
    Require(!Merge("", {{"absent", "iphoneos-arm64", true}}, &updated), "absent dependency is not invented");
    Require(!Merge("", {{"example", "unknown-arch", false}}, &updated), "unknown architecture rejected");
    Require(!Merge("", {{"example", "all", true}}, &updated), "all is not a mutable package identity");
    Require(!Merge("", {{"example\nPackage: injection", "iphoneos-arm64", true}}, &updated), "package injection rejected");
    Require(!Merge("", {{"example", "iphoneos-arm64", true}, {"example", "iphoneos-arm64", false}}, &updated), "contradictory deltas rejected");
    Require(!Merge("Package: example\nPackage: example\n", {}, &updated), "duplicate paragraph field rejected");
    Require(!Merge("Package: example\nArchitecture: iphoneos-arm64\nAuto-Installed: invalid\n", {{"example", "iphoneos-arm64", false}}, &updated), "malformed selected auto flag rejected");
    Require(!Merge(std::string(8 * 1024 * 1024 + 1, 'x'), {}, &updated), "input size bounded");
    Require(!Merge(std::string("Package: example\0hidden", 23), {}, &updated), "binary payload rejected");
    std::cout << "[extended-state] PASS: lossless shared flags, multiarch preservation and invalid input rejection\n";
}
