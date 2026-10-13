/* Canonical direct Begin approvals; no native capture or package mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionRequest.hpp"
#include "Cydia/AptProviderEffectReviewBundle.hpp"
#include <cstdlib>
#include <functional>
#include <iostream>
#if defined(CYDIA_BEGIN_NATIVE_APT)
#include <apt-pkg/hashes.h>
#endif

namespace {
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[transaction-begin] " << message << '\n'; std::exit(1); }
}
P::TransactionBeginRequest Fixture() {
    P::TransactionBeginRequest begin; auto bundle = std::make_shared<P::EffectReviewBundle>();
    bundle->methodsIdentity = "methods:fixture"; auto &approval = bundle->deconfiguration;
    approval.identity.assign(64, 'a'); approval.initialCheckpoint.assign(64, 'b'); approval.nativeAuthorityIdentity.assign(64, 'c');
    auto &review = approval.primaryReview;
    review.binding.providerIdentifier = "fixture"; review.binding.session.assign(64, '1');
    review.binding.configurationIdentity = "configuration:fixture"; review.binding.policyIdentity = "policy:fixture";
    review.binding.packageStateIdentity = "state:fixture"; review.binding.review = "review:fixture";
    review.binding.cacheEpoch = 2; review.binding.selectionRevision = 3; review.transaction.registeredArchitectures = {"amd64"};
    review.transaction.installs = {"sample"}; CydiaAPT::TransactionPackageData package;
    package.identity.baseName = package.identity.routingName = "sample"; package.identity.packageArchitecture = package.identity.versionArchitecture = "amd64";
    package.version = "2"; package.displayName = "sample"; review.transaction.packages["sample"] = package;
    P::ArchiveManifest archive; archive.identifier = "sample-index"; archive.package = {"sample", "2", "amd64"};
    archive.path = "/archives/sample.deb"; archive.sourceURI = "https://example.invalid/"; archive.sourceIndexIdentity = "SHA256:" + std::string(64, 'd');
    archive.sourceDefinitionPath = "/etc/apt/sources.list.d/example.sources"; archive.sourceDefinitionOrdinal = 1;
    archive.sourceIndexPath = "/lists/Packages"; archive.sourceIndexURI = "https://example.invalid/Packages";
    archive.filename = "sample.deb"; archive.recordOffset = 128; archive.recordSize = 256; archive.hashes["SHA256"] = std::string(64, 'e');
    archive.size = 1024; archive.layout.prefix = "/"; review.execution.archives.push_back(archive);
    auto breaker = archive; breaker.identifier = "breaker-index"; breaker.package = {"breaker", "2", "amd64"};
    breaker.path = "/archives/breaker.deb"; breaker.filename = "breaker.deb"; breaker.recordOffset = 512;
    review.execution.archives.insert(review.execution.archives.begin(), breaker);
    auto breakerPackage = package; breakerPackage.identity.baseName = breakerPackage.identity.routingName = "breaker";
    breakerPackage.displayName = "breaker"; review.transaction.packages["breaker"] = breakerPackage;
    review.transaction.installs.push_back("breaker");
    P::ReviewedAction causeAction; causeAction.identifier = 5; causeAction.action = P::ExecutionAction::Unpack;
    causeAction.package = breaker.package; causeAction.archive = breaker.identifier; review.execution.actions.push_back(causeAction);
    P::ReviewedAction action; action.identifier = 10; action.action = P::ExecutionAction::Unpack; action.package = archive.package; action.archive = archive.identifier;
    review.execution.actions.push_back(action); action.identifier = 20; action.action = P::ExecutionAction::Configure; action.archive.clear(); review.execution.actions.push_back(action);
    P::DeconfigurationAllowance allowance; allowance.installed = {"sample", "1", "amd64"}; allowance.selection = P::DpkgSelection::Hold;
    allowance.initialStatus = allowance.diskStatus = P::DpkgPackageStatus::Installed; allowance.installedControlIdentity.assign(64, 'e');
    allowance.installedScriptsIdentity.assign(64, 'f'); P::DeconfigurationCause cause; cause.unpackAction = 5; cause.archive = breaker.identifier;
    cause.canonicalRelation = "sample (<< 2)"; cause.comparedVersion = "1"; allowance.causes.push_back(cause);
    allowance.endpoint.action = 20; allowance.endpoint.precedingUnpack = 10; allowance.endpoint.package = archive.package;
    approval.allowances["sample:amd64@1"] = allowance;
    auto &triggers = bundle->triggers; triggers.identity.assign(64, '9'); triggers.initialCheckpoint = approval.initialCheckpoint;
    triggers.nativeAuthorityIdentity = approval.nativeAuthorityIdentity; triggers.primaryReview = review;
    triggers.recipients["sample:amd64@2"] = archive.package; triggers.awaiters = triggers.recipients; triggers.incoming.insert("sample:amd64@2");
    begin.review = review; begin.reviewedEffects = std::make_shared<const P::TriggerEffectEnvelope>(triggers);
    begin.reviewedDeconfiguration = bundle; begin.changes = {{"sample", "amd64", true}}; begin.additionalActions = {20};
    begin.archiveWarnings = {archive.identifier}; begin.extendedState = "Package: sample\nArchitecture: amd64\nAuto-Installed: 1\n\n";
    return begin;
}
std::string Encode(const P::TransactionBeginRequest &value) {
    std::string bytes; Require(P::EncodeTransactionBegin(value, &bytes), "valid Begin encodes"); return bytes;
}
void Refused(const P::TransactionBeginRequest &value) {
    std::string bytes = "sentinel";
    Require(!P::EncodeTransactionBegin(value, &bytes) && bytes.empty(), "invalid Begin clears encoded output");
}
void Refused(const std::string &bytes) {
    auto value = Fixture();
    Require(!P::DecodeTransactionBegin(bytes, &value) && value.review.binding.session.empty() && value.changes.empty() &&
        value.additionalActions.empty() && value.archiveWarnings.empty() && value.extendedState.empty() &&
        !value.reviewedEffects && !value.reviewedDeconfiguration, "bad wire clears all old/partial approval state");
}
void V3AndLegacy() {
    const auto original = Fixture(); Require(original.formatVersion == 3, "new Begin defaults to v3");
    const auto bytes = Encode(original); P::TransactionBeginRequest decoded;
    Require(bytes.find("CYDIA-TRANSACTION-BEGIN-3") != std::string::npos && P::DecodeTransactionBegin(bytes, &decoded) &&
        decoded.formatVersion == 3 && decoded.reviewedDeconfiguration && Encode(decoded) == bytes, "canonical v3 carries paired immutable approvals");
    std::string before, after;
    Require(P::EncodeEffectReviewBundle(*original.reviewedDeconfiguration, &before) &&
        P::EncodeEffectReviewBundle(*decoded.reviewedDeconfiguration, &after) && before == after &&
        decoded.reviewedDeconfiguration->deconfiguration.allowances.at("sample:amd64@1").endpoint.action == 20,
        "all old-generation, cause and endpoint approval bytes survive");
    auto legacy = original; legacy.formatVersion = 2; legacy.reviewedDeconfiguration.reset();
    const auto old = Encode(legacy); std::string triggers; Require(P::EncodeTriggerEffectEnvelope(*legacy.reviewedEffects, &triggers), "legacy trigger encoding");
    P::Writer exact; Require(exact(std::string("CYDIA-TRANSACTION-BEGIN-2"), legacy.review, legacy.additionalActions, legacy.archiveWarnings,
        legacy.changes, legacy.extendedState, triggers) && exact.result() == old, "v2 byte framing remains unchanged for existing clients");
    Require(P::DecodeTransactionBegin(old, &decoded) && decoded.formatVersion == 2 && !decoded.reviewedDeconfiguration && Encode(decoded) == old,
        "legacy canonical decoding never adds conditional permission");
    legacy = original; legacy.formatVersion = 2; Refused(legacy);
    legacy = original; legacy.formatVersion = 4; Refused(legacy);
}
void BindingAndMalformed() {
    const auto original = Fixture();
    auto invalid = original; invalid.reviewedEffects.reset(); Refused(invalid);
    invalid = original; auto triggers = std::make_shared<P::TriggerEffectEnvelope>(*invalid.reviewedEffects);
    triggers->identity.assign(64, '8'); invalid.reviewedEffects = triggers; Refused(invalid);
    invalid = original; ++invalid.review.binding.cacheEpoch; Refused(invalid);
    invalid = original; auto bundle = std::make_shared<P::EffectReviewBundle>(*invalid.reviewedDeconfiguration);
    bundle->triggers.initialCheckpoint.assign(64, '8'); invalid.reviewedDeconfiguration = bundle; Refused(invalid);
    invalid = original; bundle = std::make_shared<P::EffectReviewBundle>(*invalid.reviewedDeconfiguration);
    bundle->deconfiguration.allowances.begin()->second.endpoint.action = 999; invalid.reviewedDeconfiguration = bundle; Refused(invalid);
    const auto bytes = Encode(original); Refused(""); Refused(bytes + "x"); Refused(bytes.substr(0, bytes.size() - 1));
    for (std::size_t end = 1; end < bytes.size(); end += 113) Refused(bytes.substr(0, end));
    auto changed = bytes; const auto tag = changed.find("CYDIA-TRANSACTION-BEGIN-3"); Require(tag != std::string::npos, "v3 tag present");
    changed[tag] = 'X'; Refused(changed);
    // v3 requires its final field even for a legacy primary-only request.
    auto ordinary = original; ordinary.reviewedDeconfiguration.reset(); ordinary.reviewedEffects.reset();
    P::Writer missing; Require(missing(std::string("CYDIA-TRANSACTION-BEGIN-3"), ordinary.review, ordinary.additionalActions,
        ordinary.archiveWarnings, ordinary.changes, ordinary.extendedState, std::string()), "missing-field fixture encodes"); Refused(missing.result());
}
void AggregateBound() {
    auto value = Fixture(); auto bundle = std::make_shared<P::EffectReviewBundle>(*value.reviewedDeconfiguration);
    value.review.transaction.packages.at("sample").displayName.assign(P::MaximumTransactionBeginBytes / 8, 'x');
    bundle->triggers.primaryReview = bundle->deconfiguration.primaryReview = value.review;
    value.reviewedDeconfiguration = bundle; value.reviewedEffects = std::make_shared<const P::TriggerEffectEnvelope>(bundle->triggers);
    std::string paired; Require(P::EncodeEffectReviewBundle(*bundle, &paired) && paired.size() < P::MaximumTransactionBeginBytes,
        "paired approval fits its standalone total ceiling");
    Require(Encode(value).size() < P::MaximumTransactionBeginBytes, "large Begin remains bounded without state padding");
    value.extendedState.assign(4 * 1024 * 1024, 'x'); Refused(value);
    Refused(std::string(P::MaximumTransactionBeginBytes + 1, 'x'));
}
#if defined(CYDIA_BEGIN_NATIVE_APT)
std::string Digest(const std::string &domain, const std::string &bytes) {
    Hashes hashes(Hashes::SHA256SUM); Require(hashes.Add(domain.data(), domain.size()) && hashes.Add(bytes.data(), bytes.size()), "hash Begin fixture");
    return hashes.GetHashString(Hashes::SHA256SUM).HashValue();
}
void Digests() {
    const auto value = Fixture(); const auto bytes = Encode(value); const auto digest = P::TransactionBeginDigest(value);
    Require(digest.size() == 64 && digest == Digest("CYDIA-TRANSACTION-REVIEW-3", bytes), "v3 digest binds complete canonical Begin");
    auto changed = value; auto bundle = std::make_shared<P::EffectReviewBundle>(*changed.reviewedDeconfiguration);
    bundle->methodsIdentity = "methods:changed"; changed.reviewedDeconfiguration = bundle;
    Require(P::TransactionBeginDigest(changed) != digest, "method change cannot reuse Begin digest");
    changed = value; bundle = std::make_shared<P::EffectReviewBundle>(*changed.reviewedDeconfiguration);
    bundle->deconfiguration.identity.assign(64, '7'); changed.reviewedDeconfiguration = bundle;
    Require(P::TransactionBeginDigest(changed) != digest, "conditional identity cannot reuse Begin digest");
    changed = value; changed.extendedState += "\n"; Require(P::TransactionBeginDigest(changed) != digest, "commit baseline is bound");
    changed = value; changed.formatVersion = 2; changed.reviewedDeconfiguration.reset();
    Require(P::TransactionBeginDigest(changed) == Digest("CYDIA-TRANSACTION-REVIEW-2", Encode(changed)), "legacy digest remains byte-compatible");
    changed.reviewedDeconfiguration = value.reviewedDeconfiguration;
    Require(P::TransactionBeginDigest(changed).empty(), "invalid legacy approval has no digest");
}
#endif
}
int main() {
    V3AndLegacy(); BindingAndMalformed(); AggregateBound();
#if defined(CYDIA_BEGIN_NATIVE_APT)
    Digests();
#endif
    std::cout << "transaction Begin passed\n";
}
