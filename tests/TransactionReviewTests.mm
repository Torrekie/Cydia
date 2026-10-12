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
        return [[CydiaTransactionReview alloc] initWithTransaction:transaction providerReview:&provider];
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
    CydiaTransactionReview *embedded([[CydiaTransactionReview alloc] initWithTransaction:fixture.transaction providerReview:nullptr]);
    Require(embedded != nil && [embedded matchesTransaction:fixture.transaction], "embedded transaction snapshot is missing");
    Text(embedded.runtimeNotice, CydiaRuntimeProviderLocalize(@"RECOVERY_REVIEW"), "embedded recovery notice is missing");
    Require(embedded.operations.count == 0 && embedded.archiveWarningRows.count == 0 &&
        [embedded displayedActions].empty() && [embedded displayedArchiveWarnings].empty(),
        "embedded review invented provider approval IDs");
}
}

int main() {
    @autoreleasepool {
        ImmutableOwnedSnapshot(); ChangesInvalidateTheSnapshot(); ExactRowsAndSingleArchitecture();
        DistinctForeignArchitecture(); EveryKnownActionIsVisibleAndUnknownRejected(); EmbeddedRecoveryNotice();
        std::cout << "[transaction-review] PASS\n";
    }
}
