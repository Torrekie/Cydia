/* Cydia Refurbished native confirmation model tests.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/ConfirmationViewModel.h"

#include <cstdlib>
#include <iostream>
#include <limits>

/* The production constructor lives in AptCompatibility.cpp, whose host build
   requires libapt-pkg. This focused Foundation test supplies the identical
   zero-value constructor without linking the embedded APT implementation. */
namespace CydiaAPT {
TransactionData::TransactionData() :
    downloading(0),
    resuming(0),
    removesEssential(false),
    substrate(false)
{
}
} // namespace CydiaAPT

namespace {

void Require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "[verify-confirmation-view-model][FAIL] " << message << std::endl;
        std::exit(1);
    }
}

void RequireString(NSString *actual, NSString *expected, const char *message) {
    Require(actual == expected || [actual isEqualToString:expected], message);
}

void TestGroupsIdentityAndOwnership() {
    CydiaAPT::TransactionData transaction;
    transaction.installs.push_back("native-package");
    transaction.installs.push_back("blank-name");
    transaction.reinstalls.push_back("same-package");
    transaction.upgrades.push_back("foreign-package:iphoneos-arm");
    transaction.downgrades.push_back("independent-package");
    transaction.removes.push_back("old-package");

    NSMutableString *foreignName([NSMutableString stringWithString:@"Foreign Runtime"]);
    __block NSUInteger resolverCalls(0);
    CydiaConfirmationPackageNameResolver resolver = ^NSString *(NSString *identity) {
        ++resolverCalls;
        if ([identity isEqualToString:@"native-package"])
            return @"Native Package";
        if ([identity isEqualToString:@"foreign-package:iphoneos-arm"])
            return foreignName;
        if ([identity isEqualToString:@"blank-name"])
            return @"";
        return nil;
    };

    CydiaConfirmationViewModel *model([[CydiaConfirmationViewModel alloc]
        initWithTransactionData:transaction
        advancedModeEnabled:NO
        packageNameResolver:resolver]);

    Require([[model groups] count] == 5, "non-empty change group count changed");
    const CydiaConfirmationChangeKind kinds[] = {
        CydiaConfirmationChangeKindInstall,
        CydiaConfirmationChangeKindReinstall,
        CydiaConfirmationChangeKindUpgrade,
        CydiaConfirmationChangeKindDowngrade,
        CydiaConfirmationChangeKindRemove,
    };
    NSArray *keys(@[@"INSTALL", @"REINSTALL", @"UPGRADE", @"DOWNGRADE", @"REMOVE"]);
    for (NSUInteger index(0); index != 5; ++index) {
        CydiaConfirmationChangeGroup *group([[model groups] objectAtIndex:index]);
        Require([group kind] == kinds[index], "change group order changed");
        RequireString([group titleLocalizationKey], [keys objectAtIndex:index],
                      "change group localization key changed");
        Require([model groupForKind:kinds[index]] == group, "group lookup lost identity");
    }

    CydiaConfirmationChangeGroup *installs([model groupForKind:CydiaConfirmationChangeKindInstall]);
    RequireString([[[installs packages] objectAtIndex:0] identity], @"native-package",
                  "native package route changed");
    RequireString([[[installs packages] objectAtIndex:0] displayName], @"Native Package",
                  "resolved package name changed");
    RequireString([[[installs packages] objectAtIndex:1] displayName], @"blank-name",
                  "empty resolver result did not fall back to identity");

    CydiaConfirmationPackageReference *foreign(
        [[[model groupForKind:CydiaConfirmationChangeKindUpgrade] packages] objectAtIndex:0]);
    RequireString([foreign identity], @"foreign-package:iphoneos-arm",
                  "foreign architecture qualifier was normalized away");
    RequireString([foreign displayName], @"Foreign Runtime", "mutable resolver value was not copied");
    RequireString([[[[model groupForKind:CydiaConfirmationChangeKindDowngrade] packages]
        objectAtIndex:0] identity], @"independent-package",
        "Architecture: all routing identity changed");

    transaction.installs[0] = "mutated-package";
    transaction.upgrades[0] = "mutated-foreign";
    [foreignName appendString:@" Mutated"];
    RequireString([[[installs packages] objectAtIndex:0] identity], @"native-package",
                  "model retained transaction storage");
    RequireString([foreign identity], @"foreign-package:iphoneos-arm",
                  "model retained qualified transaction storage");
    RequireString([foreign displayName], @"Foreign Runtime", "model retained resolver storage");
    Require(resolverCalls == 6, "resolver was not called exactly once per unique package identity");
    Require(![[model groups] isKindOfClass:[NSMutableArray class]], "groups remained mutable");
}

CydiaAPT::TransactionClauseData Clause(const char *package,
                                        const char *status,
                                        const char *comparison = "",
                                        const char *required = "",
                                        const char *planned = "") {
    CydiaAPT::TransactionClauseData clause;
    clause.package = package;
    clause.reason = status;
    clause.comparison = comparison;
    clause.version = required;
    clause.installed = planned;
    return clause;
}

void TestIssuesAndNullableValues() {
    CydiaAPT::TransactionData transaction;
    CydiaAPT::TransactionIssueData issue;
    issue.package = "consumer:iphoneos-arm";

    CydiaAPT::TransactionReasonData depends;
    depends.relationship = "Depends";
    depends.clauses.push_back(Clause("runtime:any", "installed", ">=", "2:1.0", "2:1.1"));
    depends.clauses.push_back(Clause("missing-package", "missing"));
    depends.clauses.push_back(Clause("available-package", "uninstalled"));
    depends.clauses.push_back(Clause("dead-package", "uninstallable"));
    depends.clauses.push_back(Clause("virtual-package", "virtual"));
    depends.clauses.push_back(Clause("future-package", "future-status"));
    issue.reasons.push_back(depends);
    transaction.issues.push_back(issue);

    CydiaAPT::TransactionIssueData specialRemoval;
    CydiaAPT::TransactionReasonData conflicts;
    conflicts.relationship = "Conflicts";
    conflicts.clauses.push_back(Clause("firmware", "installed"));
    specialRemoval.reasons.push_back(conflicts);
    transaction.issues.push_back(specialRemoval);

    CydiaConfirmationViewModel *model([[CydiaConfirmationViewModel alloc]
        initWithTransactionData:transaction
        advancedModeEnabled:NO
        packageNameResolver:nil]);
    Require([model hasBlockingIssues], "dependency issues were not blocking");
    Require(![model showsConfirmAction], "blocking issues exposed Confirm");
    Require([[model issues] count] == 2, "issue count changed");

    CydiaConfirmationIssue *nativeIssue([[model issues] objectAtIndex:0]);
    RequireString([[nativeIssue package] identity], @"consumer:iphoneos-arm",
                  "issue package architecture qualifier changed");
    CydiaConfirmationReason *reason([[nativeIssue reasons] objectAtIndex:0]);
    RequireString([reason relationship], @"Depends", "relationship changed");
    Require([[reason clauses] count] == 6, "OR clause order/count changed");

    const CydiaConfirmationClauseStatus statuses[] = {
        CydiaConfirmationClauseStatusInstalled,
        CydiaConfirmationClauseStatusMissing,
        CydiaConfirmationClauseStatusUninstalled,
        CydiaConfirmationClauseStatusUninstallable,
        CydiaConfirmationClauseStatusVirtual,
        CydiaConfirmationClauseStatusUnknown,
    };
    for (NSUInteger index(0); index != 6; ++index)
        Require([[[reason clauses] objectAtIndex:index] status] == statuses[index],
                "clause status mapping changed");

    CydiaConfirmationClause *planned([[reason clauses] objectAtIndex:0]);
    RequireString([[planned package] identity], @"runtime:any",
                  "dependency :any identity was normalized away");
    RequireString([planned comparisonOperator], @">=", "comparison operator changed");
    RequireString([planned requiredVersion], @"2:1.0", "required version changed");
    RequireString([planned plannedVersion], @"2:1.1", "planned version changed");

    CydiaConfirmationClause *missing([[reason clauses] objectAtIndex:1]);
    Require([missing comparisonOperator] == nil, "absent comparison became a web sentinel");
    Require([missing requiredVersion] == nil, "absent requirement became a web sentinel");
    Require([missing plannedVersion] == nil, "absent planned version became a web sentinel");
    CydiaConfirmationClause *future([[reason clauses] objectAtIndex:5]);
    RequireString([future rawStatusIdentifier], @"future-status",
                  "unknown status did not preserve its raw identifier");

    CydiaConfirmationIssue *special([[model issues] objectAtIndex:1]);
    Require([special package] == nil, "special-removal nil package became a web sentinel");
    RequireString([[[[special reasons] objectAtIndex:0] clauses][0].package identity],
                  @"firmware", "special-removal clause changed");

    transaction.issues[0].package = "mutated-consumer";
    transaction.issues[0].reasons[0].clauses[0].package = "mutated-runtime";
    RequireString([[nativeIssue package] identity], @"consumer:iphoneos-arm",
                  "issue retained transaction package storage");
    RequireString([[planned package] identity], @"runtime:any",
                  "clause retained transaction package storage");
}

void TestSizesAndPolicies() {
    CydiaAPT::TransactionData empty;
    CydiaConfirmationViewModel *emptyModel([[CydiaConfirmationViewModel alloc]
        initWithTransactionData:empty
        advancedModeEnabled:NO
        packageNameResolver:nil]);
    Require(![emptyModel hasChanges], "empty transaction contains changes");
    Require(![emptyModel hasBlockingIssues], "empty transaction contains issues");
    Require([emptyModel showsConfirmAction], "legacy empty transaction lost Confirm");
    Require([[emptyModel groups] count] == 0, "empty transaction exposed empty sections");
    Require([emptyModel essentialRemovalPolicy] == CydiaConfirmationEssentialRemovalPolicyNone,
            "empty transaction has an essential policy");

    CydiaAPT::TransactionData dangerous;
    dangerous.downloading = std::numeric_limits<uint64_t>::max();
    dangerous.resuming = std::numeric_limits<uint64_t>::max() - 1;
    dangerous.removesEssential = true;
    dangerous.substrate = true;
    CydiaConfirmationViewModel *blocked([[CydiaConfirmationViewModel alloc]
        initWithTransactionData:dangerous
        advancedModeEnabled:NO
        packageNameResolver:nil]);
    Require([blocked downloadingBytes] == std::numeric_limits<uint64_t>::max(),
            "download byte count was narrowed or derived");
    Require([blocked resumingBytes] == std::numeric_limits<uint64_t>::max() - 1,
            "resume byte count was narrowed or derived");
    Require([blocked essentialRemovalPolicy] == CydiaConfirmationEssentialRemovalPolicyBlocked,
            "non-Advanced essential removal was not blocked");
    Require([blocked requiresSubstrateRestart], "substrate restart flag was lost");
    Require([blocked showsConfirmAction], "essential policy incorrectly hid Confirm");

    CydiaConfirmationViewModel *forceAllowed([[CydiaConfirmationViewModel alloc]
        initWithTransactionData:dangerous
        advancedModeEnabled:YES
        packageNameResolver:nil]);
    Require([forceAllowed essentialRemovalPolicy] == CydiaConfirmationEssentialRemovalPolicyForceAllowed,
            "Advanced essential removal did not require force confirmation");
}

} // namespace

int main() {
    @autoreleasepool {
        TestGroupsIdentityAndOwnership();
        TestIssuesAndNullableValues();
        TestSizesAndPolicies();
    }
    std::cout << "[verify-confirmation-view-model][ ok ] typed transaction snapshot" << std::endl;
    return 0;
}
