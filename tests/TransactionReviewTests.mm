/* Immutable native confirmation tests; Foundation only, no package operations.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#include "Cydia/TransactionReview.h"
#include "Cydia/RuntimeProviderStatus.h"
#include <cstdlib>
#include <iostream>

// Use the same localization call contract with a deterministic English
// fallback. The real architecture caption helper retains its bundle lookup.
NSString *CydiaRuntimeProviderLocalize(NSString *key) {
    NSDictionary<NSString *, NSString *> *fallbacks = @{
        @"REVIEW_UNPACK": @"Unpack", @"REVIEW_CONFIGURE": @"Configure",
        @"REVIEW_REMOVE": @"Remove", @"REVIEW_PURGE": @"Purge",
        @"REVIEW_TRIGGERS": @"Process Triggers", @"REVIEW_DECONFIGURE": @"Deconfigure",
        @"ARCHIVE_REVIEW_LIMITS": @"Review installation scripts and shared locations for %@.",
        @"RECOVERY_REVIEW": @"Cydia’s bundled APT will apply the selected repository security settings."
    };
    return [[NSBundle mainBundle] localizedStringForKey:key value:fallbacks[key] ?: key table:@"RuntimeProvider"];
}

namespace {
namespace P = CydiaAPT::Provider;
void Require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "[transaction-review] " << message << '\n';
        std::exit(1);
    }
}
void Text(NSString *actual, NSString *expected, const char *message) {
    Require(actual != nil && [actual isEqualToString:expected], message);
}
void Row(NSArray<NSDictionary<NSString *, NSString *> *> *rows, NSUInteger position,
         NSString *title, NSString *detail) {
    Require(position < rows.count, "expected review row is missing");
    Text(rows[position][@"title"], title, "review row has the wrong package or operation");
    Text(rows[position][@"detail"], detail, "review row has the wrong version or notice");
}
P::ReviewedAction Action(std::uint64_t id, P::ExecutionAction kind, const char *package,
                         const char *architecture, const char *version = "1.0") {
    P::ReviewedAction result;
    result.identifier = id; result.action = kind; result.package = {package, version, architecture};
    return result;
}
P::ArchiveManifest Archive(const char *id, const P::ExecutionPackage &package) {
    P::ArchiveManifest result;
    result.identifier = id; result.package = package;
    return result;
}
struct Fixture {
    CydiaAPT::TransactionData transaction;
    P::ReviewedTransaction provider;
    Fixture() {
        transaction.registeredArchitectures = {"iphoneos-arm64"};
        transaction.installs = {"native-package", "independent-package"};
        for (const auto &entry : std::vector<std::pair<std::string, std::string>>{
                 {"native-package", "iphoneos-arm64"}, {"independent-package", "all"}}) {
            CydiaAPT::TransactionPackageData package;
            package.identity = CydiaAPT::BuildPackageIdentity(entry.first, "iphoneos-arm64", entry.second,
                "iphoneos-arm64", CydiaAPT::MultiArchMode::None);
            package.version = "1.0"; package.displayName = entry.first;
            transaction.packages.emplace(entry.first, package);
        }
        transaction.downloading = 100; transaction.resuming = 25;
        provider.transaction = transaction;
        provider.execution.actions = {
            Action(17, P::ExecutionAction::Unpack, "native-package", "iphoneos-arm64"),
            Action(29, P::ExecutionAction::Configure, "native-package", "iphoneos-arm64"),
            Action(42, P::ExecutionAction::Unpack, "independent-package", "all"),
            Action(58, P::ExecutionAction::Configure, "independent-package", "all")
        };
        provider.execution.archives = {
            Archive("native-archive", provider.execution.actions[0].package),
            Archive("independent-archive", provider.execution.actions[2].package)
        };
        provider.execution.actions[0].archive = "native-archive";
        provider.execution.actions[2].archive = "independent-archive";
    }
    CydiaTransactionReview *Make() const {
        return [[CydiaTransactionReview alloc] initWithTransaction:transaction providerReview:&provider
            runtimeOrigin:CydiaAPT::RuntimeDescriptorOrigin::External];
    }
};

void ImmutableOwnedSnapshot() {
    Fixture fixture;
    const auto original(fixture.transaction);
    CydiaTransactionReview *review(fixture.Make());
    Require(review != nil && [review matchesTransaction:original], "initial transaction does not match");
    fixture.transaction.installs.front() = "replacement";
    fixture.transaction.packages["native-package"].version = "9.0";
    fixture.transaction.registeredArchitectures.push_back("iphoneos-arm");
    fixture.provider.execution.actions[0].identifier = 999;
    fixture.provider.execution.actions[0].package.package = "replacement";
    fixture.provider.execution.archives[0].identifier = "replacement-archive";
    Require([review transaction].installs == original.installs, "review borrowed the input package list");
    Require([review transaction].packages.at("native-package").version == "1.0", "review borrowed nested package metadata");
    Require([review transaction].registeredArchitectures == original.registeredArchitectures, "review borrowed architecture metadata");
    Require([review matchesTransaction:original] && ![review matchesTransaction:fixture.transaction],
        "mutation of the original input changed the approved snapshot");
    Require([review displayedActions] == std::set<std::uint64_t>({17, 29, 42, 58}), "action IDs were not copied");
    Require([review displayedArchiveWarnings] == std::set<std::string>({"native-archive", "independent-archive"}),
        "archive warning IDs were not copied");
    Row(review.operations, 0, @"Unpack: native-package", @"1.0");
    Require(![review.operations isKindOfClass:[NSMutableArray class]] &&
        ![review.archiveWarningRows isKindOfClass:[NSMutableArray class]], "published row arrays remain mutable");
}

void ChangesInvalidateTheSnapshot() {
    Fixture fixture;
    CydiaTransactionReview *review(fixture.Make());
    for (unsigned change = 0; change != 6; ++change) {
        auto changed(fixture.transaction);
        switch (change) {
            case 0: changed.packages["native-package"].version = "2.0"; break;
            case 1: changed.registeredArchitectures.push_back("iphoneos-arm"); break;
            case 2: ++changed.downloading; break;
            case 3: changed.removesEssential = true; break;
            case 4: changed.installs.pop_back(); break;
            case 5: {
                CydiaAPT::TransactionIssueData issue; issue.package = "native-package"; issue.kind = "Depends";
                changed.issues.push_back(issue); break;
            }
        }
        Require(![review matchesTransaction:changed], "a changed transaction was accepted as the approved snapshot");
    }
}

void ExactRowsAndSingleArchitecture() {
    Fixture fixture;
    CydiaTransactionReview *review(fixture.Make());
    Require(review.operations.count == [review displayedActions].size(), "an action ID has no visible row");
    Require(review.archiveWarningRows.count == [review displayedArchiveWarnings].size(), "a warning ID has no visible row");
    Row(review.operations, 0, @"Unpack: native-package", @"1.0");
    Row(review.operations, 1, @"Configure: native-package", @"1.0");
    Row(review.operations, 2, @"Unpack: independent-package", @"1.0");
    Row(review.operations, 3, @"Configure: independent-package", @"1.0");
    Row(review.archiveWarningRows, 0, @"native-package 1.0",
        @"Review installation scripts and shared locations for native-package.");
    Row(review.archiveWarningRows, 1, @"independent-package 1.0",
        @"Review installation scripts and shared locations for independent-package.");
    Text(review.runtimeNotice, @"", "external review unexpectedly shows the recovery notice");
}

void DistinctForeignArchitecture() {
    Fixture fixture;
    fixture.transaction.registeredArchitectures.push_back("iphoneos-arm");
    fixture.provider.execution.actions.push_back(Action(99, P::ExecutionAction::Remove,
        "foreign-package", "iphoneos-arm", "2.0"));
    CydiaTransactionReview *review(fixture.Make());
    Row(review.operations, 0, @"Unpack: native-package (Native · iphoneos-arm64)", @"1.0");
    Row(review.operations, 2, @"Unpack: independent-package (Architecture-independent · all)", @"1.0");
    Row(review.operations, 4, @"Remove: foreign-package (Additional · iphoneos-arm)", @"2.0");
    Require([review displayedActions].count(99) == 1, "foreign package action is absent from approval IDs");
}

void EveryKnownActionIsVisibleAndUnknownRejected() {
    Fixture fixture;
    fixture.provider.execution.actions = {
        Action(1, P::ExecutionAction::Unpack, "unpack", "all"),
        Action(2, P::ExecutionAction::Configure, "configure", "all"),
        Action(3, P::ExecutionAction::Remove, "remove", "all"),
        Action(4, P::ExecutionAction::Purge, "purge", "all"),
        Action(5, P::ExecutionAction::Triggers, "trigger", "all"),
        Action(6, P::ExecutionAction::Deconfigure, "deconfigure", "all")
    };
    fixture.provider.execution.archives.clear();
    CydiaTransactionReview *review(fixture.Make());
    Require(review.operations.count == 6 && [review displayedActions] == std::set<std::uint64_t>({1, 2, 3, 4, 5, 6}),
        "a known action was omitted from rows or approval IDs");
    Row(review.operations, 3, @"Purge: purge", @"1.0");
    Row(review.operations, 4, @"Process Triggers: trigger", @"1.0");
    Row(review.operations, 5, @"Deconfigure: deconfigure", @"1.0");
    fixture.provider.execution.actions.back().action = static_cast<P::ExecutionAction>(99);
    Require(fixture.Make() == nil, "unknown action was silently hidden from an otherwise accepted review");
    fixture.provider.execution.actions.back().action = P::ExecutionAction::Deconfigure;
    fixture.provider.execution.actions.back().identifier = 1;
    Require(fixture.Make() == nil, "duplicate action IDs produced ambiguous visible approval");

    Fixture warnings;
    warnings.provider.execution.archives.back().identifier = warnings.provider.execution.archives.front().identifier;
    Require(warnings.Make() == nil, "duplicate archive warning IDs produced ambiguous visible approval");
}

void EmbeddedRecoveryNotice() {
    Fixture fixture;
    CydiaTransactionReview *embedded([[CydiaTransactionReview alloc] initWithTransaction:fixture.transaction providerReview:nullptr
        runtimeOrigin:CydiaAPT::RuntimeDescriptorOrigin::Embedded]);
    Require(embedded != nil && [embedded matchesTransaction:fixture.transaction], "embedded transaction snapshot is missing");
    Text(embedded.runtimeNotice, CydiaRuntimeProviderLocalize(@"RECOVERY_REVIEW"), "embedded recovery notice is missing");
    Require(embedded.operations.count == 0 && embedded.archiveWarningRows.count == 0 &&
        [embedded displayedActions].empty() && [embedded displayedArchiveWarnings].empty(),
        "embedded review invented provider approval IDs");
}
void RecoveryWorkerNotice() {
    Fixture fixture;
    using Origin = CydiaAPT::RuntimeDescriptorOrigin;
    auto origin = Origin::RecoveryWorker;
    CydiaTransactionReview *recovery([[CydiaTransactionReview alloc] initWithTransaction:fixture.transaction
        providerReview:&fixture.provider runtimeOrigin:origin]);
    Require(recovery != nil && recovery.runtimeOrigin == Origin::RecoveryWorker && recovery.operations.count == 4,
        "private recovery keeps exact protocol review while retaining its adopted runtime origin");
    Text(recovery.runtimeNotice, CydiaRuntimeProviderLocalize(@"RECOVERY_REVIEW"), "private recovery worker policy notice is missing");
    origin = Origin::External; fixture.provider.binding.providerIdentifier = "different-provider";
    Require(recovery.runtimeOrigin == Origin::RecoveryWorker, "retained origin changed with later caller state");
    Text(recovery.runtimeNotice, CydiaRuntimeProviderLocalize(@"RECOVERY_REVIEW"), "later provider state erased reviewed policy notice");
    CydiaTransactionReview *external([[CydiaTransactionReview alloc] initWithTransaction:fixture.transaction
        providerReview:&fixture.provider runtimeOrigin:origin]);
    Text(external.runtimeNotice, @"", "external origin inherited another runtime's recovery notice");
    Require([[CydiaTransactionReview alloc] initWithTransaction:fixture.transaction providerReview:nullptr
        runtimeOrigin:Origin::External] == nil, "missing external protocol review cannot become embedded recovery");
    Require([[CydiaTransactionReview alloc] initWithTransaction:fixture.transaction providerReview:&fixture.provider
        runtimeOrigin:Origin::Embedded] == nil, "embedded origin cannot borrow a worker review");
}
void ImmutableProcessingPool() {
    Fixture fixture;
    auto &binding = fixture.provider.binding;
    binding.providerIdentifier = "fixture"; binding.session.assign(64, 'a');
    binding.configurationIdentity = "config"; binding.policyIdentity = "policy"; binding.packageStateIdentity = "state";
    binding.cacheEpoch = 1; binding.selectionRevision = 1; binding.review = "review";
    fixture.transaction.registeredArchitectures.push_back("iphoneos-arm");
    P::TriggerEffectEnvelope effects;
    effects.identity.assign(64, 'a'); effects.initialCheckpoint.assign(64, 'b'); effects.nativeAuthorityIdentity.assign(64, 'c');
    effects.primaryReview = fixture.provider;
    effects.recipients = {{"foreign-package:iphoneos-arm@2.0", {"foreign-package", "2.0", "iphoneos-arm"}}};
    effects.awaiters = effects.recipients;
    effects.awaiters.emplace("native-package:iphoneos-arm64@1.0", P::ExecutionPackage{"native-package", "1.0", "iphoneos-arm64"});
    CydiaTransactionReview *review([[CydiaTransactionReview alloc] initWithTransaction:fixture.transaction
        providerReview:&fixture.provider runtimeOrigin:CydiaAPT::RuntimeDescriptorOrigin::External reviewedEffects:&effects]);
    Require(review != nil && review.processingRows.count == 2 && [review displayedEffectsIdentity] == effects.identity,
        "processing approval retains exact union and native authority binding");
    Row(review.processingRows, 0, @"foreign-package (Additional · iphoneos-arm)", @"2.0");
    Row(review.processingRows, 1, @"native-package (Native · iphoneos-arm64)", @"1.0");
    effects.identity.assign(64, 'f'); effects.awaiters.clear();
    Require([review displayedEffectsIdentity] == std::string(64, 'a') && review.processingRows.count == 2 &&
        ![review.processingRows isKindOfClass:[NSMutableArray class]], "displayed processing pool cannot mutate with input");
    effects.awaiters = effects.recipients; effects.primaryReview.binding.review = "different-review";
    Require([[CydiaTransactionReview alloc] initWithTransaction:fixture.transaction providerReview:&fixture.provider
        runtimeOrigin:CydiaAPT::RuntimeDescriptorOrigin::External reviewedEffects:&effects] == nil,
        "processing approval cannot hide a changed primary review");
}
std::shared_ptr<P::EffectReviewBundle> ConditionalFixture(Fixture &fixture) {
    auto &binding(fixture.provider.binding);
    binding.providerIdentifier = "fixture"; binding.session.assign(64, 'a'); binding.configurationIdentity = "config";
    binding.policyIdentity = "policy"; binding.packageStateIdentity = "state"; binding.review = "review";
    binding.cacheEpoch = binding.selectionRevision = 1;
    fixture.provider.transaction = fixture.transaction;
    const auto primary(fixture.provider.execution.actions);
    fixture.provider.execution.actions = {primary[2], primary[0], primary[1], primary[3]};
    auto bundle = std::make_shared<P::EffectReviewBundle>(); bundle->methodsIdentity = "methods:fixture";
    auto &approval(bundle->deconfiguration); approval.identity.assign(64, 'a'); approval.initialCheckpoint.assign(64, 'b');
    approval.nativeAuthorityIdentity.assign(64, 'c'); approval.primaryReview = fixture.provider;
    P::DeconfigurationAllowance allowance; allowance.installed = {"native-package", "0.9", "iphoneos-arm64"};
    allowance.selection = P::DpkgSelection::Hold; allowance.initialStatus = allowance.diskStatus = P::DpkgPackageStatus::Installed;
    allowance.installedControlIdentity.assign(64, 'd'); allowance.installedScriptsIdentity.assign(64, 'e');
    P::DeconfigurationCause cause; cause.unpackAction = 42; cause.archive = "independent-archive";
    cause.canonicalRelation = "native-package (<< 1.0)"; cause.comparedVersion = "0.9"; allowance.causes.push_back(cause);
    allowance.endpoint.action = 29; allowance.endpoint.precedingUnpack = 17; allowance.endpoint.package = {"native-package", "1.0", "iphoneos-arm64"};
    approval.allowances["native-package:iphoneos-arm64@0.9"] = allowance;
    auto &triggers(bundle->triggers); triggers.identity.assign(64, 'f'); triggers.initialCheckpoint = approval.initialCheckpoint;
    triggers.nativeAuthorityIdentity = approval.nativeAuthorityIdentity; triggers.primaryReview = fixture.provider;
    triggers.recipients = {{"native-package:iphoneos-arm64@1.0", {"native-package", "1.0", "iphoneos-arm64"}}};
    triggers.awaiters = triggers.recipients; triggers.incoming.insert("native-package:iphoneos-arm64@1.0");
    return bundle;
}
CydiaTransactionReview *ConditionalReview(const Fixture &fixture, const std::shared_ptr<P::EffectReviewBundle> &bundle,
    const P::TriggerEffectEnvelope *effects = nullptr) {
    return [[CydiaTransactionReview alloc] initWithTransaction:fixture.transaction providerReview:&fixture.provider
        runtimeOrigin:CydiaAPT::RuntimeDescriptorOrigin::External reviewedEffects:effects ? effects : &bundle->triggers reviewedDeconfiguration:bundle];
}
void ExactConditionalRowsAndImmutableIdentity() {
    Fixture fixture; auto bundle(ConditionalFixture(fixture)); CydiaTransactionReview *review(ConditionalReview(fixture, bundle));
    const auto identity(CydiaDeconfigurationReviewIdentity(*bundle));
    Require(review != nil && identity.size() == 64 && [review displayedDeconfigurationIdentity] == identity,
        "conditional display identity binds the entire canonical pair");
    Require(review.conditionalRows.count == 3 && [review displayedActions] == std::set<std::uint64_t>({17, 29, 42, 58}),
        "conditional recipients invent no primary action IDs");
    Row(review.conditionalRows, 0, @"native-package:iphoneos-arm64", @"0.9");
    Row(review.conditionalRows, 1, @"Unpack: independent-package:all", @"1.0\nnative-package (<< 1.0)");
    Row(review.conditionalRows, 2, @"Configure: native-package:iphoneos-arm64", @"1.0");
    Require(![review.conditionalRows isKindOfClass:[NSMutableArray class]], "conditional rows are copied immutable values");
    bundle->methodsIdentity = "methods:changed";
    Require(CydiaDeconfigurationReviewIdentity(*bundle) != identity && [review displayedDeconfigurationIdentity] == identity,
        "a later paired method change cannot rewrite what the controller displayed");
    bundle->deconfiguration.allowances.clear();
    Require(review.conditionalRows.count == 3 && [review displayedDeconfigurationIdentity] == identity,
        "later input pool mutation cannot rewrite approved rows or identity");
    Fixture invalid; auto other(ConditionalFixture(invalid)); auto copied(other->triggers);
    Require(ConditionalReview(invalid, other, &copied) == nil, "independently copied trigger pool cannot be joined into paired presentation");
    ++invalid.provider.binding.cacheEpoch;
    Require(ConditionalReview(invalid, other) == nil, "changed primary review cannot borrow paired presentation");
    invalid = Fixture(); other = ConditionalFixture(invalid); invalid.transaction.packages.at("native-package").displayName = "different display";
    Require(ConditionalReview(invalid, other) == nil, "different transaction presentation cannot borrow paired approval");
}
void ExistingRemovalEndpointsAndSiblingCause() {
    for (const auto kind : {P::ExecutionAction::Remove, P::ExecutionAction::Purge}) {
        Fixture fixture; auto bundle(ConditionalFixture(fixture));
        auto allowance(bundle->deconfiguration.allowances.begin()->second); allowance.installed = {"removed-package", "0.9", "iphoneos-arm64"};
        allowance.causes[0].canonicalRelation = "removed-package (<< 1.0)";
        allowance.endpoint.action = 99; allowance.endpoint.precedingUnpack = 0; allowance.endpoint.kind = kind; allowance.endpoint.package = allowance.installed;
        fixture.provider.execution.actions.push_back(Action(99, kind, "removed-package", "iphoneos-arm64", "0.9"));
        bundle->deconfiguration.allowances.clear(); bundle->deconfiguration.allowances["removed-package:iphoneos-arm64@0.9"] = allowance;
        bundle->deconfiguration.primaryReview = bundle->triggers.primaryReview = fixture.provider;
        CydiaTransactionReview *review(ConditionalReview(fixture, bundle)); Require(review != nil, "existing remove/purge endpoint is presentable");
        Row(review.conditionalRows, 2, kind == P::ExecutionAction::Remove ? @"Remove: removed-package:iphoneos-arm64" :
            @"Purge: removed-package:iphoneos-arm64", @"0.9");
        Require([review displayedActions].count(99) == 1 && [review displayedActions].size() == 5,
            "existing endpoint stays an existing primary action");
    }
    Fixture fixture; auto bundle(ConditionalFixture(fixture)); auto allowance(bundle->deconfiguration.allowances.begin()->second);
    allowance.installed.architecture = "iphoneos-arm"; allowance.causes[0].kind = P::DeconfigurationCauseKind::SiblingVersionMismatch;
    allowance.causes[0].unpackAction = 17; allowance.causes[0].archive = "native-archive"; allowance.causes[0].canonicalRelation.clear();
    allowance.endpoint.action = 99; allowance.endpoint.precedingUnpack = 0; allowance.endpoint.kind = P::ExecutionAction::Remove;
    allowance.endpoint.package = allowance.installed;
    fixture.provider.execution.actions.push_back(Action(99, P::ExecutionAction::Remove, "native-package", "iphoneos-arm", "0.9"));
    bundle->deconfiguration.allowances.clear(); bundle->deconfiguration.allowances["native-package:iphoneos-arm@0.9"] = allowance;
    bundle->deconfiguration.primaryReview = bundle->triggers.primaryReview = fixture.provider;
    CydiaTransactionReview *review(ConditionalReview(fixture, bundle)); Require(review != nil, "sibling cause is presentable without an invented relation");
    Row(review.conditionalRows, 0, @"native-package:iphoneos-arm", @"0.9");
    Row(review.conditionalRows, 1, @"Unpack: native-package:iphoneos-arm64", @"1.0 ↔ 0.9");
    Row(review.conditionalRows, 2, @"Remove: native-package:iphoneos-arm", @"0.9");
}
}

int main() {
    @autoreleasepool {
        ImmutableOwnedSnapshot(); ChangesInvalidateTheSnapshot(); ExactRowsAndSingleArchitecture();
        DistinctForeignArchitecture(); EveryKnownActionIsVisibleAndUnknownRejected(); EmbeddedRecoveryNotice();
        ImmutableProcessingPool(); RecoveryWorkerNotice();
        ExactConditionalRowsAndImmutableIdentity(); ExistingRemovalEndpointsAndSiblingCause();
        std::cout << "[transaction-review] PASS\n";
    }
}
