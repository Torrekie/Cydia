/* Standalone approval framing fixtures; no native capture, policy or child.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderDeconfigurationApproval.hpp"
#include <cstdlib>
#include <functional>
#include <iostream>
#include <limits>

namespace {
namespace P = CydiaAPT::Provider;
namespace B = P::BinaryRelationships;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[deconfiguration-approval] " << message << '\n'; std::exit(1); }
}
P::ReviewedAction Action(std::uint64_t identifier, P::ExecutionAction kind, P::ExecutionPackage package, const std::string &archive = "") {
    P::ReviewedAction result; result.identifier = identifier; result.action = kind; result.package = package; result.archive = archive; return result;
}
P::ArchiveManifest Archive(const std::string &identifier, P::ExecutionPackage package) {
    P::ArchiveManifest result; result.identifier = identifier; result.package = package; result.path = "/archives/" + identifier + ".deb";
    result.sourceURI = "https://example.invalid/"; result.sourceIndexIdentity = "SHA256:" + std::string(64, 'e');
    result.sourceDefinitionPath = "/etc/apt/sources.list.d/example.sources"; result.sourceIndexPath = "/lists/Packages";
    result.sourceIndexURI = "https://example.invalid/Packages"; result.filename = identifier + ".deb";
    result.sourceDefinitionOrdinal = 1; result.recordOffset = 128; result.recordSize = 256;
    result.hashes["SHA256"] = std::string(64, 'f'); result.size = 1024; result.layout.prefix = "/"; return result;
}
P::DeconfigurationAllowanceSet Fixture() {
    P::DeconfigurationAllowanceSet result; result.identity.assign(64, 'a'); result.initialCheckpoint.assign(64, 'b');
    result.nativeAuthorityIdentity.assign(64, 'c'); auto &review = result.primaryReview;
    review.binding.providerIdentifier = "fixture"; review.binding.session.assign(64, '1');
    review.binding.configurationIdentity = "configuration:fixture"; review.binding.policyIdentity = "policy:fixture";
    review.binding.packageStateIdentity = "state:fixture"; review.binding.review = "review:fixture";
    review.binding.cacheEpoch = 2; review.binding.selectionRevision = 3;
    review.transaction.registeredArchitectures = {"amd64", "i386"}; review.transaction.downloading = 1024; review.transaction.resuming = 16;
    review.transaction.substrate = true; review.transaction.installs = {"alpha"}; review.transaction.upgrades = {"victim"};
    for (const char *name : {"alpha", "victim"}) {
        CydiaAPT::TransactionPackageData package; package.identity.baseName = name; package.identity.packageArchitecture = "amd64";
        package.identity.versionArchitecture = "amd64"; package.identity.routingName = name; package.version = "2"; package.displayName = name;
        review.transaction.packages[name] = package;
    }
    review.execution.archives = {Archive("alpha-index", {"alpha", "2", "amd64"}), Archive("victim-index", {"victim", "2", "amd64"})};
    review.execution.actions = {Action(10, P::ExecutionAction::Unpack, {"alpha", "2", "amd64"}, "alpha-index"),
        Action(20, P::ExecutionAction::Unpack, {"victim", "2", "amd64"}, "victim-index"),
        Action(30, P::ExecutionAction::Configure, {"alpha", "2", "amd64"}), Action(40, P::ExecutionAction::Configure, {"victim", "2", "amd64"})};
    P::DeconfigurationAllowance allowance; allowance.installed = {"victim", "1", "amd64"}; allowance.selection = P::DpkgSelection::Hold;
    allowance.initialStatus = P::DpkgPackageStatus::Installed; allowance.diskStatus = P::DpkgPackageStatus::TriggersAwaited;
    allowance.configVersion = "0.9"; allowance.installedControlIdentity.assign(64, 'd'); allowance.installedScriptsIdentity.assign(64, 'e');
    P::DeconfigurationCause cause; cause.unpackAction = 10; cause.archive = "alpha-index";
    cause.canonicalRelation = "victim (<< 2)"; cause.comparedVersion = "1"; allowance.causes.push_back(cause);
    allowance.endpoint.action = 40; allowance.endpoint.precedingUnpack = 20; allowance.endpoint.kind = P::ExecutionAction::Configure;
    allowance.endpoint.package = {"victim", "2", "amd64"}; result.allowances["victim:amd64@1"] = allowance; return result;
}
std::string Encode(const P::DeconfigurationAllowanceSet &value) {
    std::string bytes, error;
    Require(P::EncodeDeconfigurationApproval(value, &bytes, &error) && error.empty(), "encode a structurally valid approval"); return bytes;
}
void Refused(const P::DeconfigurationAllowanceSet &value) {
    std::string bytes = "sentinel", error;
    Require(!P::EncodeDeconfigurationApproval(value, &bytes, &error) && bytes.empty() && !error.empty(), "invalid approval clears encoded output");
}
void Refused(const std::string &bytes) {
    auto value = Fixture(); std::string error;
    Require(!P::DecodeDeconfigurationApproval(bytes, &value, &error) && !error.empty() && value.identity.empty() &&
        value.initialCheckpoint.empty() && value.nativeAuthorityIdentity.empty() && value.allowances.empty() &&
        value.primaryReview.execution.actions.empty() && value.primaryReview.binding.session.empty(), "bad wire publishes no partial approval");
}
void RoundTrip() {
    auto value = Fixture(); const auto bytes = Encode(value); P::DeconfigurationAllowanceSet decoded; std::string error;
    Require(P::DecodeDeconfigurationApproval(bytes, &decoded, &error) && error.empty() && Encode(decoded) == bytes, "canonical roundtrip");
    std::string before, after;
    Require(P::Encode(value.primaryReview, &before) && P::Encode(decoded.primaryReview, &after) && before == after, "exact whole review retained");
    const auto &old = decoded.allowances.at("victim:amd64@1");
    Require(old.installed.version == "1" && old.diskStatus == P::DpkgPackageStatus::TriggersAwaited && old.configVersion == "0.9" &&
        old.selection == P::DpkgSelection::Hold && old.causes[0].provide == B::DirectPackage && old.endpoint.action == 40 &&
        old.endpoint.precedingUnpack == 20 && old.endpoint.package.version == "2", "old history, sentinel and exact primary IDs survive");
    value.allowances.clear(); const auto empty = Encode(value);
    Require(P::DecodeDeconfigurationApproval(empty, &decoded) && decoded.allowances.empty() &&
        decoded.primaryReview.execution.actions.size() == 4 && Encode(decoded) == empty, "exact empty allowance set retains its review");
    value = Fixture(); auto &cause = value.allowances.begin()->second.causes[0];
    cause.provide = 0; cause.canonicalRelation = "virtual-victim"; cause.comparedVersion.clear();
    Require(P::DecodeDeconfigurationApproval(Encode(value), &decoded) && decoded.allowances.begin()->second.causes[0].comparedVersion.empty(),
        "unversioned provider witness stays distinct from direct package identity");
    value = Fixture(); auto allowance = value.allowances.begin()->second;
    value.allowances.clear(); allowance.installed = {"alpha", "1", "i386"}; allowance.endpoint.action = 40;
    allowance.endpoint.precedingUnpack = 0; allowance.endpoint.kind = P::ExecutionAction::Remove; allowance.endpoint.package = allowance.installed;
    auto &sibling = allowance.causes[0]; sibling.kind = P::DeconfigurationCauseKind::SiblingVersionMismatch; sibling.canonicalRelation.clear();
    value.primaryReview.execution.archives.resize(1);
    value.primaryReview.execution.actions = {value.primaryReview.execution.actions[0],
        Action(40, P::ExecutionAction::Remove, allowance.installed), Action(50, P::ExecutionAction::Configure, {"alpha", "2", "amd64"})};
    value.allowances["alpha:i386@1"] = allowance;
    Require(P::DecodeDeconfigurationApproval(Encode(value), &decoded) && decoded.allowances.begin()->second.causes[0].kind == sibling.kind,
        "sibling cause and old-generation removal endpoint have no invented Unpack");
}
void ReviewAndCauseOrder() {
    auto value = Fixture(); auto &transaction = value.primaryReview.transaction;
    // Exercise every presentation field in the shared protocol, independently
    // of whether that presentation would constitute an executable review.
    transaction.reinstalls = {"reinstall"}; transaction.downgrades = {"downgrade"};
    transaction.removes = {"remove:i386"}; transaction.purges = {"purge"}; transaction.removesEssential = true;
    CydiaAPT::TransactionClauseData clause; clause.package = "dependency:any"; clause.comparison = ">=";
    clause.version = "1:2-3"; clause.reason = "fixture reason"; clause.installed = "1:1-1";
    clause.providers = {CydiaAPT::PackageHandle(7), CydiaAPT::PackageHandle(11)};
    CydiaAPT::TransactionReasonData reason; reason.relationship = "PreDepends"; reason.clauses.push_back(clause);
    CydiaAPT::TransactionIssueData issue; issue.package = "alpha"; issue.kind = "fixture issue"; issue.reasons.push_back(reason);
    transaction.issues.push_back(issue);
    auto &identity = transaction.packages.at("alpha").identity;
    identity.aptName = "alpha:amd64"; identity.dpkgName = "alpha:amd64"; identity.multiArch = CydiaAPT::MultiArchMode::Same;
    transaction.packages.at("alpha").displayName = std::string("translated \xe5\x90\x8d\0tail", 19);
    P::DeconfigurationAllowanceSet decoded;
    Require(P::DecodeDeconfigurationApproval(Encode(value), &decoded), "populated protocol review decodes");
    std::string before, after;
    Require(P::Encode(value.primaryReview, &before) && P::Encode(decoded.primaryReview, &after) && before == after,
        "all generic transaction fields retain their exact protocol field order and bytes");

    value = Fixture(); value.primaryReview.execution.archives.push_back(Archive("beta-index", {"beta", "2", "amd64"}));
    value.primaryReview.execution.actions.insert(value.primaryReview.execution.actions.begin() + 1,
        Action(5, P::ExecutionAction::Unpack, {"beta", "2", "amd64"}, "beta-index"));
    auto &allowance = value.allowances.begin()->second; auto second = allowance.causes[0];
    second.unpackAction = 5; second.archive = "beta-index"; allowance.causes.push_back(second);
    Require(P::DecodeDeconfigurationApproval(Encode(value), &decoded) &&
        decoded.allowances.begin()->second.causes[0].unpackAction == 10 &&
        decoded.allowances.begin()->second.causes[1].unpackAction == 5,
        "causes preserve primary action order, not numeric ID sorting");
    std::swap(allowance.causes[0], allowance.causes[1]); Refused(value);

    value = Fixture(); P::InstalledPackageScripts scripts;
    scripts.prerm.path = "/var/lib/dpkg/info/victim.prerm"; scripts.prerm.bytes = "#!/bin/sh\necho private-script-body\n";
    scripts.evidenceIdentity.assign(64, 'e'); value.allowances.begin()->second.installedScriptsIdentity = scripts.evidenceIdentity;
    const auto bytes = Encode(value);
    Require(bytes.find(scripts.evidenceIdentity) != std::string::npos && bytes.find(scripts.prerm.path) == std::string::npos &&
        bytes.find(scripts.prerm.bytes) == std::string::npos, "approval carries script identity alone, without raw evidence");
    value.allowances.begin()->second.installedScriptsIdentity = scripts.prerm.bytes; Refused(value);
}
void InvalidShapes() {
    const std::vector<std::function<void(P::DeconfigurationAllowanceSet &)>> mutations = {
        [](P::DeconfigurationAllowanceSet &v) { v.identity[0] = 'A'; },
        [](P::DeconfigurationAllowanceSet &v) { v.nativeAuthorityIdentity.clear(); },
        [](P::DeconfigurationAllowanceSet &v) { v.primaryReview.binding.review.clear(); },
        [](P::DeconfigurationAllowanceSet &v) { v.primaryReview.execution.actions.clear(); },
        [](P::DeconfigurationAllowanceSet &v) { v.primaryReview.execution.actions[1].identifier = 10; },
        [](P::DeconfigurationAllowanceSet &v) { v.primaryReview.execution.actions[0].action = P::ExecutionAction::Deconfigure; },
        [](P::DeconfigurationAllowanceSet &v) { v.primaryReview.execution.actions[2].archive = "alpha-index"; },
        [](P::DeconfigurationAllowanceSet &v) { v.primaryReview.execution.archives[0].package.version = "3"; },
        [](P::DeconfigurationAllowanceSet &v) { v.primaryReview.execution.archives.push_back(Archive("unused", {"unused", "1", "all"})); },
        [](P::DeconfigurationAllowanceSet &v) { auto a = v.allowances.begin()->second; v.allowances.clear(); v.allowances["wrong:key"] = a; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.installed.package = "--option"; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.installed.architecture = "any"; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.initialStatus = P::DpkgPackageStatus::HalfConfigured; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.diskStatus = static_cast<P::DpkgPackageStatus>(99); },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.selection = static_cast<P::DpkgSelection>(99); },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.configVersion = "not-a-version"; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.installedScriptsIdentity = "opaque"; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.causes.clear(); },
        [](P::DeconfigurationAllowanceSet &v) { auto &a = v.allowances.begin()->second; a.causes.push_back(a.causes[0]); },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.causes[0].unpackAction = 30; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.causes[0].archive = "victim-index"; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.causes[0].kind = static_cast<P::DeconfigurationCauseKind>(99); },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.causes[0].group = 1; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.causes[0].alternative = 1; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.causes[0].provide = B::MaximumGroups; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.causes[0].comparedVersion = "2"; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.causes[0].canonicalRelation = "victim(<<2)"; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.endpoint.action = 999; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.endpoint.action = 10; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.endpoint.kind = P::ExecutionAction::Purge; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.endpoint.package.version = "1"; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.endpoint.precedingUnpack = 0; },
        [](P::DeconfigurationAllowanceSet &v) { v.allowances.begin()->second.endpoint.precedingUnpack = 10; }
    };
    for (const auto &mutate : mutations) { auto value = Fixture(); mutate(value); Refused(value); }
}
struct Cursor {
    const std::string &bytes; std::size_t at = 0;
    explicit Cursor(const std::string &value) : bytes(value) {}
    std::uint64_t Number(unsigned count) {
        Require(at + count <= bytes.size(), "fixture cursor bound"); std::uint64_t value = 0;
        while (count--) value = (value << 8) | static_cast<unsigned char>(bytes[at++]); return value;
    }
    void String() { const auto size = Number(4); Require(size <= bytes.size() - at, "fixture string bound"); at += size; }
    void Package() { String(); String(); String(); }
};
void Number(std::string *bytes, std::size_t at, std::uint64_t value, unsigned count = 4) {
    Require(at + count <= bytes->size(), "fixture overwrite bound");
    for (unsigned i = 0; i < count; ++i) (*bytes)[at + count - i - 1] = static_cast<char>((value >> (i * 8)) & 255);
}
struct Parts { std::size_t count, causes, selection, provide; std::vector<std::pair<std::size_t, std::size_t>> allowances; };
Parts Locate(const std::string &bytes) {
    Cursor cursor(bytes); for (unsigned i = 0; i < 5; ++i) cursor.String();
    Parts parts{}; parts.count = cursor.at; const auto count = cursor.Number(4);
    for (std::uint64_t i = 0; i < count; ++i) {
        const auto begin = cursor.at; cursor.String(); cursor.Package();
        parts.selection = cursor.at; cursor.Number(4); cursor.Number(4); cursor.Number(4);
        cursor.String(); cursor.String(); cursor.String(); parts.causes = cursor.at; const auto causes = cursor.Number(4);
        for (std::uint64_t c = 0; c < causes; ++c) {
            cursor.Number(4); cursor.Number(8); cursor.String(); cursor.String(); cursor.String();
            cursor.Number(8); cursor.Number(8); parts.provide = cursor.at; cursor.Number(8);
        }
        cursor.Number(8); cursor.Number(8); cursor.Number(4); cursor.Package();
        parts.allowances.push_back({begin, cursor.at});
    }
    Require(cursor.at == bytes.size(), "fixture frame fully traversed"); return parts;
}
void NestedCounts() {
    auto value = Fixture(); const auto bytes = Encode(value); Cursor outer(bytes);
    for (unsigned i = 0; i < 4; ++i) outer.String();
    const auto reviewLength = outer.Number(4); const auto begin = outer.at;
    std::string exact; Require(P::Encode(value.primaryReview, &exact) && bytes.substr(begin, reviewLength) == exact,
        "review is the unchanged generic protocol payload");
    P::Writer transaction;
    const auto &v = value.primaryReview.transaction;
    Require(transaction(v.registeredArchitectures, v.installs, v.reinstalls, v.upgrades, v.downgrades, v.removes, v.purges),
        "locate nested issue count");
    std::vector<std::pair<std::size_t, std::uint64_t>> prefixes = {{begin, 129},
        {begin + transaction.result().size(), P::MaximumDeconfigurationActions + 1}};
    Require(transaction(v.issues), "locate nested package map count");
    prefixes.push_back({begin + transaction.result().size(), P::MaximumDeconfigurationActions + 1});
    P::Writer manifest;
    Require(manifest(v, value.primaryReview.binding), "locate nested archive count");
    prefixes.push_back({begin + manifest.result().size(), P::MaximumDeconfigurationActions + 1});
    Require(manifest(value.primaryReview.execution.archives), "locate nested action count");
    prefixes.push_back({begin + manifest.result().size(), P::MaximumDeconfigurationActions + 1});
    for (const auto &prefix : prefixes) { auto bad = bytes; Number(&bad, prefix.first, prefix.second); Refused(bad); }
}
void MalformedFramesAndBounds() {
    auto value = Fixture(); const auto bytes = Encode(value); const auto parts = Locate(bytes);
    for (const auto count : {std::size_t(0), std::size_t(1), std::size_t(3), std::size_t(4), parts.count, parts.causes, bytes.size() - 1})
        Refused(bytes.substr(0, count));
    Refused(bytes + '\0'); auto damaged = bytes; damaged[4] = 'X'; Refused(damaged);
    damaged = bytes; Number(&damaged, 0, 0xffffffff); Refused(damaged);
    damaged = bytes; Number(&damaged, parts.count, P::MaximumDeconfigurationActions + 1); Refused(damaged);
    damaged = bytes; Number(&damaged, parts.causes, P::MaximumDeconfigurationCauses + 1); Refused(damaged);
    damaged = bytes; Number(&damaged, parts.selection, 99); Refused(damaged);
    Cursor sentinel(bytes); sentinel.at = parts.provide;
    Require(sentinel.Number(8) == std::numeric_limits<std::uint64_t>::max(), "direct-provider sentinel is portable UINT64_MAX");
    damaged = bytes; Number(&damaged, parts.provide, 0xffffffff, 8); Refused(damaged);
    value.primaryReview.execution.actions.resize(P::MaximumDeconfigurationActions + 1); Refused(value);
    value = Fixture(); value.allowances.begin()->second.causes.resize(P::MaximumDeconfigurationCauses + 1); Refused(value);
    value = Fixture(); auto &display = value.primaryReview.transaction.packages.at("alpha").displayName;
    display.append(P::MaximumDeconfigurationApprovalBytes - bytes.size(), 'x');
    const auto largest = Encode(value); Require(largest.size() == P::MaximumDeconfigurationApprovalBytes, "wire limit is inclusive");
    P::DeconfigurationAllowanceSet decoded; Require(P::DecodeDeconfigurationApproval(largest, &decoded), "exact byte limit decodes");
    display.push_back('x'); Refused(value); Refused(largest + 'x');

    value = Fixture(); auto other = value.allowances.begin()->second;
    other.installed.package = "other"; other.causes[0].canonicalRelation = "other (<< 2)";
    other.endpoint.action = 50; other.endpoint.precedingUnpack = 0; other.endpoint.kind = P::ExecutionAction::Remove; other.endpoint.package = other.installed;
    value.allowances["other:amd64@1"] = other;
    value.primaryReview.execution.actions.push_back(Action(50, P::ExecutionAction::Remove, other.installed));
    const auto ordered = Encode(value); const auto boundaries = Locate(ordered);
    Require(boundaries.allowances.size() == 2, "two map entries for canonical ordering fixture");
    const auto &first = boundaries.allowances[0]; const auto &second = boundaries.allowances[1];
    Refused(ordered.substr(0, first.first) + ordered.substr(second.first, second.second - second.first) +
        ordered.substr(first.first, first.second - first.first));
    Refused(ordered.substr(0, first.second) + ordered.substr(first.first, first.second - first.first));

    value = Fixture(); auto &causes = value.allowances.begin()->second.causes;
    std::string relation, atom = "victim (<< 2" + std::string(900, '0') + ')';
    for (unsigned i = 0; i < 1024; ++i) { if (i) relation += ", "; relation += atom; }
    auto cause = causes[0]; causes.clear(); cause.canonicalRelation = relation;
    for (unsigned i = 0; i < 9; ++i) { cause.group = i; causes.push_back(cause); }
    Require(relation.size() <= B::MaximumFieldBytes && relation.size() * causes.size() > P::MaximumDeconfigurationApprovalBytes,
        "individual relations fit but repeated total exceeds the approval byte limit");
    std::string output = "sentinel", error;
    Require(!P::EncodeDeconfigurationApproval(value, &output, &error) && output.empty() &&
        error == "provider_deconfiguration_approval_limit", "repeated relation work is bounded before growing output");
}
}
int main() {
    RoundTrip(); ReviewAndCauseOrder(); InvalidShapes(); NestedCounts(); MalformedFramesAndBounds();
    std::cout << "[deconfiguration-approval] PASS: canonical exact approvals, shape/reference checks and atomic wire bounds\n";
}
