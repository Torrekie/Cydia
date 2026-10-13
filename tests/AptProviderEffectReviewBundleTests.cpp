/* Paired read-only transport fixtures; no native policy, capture or mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderEffectReviewBundle.hpp"
#include <cstdlib>
#include <functional>
#include <iostream>

namespace {
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[effect-review-bundle] " << message << '\n'; std::exit(1); }
}
P::ReviewedAction Action(std::uint64_t id, P::ExecutionAction kind, P::ExecutionPackage package, const std::string &archive = "") {
    P::ReviewedAction result; result.identifier = id; result.action = kind; result.package = std::move(package); result.archive = archive; return result;
}
P::ArchiveManifest Archive(const std::string &id, P::ExecutionPackage package) {
    P::ArchiveManifest result; result.identifier = id; result.package = std::move(package); result.path = "/archives/" + id + ".deb";
    result.sourceURI = "https://example.invalid/"; result.sourceIndexIdentity = "SHA256:" + std::string(64, 'e');
    result.sourceDefinitionPath = "/etc/apt/sources.list.d/example.sources"; result.sourceIndexPath = "/lists/Packages";
    result.sourceIndexURI = "https://example.invalid/Packages"; result.filename = id + ".deb"; result.sourceDefinitionOrdinal = 1;
    result.recordOffset = 128; result.recordSize = 256; result.hashes["SHA256"] = std::string(64, 'f'); result.size = 1024; result.layout.prefix = "/";
    return result;
}
P::EffectReviewBundle Fixture() {
    P::EffectReviewBundle result; result.methodsIdentity = "methods:fixture";
    auto &approval = result.deconfiguration;
    approval.identity.assign(64, 'a'); approval.initialCheckpoint.assign(64, 'b'); approval.nativeAuthorityIdentity.assign(64, 'c');
    auto &review = approval.primaryReview;
    review.binding.providerIdentifier = "fixture"; review.binding.session.assign(64, '1');
    review.binding.configurationIdentity = "configuration:fixture"; review.binding.policyIdentity = "policy:fixture";
    review.binding.packageStateIdentity = "state:fixture"; review.binding.review = "review:fixture";
    review.binding.cacheEpoch = 2; review.binding.selectionRevision = 3;
    review.transaction.registeredArchitectures = {"amd64", "i386"}; review.transaction.installs = {"alpha"}; review.transaction.upgrades = {"victim"};
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
    allowance.initialStatus = P::DpkgPackageStatus::Installed; allowance.diskStatus = P::DpkgPackageStatus::Installed;
    allowance.configVersion = "0.9"; allowance.installedControlIdentity.assign(64, 'd'); allowance.installedScriptsIdentity.assign(64, 'e');
    P::DeconfigurationCause cause; cause.unpackAction = 10; cause.archive = "alpha-index"; cause.canonicalRelation = "victim (<< 2)"; cause.comparedVersion = "1";
    allowance.causes.push_back(cause); allowance.endpoint.action = 40; allowance.endpoint.precedingUnpack = 20;
    allowance.endpoint.kind = P::ExecutionAction::Configure; allowance.endpoint.package = {"victim", "2", "amd64"};
    approval.allowances["victim:amd64@1"] = allowance;
    auto &triggers = result.triggers; triggers.identity.assign(64, 'f'); triggers.initialCheckpoint = approval.initialCheckpoint;
    triggers.nativeAuthorityIdentity = approval.nativeAuthorityIdentity; triggers.primaryReview = review;
    triggers.recipients["alpha:amd64@2"] = {"alpha", "2", "amd64"}; triggers.awaiters = triggers.recipients; triggers.incoming.insert("alpha:amd64@2");
    return result;
}
std::string Encode(const P::EffectReviewBundle &value) {
    std::string bytes, error; Require(P::EncodeEffectReviewBundle(value, &bytes, &error) && error.empty(), "valid bundle encodes"); return bytes;
}
void Refused(const P::EffectReviewBundle &value) {
    std::string bytes = "sentinel", error;
    Require(!P::EncodeEffectReviewBundle(value, &bytes, &error) && bytes.empty() && !error.empty(), "invalid bundle clears output");
}
void Refused(const std::string &bytes) {
    auto value = Fixture(); std::string error;
    Require(!P::DecodeEffectReviewBundle(bytes, &value, &error) && !error.empty() && value.methodsIdentity.empty() &&
        value.triggers.identity.empty() && value.triggers.primaryReview.execution.actions.empty() &&
        value.deconfiguration.identity.empty() && value.deconfiguration.allowances.empty(), "invalid wire publishes no partial bundle");
}
void PairAndExactReview() {
    const auto original = Fixture(); const auto bytes = Encode(original); P::EffectReviewBundle decoded; std::string error;
    Require(P::DecodeEffectReviewBundle(bytes, &decoded, &error) && error.empty() && Encode(decoded) == bytes, "canonical bundle roundtrip");
    Require(P::EffectReviewBundleMatches(decoded, original.deconfiguration.primaryReview, original.methodsIdentity, &error), "exact review and method match");
    auto changed = original.deconfiguration.primaryReview; changed.binding.session.assign(64, '2');
    Require(!P::EffectReviewBundleMatches(decoded, changed, original.methodsIdentity, &error), "other session cannot reuse approval");
    changed = original.deconfiguration.primaryReview; changed.binding.packageStateIdentity = "state:other";
    Require(!P::EffectReviewBundleMatches(decoded, changed, original.methodsIdentity), "other state cannot reuse approval");
    changed = original.deconfiguration.primaryReview; changed.transaction.packages.at("alpha").displayName = "changed display";
    Require(!P::EffectReviewBundleMatches(decoded, changed, original.methodsIdentity), "presentation is part of exact review");
    Require(!P::EffectReviewBundleMatches(decoded, original.deconfiguration.primaryReview, "methods:other"), "other acquisition methods cannot reuse approval");
    auto empty = original; empty.deconfiguration.allowances.clear(); empty.triggers.recipients.clear(); empty.triggers.awaiters.clear(); empty.triggers.incoming.clear();
    Require(P::DecodeEffectReviewBundle(Encode(empty), &decoded) && decoded.deconfiguration.allowances.empty(), "empty pools still bind one exact review/checkpoint");
    const std::vector<std::function<void(P::EffectReviewBundle &)>> mutations = {
        [](P::EffectReviewBundle &v) { v.methodsIdentity.clear(); },
        [](P::EffectReviewBundle &v) { v.methodsIdentity = "bad\nmethod"; },
        [](P::EffectReviewBundle &v) { v.triggers.initialCheckpoint.assign(64, '9'); },
        [](P::EffectReviewBundle &v) { v.deconfiguration.nativeAuthorityIdentity.assign(64, '9'); },
        [](P::EffectReviewBundle &v) { ++v.triggers.primaryReview.binding.cacheEpoch; },
        [](P::EffectReviewBundle &v) { ++v.deconfiguration.primaryReview.binding.selectionRevision; },
        [](P::EffectReviewBundle &v) { v.triggers.identity[0] = 'A'; },
        [](P::EffectReviewBundle &v) { v.deconfiguration.allowances.begin()->second.endpoint.action = 999; },
        [](P::EffectReviewBundle &v) { v.triggers.awaiters.clear(); }
    };
    for (const auto &mutate : mutations) { auto invalid = original; mutate(invalid); Refused(invalid); }
}
void CaptureRequest() {
    const auto bundle = Fixture(); P::EffectReviewCaptureRequest request; request.review = bundle.deconfiguration.primaryReview;
    request.methodsIdentity = bundle.methodsIdentity; std::string bytes, canonical, error;
    Require(P::EncodeEffectReviewCaptureRequest(request, &bytes, &error) && error.empty(), "capture request encodes");
    P::EffectReviewCaptureRequest decoded;
    Require(P::DecodeEffectReviewCaptureRequest(bytes, &decoded, &error) && error.empty() &&
        P::EncodeEffectReviewCaptureRequest(decoded, &canonical) && canonical == bytes, "capture request roundtrip");
    Require(decoded.review.binding.session == request.review.binding.session && decoded.methodsIdentity == request.methodsIdentity,
        "method and exact app session survive capture framing");
    for (const auto &bad : {std::string(), bytes.substr(0, bytes.size() - 1), bytes + "x", std::string(P::MaximumEffectReviewBundleBytes + 1, 'x')}) {
        decoded = request;
        Require(!P::DecodeEffectReviewCaptureRequest(bad, &decoded, &error) && !error.empty() &&
            decoded.methodsIdentity.empty() && decoded.review.execution.actions.empty(), "malformed request clears decoded output");
    }
    request.methodsIdentity.clear(); bytes = "sentinel";
    Require(!P::EncodeEffectReviewCaptureRequest(request, &bytes, &error) && bytes.empty() && !error.empty(), "missing method cannot reach native capture");
    request.methodsIdentity = bundle.methodsIdentity; request.review.binding.session.clear(); bytes = "sentinel";
    Require(!P::EncodeEffectReviewCaptureRequest(request, &bytes, &error) && bytes.empty(), "missing session cannot reach native capture");
}
void WireAndTotalBound() {
    auto bundle = Fixture(); const auto bytes = Encode(bundle);
    Refused(""); Refused(bytes + "x"); Refused(bytes.substr(0, bytes.size() - 1));
    for (std::size_t end = 1; end < bytes.size(); end += 97) Refused(bytes.substr(0, end));
    auto changed = bytes; const auto tag = changed.find("CYDIA-EFFECT-REVIEW-BUNDLE-1");
    Require(tag != std::string::npos, "bundle tag present"); changed[tag] = 'X'; Refused(changed);
    // An extra framing byte cannot shift an otherwise valid member prefix.
    changed = bytes; changed.insert(changed.begin(), '0'); Refused(changed);
    std::string triggers, deconfiguration; Require(P::EncodeTriggerEffectEnvelope(bundle.triggers, &triggers) &&
        P::EncodeDeconfigurationApproval(bundle.deconfiguration, &deconfiguration), "standalone members encode");
    P::Writer swapped; Require(swapped(std::string("CYDIA-EFFECT-REVIEW-BUNDLE-1"), bundle.methodsIdentity, deconfiguration, triggers), "swapped fixture encodes");
    Refused(swapped.result());
    auto large = bundle; large.deconfiguration.primaryReview.transaction.packages.at("alpha").displayName.assign(P::MaximumEffectReviewBundleBytes / 4, 'x');
    large.triggers.primaryReview = large.deconfiguration.primaryReview;
    Require(Encode(large).size() < P::MaximumEffectReviewBundleBytes, "bounded large pair retains complete presentation");
    large.deconfiguration.primaryReview.transaction.packages.at("alpha").displayName.assign(P::MaximumEffectReviewBundleBytes / 2, 'x');
    large.triggers.primaryReview = large.deconfiguration.primaryReview;
    Require(P::EncodeTriggerEffectEnvelope(large.triggers, &triggers) && P::EncodeDeconfigurationApproval(large.deconfiguration, &deconfiguration) &&
        triggers.size() < P::MaximumEffectReviewBundleBytes && deconfiguration.size() < P::MaximumEffectReviewBundleBytes,
        "both members fit standalone limits");
    Refused(large); // Combined frame cannot inherit two independent ceilings.
    Refused(std::string(P::MaximumEffectReviewBundleBytes + 1, 'x'));
}
}
int main() { PairAndExactReview(); CaptureRequest(); WireAndTotalBound(); std::cout << "effect review bundle passed\n"; }
