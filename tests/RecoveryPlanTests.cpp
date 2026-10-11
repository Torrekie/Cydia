/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RecoveryPlan.hpp"
#include <cstdlib>
#include <iostream>
using namespace CydiaRuntime::Recovery;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[recovery-plan][FAIL] " << message << '\n'; std::exit(1); }
}
std::string Package(const std::string &name, const std::string &state, const std::string &fields = "", const std::string &architecture = "arm64", const std::string &version = "1.0-1") {
    return "Package: " + name + "\nArchitecture: " + architecture + "\nVersion: " + version +
        "\nStatus: install ok " + state + '\n' + fields + '\n';
}
int main() {
    const auto broken(Package("damaged", "half-configured"));
    Require(AnalyzeStatus(broken, "damaged", "arm64").canEmergencyRemove, "actual isolated half-configured state can be recovered");
    Require(!AnalyzeStatus(Package("healthy", "installed"), "healthy", "arm64").canEmergencyRemove, "dependency-cache problems alone do not authorize script clearing");
    Require(!AnalyzeStatus(Package("damaged", "half-installed", "Essential: yes\n"), "damaged", "arm64").canEmergencyRemove, "actual Essential package is protected");
    Require(!AnalyzeStatus(Package("damaged", "half-installed", "Protected: yes\n"), "damaged", "arm64").canEmergencyRemove, "actual Protected package is protected");
    Require(!AnalyzeStatus(Package("cydia", "half-configured"), "cydia", "arm64").canEmergencyRemove, "active frontend cannot clear itself");
    const auto dependent(Package("consumer", "installed", "Pre-Depends: damaged (>= 1.0)\n", "all"));
    auto plan(AnalyzeStatus(broken + dependent, "damaged", "arm64"));
    Require(!plan.canEmergencyRemove && plan.affected == std::vector<std::string>{"consumer"}, "architecture-all installed reverse Pre-Depends blocks emergency removal");
    const auto alternatives(Package("consumer", "installed", "Depends: damaged | substitute (>= 2:1.0~rc1-2)\n"));
    Require(!AnalyzeStatus(broken + alternatives + Package("substitute", "installed", "", "arm64", "1:9.0-1"), "damaged", "arm64").canEmergencyRemove,
        "alternative provider must satisfy Debian epoch ordering");
    Require(AnalyzeStatus(broken + alternatives + Package("substitute", "installed", "", "arm64", "2:1.0-1"), "damaged", "arm64").canEmergencyRemove,
        "fully configured versioned alternative allows isolated recovery");
    Require(!AnalyzeStatus(broken + alternatives + Package("substitute", "unpacked", "", "arm64", "2:1.0-1"), "damaged", "arm64").canEmergencyRemove,
        "unconfigured alternative is insufficient for safe emergency removal");
    const auto virtualBroken(Package("damaged", "half-installed", "Provides: runtime-api (= 2.0)\n"));
    const auto virtualConsumer(Package("consumer", "installed", "Depends: runtime-api (>= 2.0)\n"));
    Require(!AnalyzeStatus(virtualBroken + virtualConsumer, "damaged", "arm64").canEmergencyRemove, "versioned virtual reverse dependency blocks clearing");
    Require(AnalyzeStatus(virtualBroken + virtualConsumer + Package("substitute", "installed", "Provides: runtime-api (= 2.1)\n"), "damaged", "arm64").canEmergencyRemove,
        "other versioned virtual provider is considered");
    Require(!AnalyzeStatus(virtualBroken + virtualConsumer + Package("substitute", "installed", "Provides: runtime-api\n"), "damaged", "arm64").canEmergencyRemove,
        "unversioned virtual provider cannot satisfy versioned dependencies");
    const auto multi(Package("damaged", "half-installed", "Multi-Arch: same\n"));
    Require(AnalyzeStatus(multi, "damaged:arm64", "arm64").canEmergencyRemove &&
        AnalyzeStatus(multi, "damaged", "arm64").reason == "unavailable", "multiarch script identity must be explicit");
    Require(!AnalyzeStatus(multi + Package("consumer", "installed", "Depends: damaged:arm64\n", "armhf"), "damaged:arm64", "arm64").canEmergencyRemove,
        "foreign consumer explicit architecture dependency is protected");
    Require(AnalyzeStatus(multi + Package("consumer", "installed", "Depends: damaged\n", "armhf"), "damaged:arm64", "arm64").canEmergencyRemove,
        "unrelated foreign-architecture dependency does not refer to selected same-arch package");
    Require(!AnalyzeStatus(broken + Package("consumer", "installed", "Depends: damaged [arm64]\n"), "damaged", "arm64").canEmergencyRemove,
        "unsupported installed dependency metadata fails closed");
    Require(!AnalyzeStatus(broken + broken, "damaged", "arm64").canEmergencyRemove, "duplicate package state fails closed");
    Require(!ValidPackageIdentity("../damaged") && !ValidPackageIdentity("damaged;rm") && ValidPackageIdentity("vendor.package+api:arm64"), "package identity cannot select an arbitrary script path");
    Review review; review.analysis = AnalyzeStatus(broken, "damaged", "arm64"); review.scripts = {"postinst", "prerm"}; review.token = std::string(64, 'a');
    Review decoded;
    Require(ParseReview(SerializeReview(review), &decoded) && decoded.analysis.canEmergencyRemove && decoded.scripts == review.scripts,
        "bounded exact preview protocol round trip");
    Require(!ParseReview(SerializeReview(review) + "extra", &decoded), "trailing preview bytes are rejected");
    std::cout << "[recovery-plan] PASS\n";
}
