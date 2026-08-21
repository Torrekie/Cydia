/* Cydia Refurbished native confirmation controller contract tests.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/ConfirmationViewModel.h"

#include <cstdlib>
#include <iostream>

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
        std::cerr << "[verify-confirmation-controller][FAIL] " << message << std::endl;
        std::exit(1);
    }
}

void RequireEffect(CydiaConfirmationActionState *state,
                   CydiaConfirmationUserAction action,
                   CydiaConfirmationActionEffect expected,
                   const char *message) {
    Require([state effectForUserAction:action] == expected, message);
}

void TestOneShotActionOutcomes() {
    CydiaConfirmationActionState *cancel([[CydiaConfirmationActionState alloc]
        initWithBlockingIssues:NO
        essentialRemovalPolicy:CydiaConfirmationEssentialRemovalPolicyNone]);
    RequireEffect(cancel, CydiaConfirmationUserActionCancel,
                  CydiaConfirmationActionEffectCancelAndClear,
                  "Cancel did not clear the queue");
    Require([cancel isTerminal], "Cancel was not terminal");
    RequireEffect(cancel, CydiaConfirmationUserActionCancel,
                  CydiaConfirmationActionEffectNone,
                  "Cancel dispatched more than once");

    CydiaConfirmationActionState *keep([[CydiaConfirmationActionState alloc]
        initWithBlockingIssues:NO
        essentialRemovalPolicy:CydiaConfirmationEssentialRemovalPolicyNone]);
    RequireEffect(keep, CydiaConfirmationUserActionContinueQueuing,
                  CydiaConfirmationActionEffectContinueQueuing,
                  "Continue Queuing cleared or confirmed the queue");
    RequireEffect(keep, CydiaConfirmationUserActionConfirm,
                  CydiaConfirmationActionEffectNone,
                  "Continue Queuing allowed a second terminal action");

    CydiaConfirmationActionState *confirm([[CydiaConfirmationActionState alloc]
        initWithBlockingIssues:NO
        essentialRemovalPolicy:CydiaConfirmationEssentialRemovalPolicyNone]);
    RequireEffect(confirm, CydiaConfirmationUserActionConfirm,
                  CydiaConfirmationActionEffectConfirm,
                  "normal Confirm did not dispatch");
    RequireEffect(confirm, CydiaConfirmationUserActionConfirm,
                  CydiaConfirmationActionEffectNone,
                  "normal Confirm dispatched more than once");

    CydiaConfirmationActionState *issues([[CydiaConfirmationActionState alloc]
        initWithBlockingIssues:YES
        essentialRemovalPolicy:CydiaConfirmationEssentialRemovalPolicyNone]);
    RequireEffect(issues, CydiaConfirmationUserActionConfirm,
                  CydiaConfirmationActionEffectNone,
                  "blocking issues allowed Confirm");
    Require(![issues isTerminal], "rejected Confirm made the issue screen terminal");
    RequireEffect(issues, CydiaConfirmationUserActionCancel,
                  CydiaConfirmationActionEffectCancelAndClear,
                  "issue screen could not be cancelled and cleared");
}

void TestEssentialRemovalOutcomes() {
    CydiaConfirmationActionState *blocked([[CydiaConfirmationActionState alloc]
        initWithBlockingIssues:NO
        essentialRemovalPolicy:CydiaConfirmationEssentialRemovalPolicyBlocked]);
    RequireEffect(blocked, CydiaConfirmationUserActionConfirm,
                  CydiaConfirmationActionEffectPresentBlockedEssentialAlert,
                  "blocked essential removal did not present its warning");
    RequireEffect(blocked, CydiaConfirmationUserActionConfirm,
                  CydiaConfirmationActionEffectNone,
                  "blocked warning was presented twice");
    RequireEffect(blocked, CydiaConfirmationUserActionBlockedEssentialAcknowledged,
                  CydiaConfirmationActionEffectDismissWithoutDelegate,
                  "blocked warning acknowledgement touched the queue delegate");
    Require([blocked isTerminal], "blocked warning acknowledgement was not terminal");
    RequireEffect(blocked, CydiaConfirmationUserActionContinueQueuing,
                  CydiaConfirmationActionEffectNone,
                  "blocked acknowledgement dispatched a later delegate outcome");

    CydiaConfirmationActionState *forceCancel([[CydiaConfirmationActionState alloc]
        initWithBlockingIssues:NO
        essentialRemovalPolicy:CydiaConfirmationEssentialRemovalPolicyForceAllowed]);
    RequireEffect(forceCancel, CydiaConfirmationUserActionConfirm,
                  CydiaConfirmationActionEffectPresentForceRemovalAlert,
                  "force-removal warning was not presented");
    RequireEffect(forceCancel, CydiaConfirmationUserActionForceRemovalCancelled,
                  CydiaConfirmationActionEffectContinueQueuing,
                  "force-removal Cancel did not retain the queue");
    RequireEffect(forceCancel, CydiaConfirmationUserActionForceRemovalConfirmed,
                  CydiaConfirmationActionEffectNone,
                  "force-removal Cancel allowed a later Confirm");

    CydiaConfirmationActionState *forceConfirm([[CydiaConfirmationActionState alloc]
        initWithBlockingIssues:NO
        essentialRemovalPolicy:CydiaConfirmationEssentialRemovalPolicyForceAllowed]);
    RequireEffect(forceConfirm, CydiaConfirmationUserActionConfirm,
                  CydiaConfirmationActionEffectPresentForceRemovalAlert,
                  "force confirmation skipped its warning");
    RequireEffect(forceConfirm, CydiaConfirmationUserActionForceRemovalConfirmed,
                  CydiaConfirmationActionEffectConfirm,
                  "force-removal action did not confirm");
    RequireEffect(forceConfirm, CydiaConfirmationUserActionForceRemovalConfirmed,
                  CydiaConfirmationActionEffectNone,
                  "force-removal action confirmed more than once");
}

void TestTableSectionPlan() {
    CydiaAPT::TransactionData transaction;
    transaction.installs.push_back("native-package");
    transaction.installs.push_back("independent-package");
    transaction.upgrades.push_back("foreign-package:iphoneos-arm");
    transaction.downloading = 4096;
    transaction.resuming = 1024;

    CydiaAPT::TransactionIssueData issue;
    issue.package = "consumer";
    CydiaAPT::TransactionReasonData reason;
    reason.relationship = "Depends";
    CydiaAPT::TransactionClauseData clause;
    clause.package = "runtime:any";
    clause.reason = "missing";
    reason.clauses.push_back(clause);
    issue.reasons.push_back(reason);
    transaction.issues.push_back(issue);

    CydiaConfirmationViewModel *model([[CydiaConfirmationViewModel alloc]
        initWithTransactionData:transaction
        advancedModeEnabled:NO
        packageNameResolver:nil]);
    NSArray<CydiaConfirmationTableSection *> *sections(
        CydiaConfirmationBuildTableSections(model));
    Require([sections count] == 3, "issue table section count changed");
    Require([[sections objectAtIndex:0] kind] == CydiaConfirmationTableSectionKindIssue,
            "dependency issue was not first");
    Require([[sections objectAtIndex:0] issue] == [[model issues] objectAtIndex:0],
            "issue section lost its typed issue");
    Require([[sections objectAtIndex:0] rowCount] == 1, "issue section row count changed");

    CydiaConfirmationTableSection *installs([sections objectAtIndex:1]);
    Require([installs kind] == CydiaConfirmationTableSectionKindChanges,
            "install group did not become a change section");
    Require([[installs changeGroup] kind] == CydiaConfirmationChangeKindInstall,
            "install group order changed");
    Require([installs rowCount] == 2, "install package row count changed");

    CydiaConfirmationTableSection *upgrades([sections objectAtIndex:2]);
    Require([[upgrades changeGroup] kind] == CydiaConfirmationChangeKindUpgrade,
            "upgrade group order changed");
    Require([upgrades rowCount] == 1, "upgrade package row count changed");
    Require([[[[[upgrades changeGroup] packages] objectAtIndex:0] identity]
                isEqualToString:@"foreign-package:iphoneos-arm"],
            "table plan normalized a foreign package identity");

    for (CydiaConfirmationTableSection *section in sections)
        Require([section kind] != CydiaConfirmationTableSectionKindSizes,
                "blocking issue retained legacy-hidden statistics");
    Require(![sections isKindOfClass:[NSMutableArray class]], "table plan remained mutable");

    CydiaAPT::TransactionData normal;
    normal.installs.push_back("native-package");
    normal.upgrades.push_back("foreign-package:iphoneos-arm");
    normal.downloading = 4096;
    normal.resuming = 1024;
    CydiaConfirmationViewModel *normalModel([[CydiaConfirmationViewModel alloc]
        initWithTransactionData:normal
        advancedModeEnabled:NO
        packageNameResolver:nil]);
    NSArray<CydiaConfirmationTableSection *> *normalSections(
        CydiaConfirmationBuildTableSections(normalModel));
    Require([normalSections count] == 3, "normal table section count changed");
    Require([[normalSections objectAtIndex:0] kind] == CydiaConfirmationTableSectionKindSizes,
            "statistics did not precede modification groups");
    Require([[normalSections objectAtIndex:0] rowCount] == 2,
            "download and resume did not retain separate rows");
    Require([[[normalSections objectAtIndex:1] changeGroup] kind] ==
                CydiaConfirmationChangeKindInstall,
            "install group did not follow statistics");
    Require([[[normalSections objectAtIndex:2] changeGroup] kind] ==
                CydiaConfirmationChangeKindUpgrade,
            "upgrade group order changed after statistics");
}

} // namespace

int main() {
    @autoreleasepool {
        TestOneShotActionOutcomes();
        TestEssentialRemovalOutcomes();
        TestTableSectionPlan();
    }
    std::cout << "[verify-confirmation-controller][ ok ] action and table contracts" << std::endl;
    return 0;
}
