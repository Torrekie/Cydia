/* Pure readiness fixtures; synthetic controls/checkpoints/native comparator.
 * No protected producer, child execution or mutation permission is exercised.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderPrimaryReadiness.hpp"
#include <cstdlib>
#include <iostream>
namespace {
namespace P = CydiaAPT::Provider; namespace B = P::BinaryRelationships;
void Require(bool ok, const char *why) { if (!ok) { std::cerr << "[primary-readiness] " << why << '\n'; std::exit(1); } }
std::string Row(const std::string &name, const std::string &phase = "installed", const std::string &version = "1",
    const std::string &arch = "amd64", const std::string &multi = "no") {
    return name + '\t' + version + '\t' + arch + "\tinstall ok " + phase + '\t' + multi + "\t\t\n";
}
P::TriggerEffectCheckpoint Point(const std::string &rows,
    const std::map<std::string, std::map<std::string, std::string>> &fields = {}) {
    P::TriggerEffectCheckpoint p; std::string error;
    Require(P::ParseDpkgState(rows, "amd64\n", "i386\n", "state:fixture", &p.packages, &error), "structured pure state");
    p.registry.synchronized = true; p.registry.evidenceIdentity.assign(64, 'a'); p.metadata.evidenceIdentity.assign(64, 'b');
    P::TriggerRegistryInput input; input.directoryPresent = true; input.files = {{"Lock", ""}, {"Unincorp", ""}};
    Require(P::ParseTriggerRegistry(input, &p.registry.state, &error), "pure registry");
    for (const auto &entry : p.packages.packages) {
        P::TriggerPackageMetadata m; m.package = entry.second.package; m.diskStatus = entry.second.status;
        if (entry.second.status >= P::DpkgPackageStatus::TriggersAwaited) m.configVersion = entry.second.package.version;
        auto controls = fields.count(entry.first) ? fields.at(entry.first) : std::map<std::string, std::string>();
        controls["multi-arch"] = entry.second.multiArch;
        Require(CydiaPackages::CanonicalPackageEffectControlFields(controls, &m.controls, &error), "canonical pure fields");
        Require(CydiaPackages::Dpkg1237WrittenPackageEffectControlFieldOrder(m.controls, &m.dependencyOrder), "explicit native dump order fixture");
        m.dependencyOrderVerified = true; m.rawControlRecord = "Package: " + m.package.package + "\nVersion: " + m.package.version + "\n";
        m.evidenceIdentity.assign(64, 'c'); m.declarationIdentity.assign(64, 'd'); p.metadata.packages[entry.first] = m;
    }
    p.metadata.packageStateIdentity = p.packages.packageStateIdentity; p.identity = P::TriggerEffectCheckpointIdentity(p);
    Require(!p.identity.empty(), "sealed pure checkpoint"); return p;
}
B::VersionComparison Compare(const std::string &a, const std::string &b) {
    B::VersionComparison result; result.status = B::ComparisonStatus::Compared;
    result.ordering = a == b ? 0 : a < b ? -1 : 1; return result; // fixture-only numeric strings 1/2
}
P::PrimaryReadinessResult Configure(const P::TriggerEffectCheckpoint &point, const B::VersionComparator &compare = Compare) {
    return P::EvaluatePrimaryRelationshipReadiness(point, P::ExecutionAction::Configure, {{"app", "1", "amd64"}}, compare);
}
void ImmediateConfigure() {
    const auto fields = std::map<std::string, std::map<std::string, std::string>>{{"app:amd64", {{"depends", "lib:any (>= 1)"}}}};
    auto point = Point(Row("app", "unpacked") + Row("lib", "installed", "1", "i386", "allowed"), fields);
    auto result = Configure(point);
    Require(result.readiness == P::PrimaryReadiness::Ready && result.checkpointIdentity == point.identity &&
        !result.relationships.empty() && result.relationships.front().matches.allGroupsMatched, "supported foreign native candidate is retained");
    point = Point(Row("app", "half-configured") + Row("lib", "half-configured", "1", "i386", "allowed"), fields);
    Require(Configure(point).readiness == P::PrimaryReadiness::Blocked, "unconfigured dependency is never normalized");
    point = Point(Row("app", "unpacked") + Row("lib", "installed", "1", "i386", "allowed"), fields);
    const B::VersionComparator unavailable = [](const std::string &, const std::string &) { return B::VersionComparison(); };
    Require(Configure(point, unavailable).readiness == P::PrimaryReadiness::ComparisonFailed, "missing selected-native comparison refuses before child");
    point = Point(Row("app", "unpacked") + Row("lib"), {{"app:amd64", {{"depends", "lib:native"}}}});
    Require(Configure(point).readiness == P::PrimaryReadiness::Unsupported, "APT-only qualifier is not guessed as dpkg syntax");
}
void BreaksAndSiblings() {
    auto point = Point(Row("app", "half-configured") + Row("breaker", "unpacked"), {{"breaker:amd64", {{"breaks", "app (<< 2)"}}}});
    Require(Configure(point).readiness == P::PrimaryReadiness::Blocked, "Unpacked breaker blocks native Configure");
    point = Point(Row("app", "unpacked", "1", "amd64", "same") + Row("app", "installed", "2", "i386", "same"));
    Require(Configure(point).readiness == P::PrimaryReadiness::Blocked, "coinstalled sibling version mismatch blocks configuration");
    point = Point(Row("app", "unpacked", "1", "amd64", "same") + Row("app", "unpacked", "1", "i386", "same"));
    Require(Configure(point).readiness == P::PrimaryReadiness::Ready, "native same-version coinstalled configuration boundary is supported");
}
void RemovalAndCompleteStartup() {
    auto point = Point(Row("lib") + Row("app"), {{"app:amd64", {{"depends", "lib"}}}});
    Require(P::EvaluatePrimaryRelationshipReadiness(point, P::ExecutionAction::Remove, {{"lib", "1", "amd64"}}, Compare).readiness ==
        P::PrimaryReadiness::Blocked, "removing sole required real candidate is refused before native dependency work");
    point = Point(Row("unused") + Row("app"), {{"app:amd64", {{"depends", "absent"}}}});
    Require(P::EvaluatePrimaryRelationshipReadiness(point, P::ExecutionAction::Purge, {{"unused", "1", "amd64"}}, Compare).readiness ==
        P::PrimaryReadiness::Blocked, "conservative removal refuses existing unrelated dependency breakage");
    point = Point(Row("unused"));
    Require(P::EvaluatePrimaryRelationshipReadiness(point, P::ExecutionAction::Purge, {{"unused", "1", "amd64"}}, Compare).readiness ==
        P::PrimaryReadiness::Ready, "independently satisfied simple removal is supported");
    point.registry.state.deferredPresent = false; point.identity = P::TriggerEffectCheckpointIdentity(point);
    Require(P::EvaluatePrimaryRelationshipReadiness(point, P::ExecutionAction::Triggers, {}, Compare).readiness ==
        P::PrimaryReadiness::Unsupported, "missing native Unincorp startup cannot borrow a query-only assumption");
}
}
int main() { ImmediateConfigure(); BreaksAndSiblings(); RemovalAndCompleteStartup(); std::cout << "primary-readiness fixtures passed\n"; }
