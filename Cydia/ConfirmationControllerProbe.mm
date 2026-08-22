/* Cydia Refurbished native confirmation simulator probe.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ConfirmationControllerProbe.h"

#if TARGET_OS_SIMULATOR

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/ConfirmationController.h"
#include "Cydia/ConfirmationViewModel.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"

#include <cmath>

@interface ConfirmationController (CydiaConfirmationProbe)
- (void) cancelButtonClicked;
- (void) continueQueuingButtonClicked;
- (void) confirmButtonClicked;
- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView;
- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section;
- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section;
- (UITableViewCell *) tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath;
- (void) tableView:(UITableView *)tableView
    willDisplayHeaderView:(UIView *)view
               forSection:(NSInteger)section;
- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
@end

@interface CydiaConfirmationProbeDelegate : NSObject <ConfirmationControllerDelegate>
@property(nonatomic, copy) NSString *lastAction;
@end

@implementation CydiaConfirmationProbeDelegate
- (void) cancelAndClear:(bool)clear {
    self.lastAction = clear ? @"cancel-clear" : @"continue-queuing";
}
- (void) confirmWithNavigationController:(UINavigationController *)navigation {
    (void) navigation;
    self.lastAction = @"confirm";
}
- (void) queue {}
@end

static UIView *ConfirmationProbeView(UIView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqualToString:identifier])
        return root;
    for (UIView *child in root.subviews) {
        UIView *match(ConfirmationProbeView(child, identifier));
        if (match != nil)
            return match;
    }
    return nil;
}

static NSInteger ConfirmationProbeLuminance(UIColor *color) {
    CGFloat red(0), green(0), blue(0), alpha(0), white(0);
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha] &&
        [color getWhite:&white alpha:&alpha])
        red = green = blue = white;
    return (NSInteger) lround(((red + green + blue) / 3.0) * 1000.0);
}

static NSUInteger ConfirmationProbeEmbeddedBrowserCount(UIView *root) {
    NSUInteger count(0);
    NSString *browserClassToken([@"Web" stringByAppendingString:@"View"]);
    if ([NSStringFromClass([root class]) rangeOfString:browserClassToken].location != NSNotFound)
        ++count;
    for (UIView *child in root.subviews)
        count += ConfirmationProbeEmbeddedBrowserCount(child);
    return count;
}

static NSString *ConfirmationProbeSectionKindName(CydiaConfirmationTableSectionKind kind) {
    switch (kind) {
        case CydiaConfirmationTableSectionKindIssueNotice: return @"issue-notice";
        case CydiaConfirmationTableSectionKindQueue: return @"queue";
        case CydiaConfirmationTableSectionKindSizes: return @"statistics";
        case CydiaConfirmationTableSectionKindModifications: return @"modifications";
        case CydiaConfirmationTableSectionKindIssueDetails: return @"issue-details";
    }
    return @"unknown";
}

static CydiaConfirmationViewModel *ConfirmationProbeModel(NSString *phase) {
    CydiaAPT::TransactionData transaction;
    transaction.installs.push_back("runtime-native");
    transaction.reinstalls.push_back("same-package");
    transaction.upgrades.push_back("foreign-package:iphoneos-arm");
    transaction.downgrades.push_back("independent-package");
    transaction.removes.push_back("old-package");
    transaction.downloading = 4096;
    transaction.resuming = 1024;
    transaction.substrate = true;

    if ([phase isEqualToString:@"issues"]) {
        CydiaAPT::TransactionIssueData issue;
        issue.package = "consumer:iphoneos-arm64";
        CydiaAPT::TransactionReasonData reason;
        reason.relationship = "Depends";
        CydiaAPT::TransactionClauseData clause;
        clause.package = "runtime:any";
        clause.reason = "missing";
        clause.comparison = ">=";
        clause.version = "2:1.0";
        reason.clauses.push_back(clause);
        issue.reasons.push_back(reason);
        transaction.issues.push_back(issue);
    }
    if ([phase hasPrefix:@"essential"])
        transaction.removesEssential = true;

    BOOL advanced = [phase isEqualToString:@"essential-force"];
    return [[CydiaConfirmationViewModel alloc]
        initWithTransactionData:transaction
        advancedModeEnabled:advanced
        packageNameResolver:^NSString *(NSString *identity) {
            if ([identity isEqualToString:@"runtime-native"])
                return @"Runtime Native";
            if ([identity isEqualToString:@"foreign-package:iphoneos-arm"])
                return @"Foreign Runtime";
            if ([identity isEqualToString:@"consumer:iphoneos-arm64"])
                return @"Consumer";
            return nil;
        }];
}

@interface CydiaConfirmationProbeHostController : UIViewController
@end

@implementation CydiaConfirmationProbeHostController {
    ConfirmationController *controller_;
    UINavigationController *navigation_;
    CydiaConfirmationProbeDelegate *delegate_;
    NSString *phase_;
    BOOL dark_;
    BOOL accessibilityLarge_;
    NSUInteger settleTicks_;
    NSString *lastInteraction_;
}

- (NSString *) markerPath:(NSString *)name {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

- (BOOL) consumeMarker:(NSString *)name {
    NSString *path([self markerPath:name]);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return NO;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return YES;
}

- (void) applyTraits {
    UITraitCollection *style([UITraitCollection traitCollectionWithUserInterfaceStyle:
        dark_ ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight]);
    UITraitCollection *size([UITraitCollection
        traitCollectionWithPreferredContentSizeCategory:accessibilityLarge_ ?
            UIContentSizeCategoryAccessibilityLarge : UIContentSizeCategoryLarge]);
    [self setOverrideTraitCollection:[UITraitCollection
        traitCollectionWithTraitsFromCollections:@[style, size]]
        forChildViewController:navigation_];
    [navigation_.view setNeedsLayout];
    [navigation_.view layoutIfNeeded];
}

- (void) installPhase:(NSString *)phase {
    if (controller_.presentedViewController != nil)
        [controller_ dismissViewControllerAnimated:NO completion:nil];
    phase_ = [phase copy];
    accessibilityLarge_ = [phase isEqualToString:@"normal-accessibility"];
    lastInteraction_ = @"";
    delegate_ = [[CydiaConfirmationProbeDelegate alloc] init];
    controller_ = [[ConfirmationController alloc]
        initWithViewModel:ConfirmationProbeModel(phase_) delegate:delegate_];
    if (navigation_ == nil) {
        navigation_ = [[UINavigationController alloc] initWithRootViewController:controller_];
        [self addChildViewController:navigation_];
        navigation_.view.frame = self.view.bounds;
        navigation_.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                             UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:navigation_.view];
        [navigation_ didMoveToParentViewController:self];
    } else {
        [navigation_ setViewControllers:@[controller_] animated:NO];
    }
    [self applyTraits];
    [navigation_.view layoutIfNeeded];
    settleTicks_ = 5;
}

- (void) selectContinueQueuingRow {
    UITableView *table((UITableView *) ConfirmationProbeView(controller_.view,
        @"cydia.confirmation.table"));
    NSArray<CydiaConfirmationTableSection *> *sections([controller_ valueForKey:@"sections"]);
    for (NSUInteger section = 0; section < [sections count]; ++section) {
        if ([[sections objectAtIndex:section] kind] != CydiaConfirmationTableSectionKindQueue)
            continue;
        lastInteraction_ = @"queue-selection";
        [controller_ tableView:table didSelectRowAtIndexPath:
            [NSIndexPath indexPathForRow:0 inSection:section]];
        return;
    }
}

- (void) loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    [self installPhase:@"normal"];
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(probeTimerFired:) userInfo:nil repeats:YES];
}

- (void) probeTimerFired:(NSTimer *)timer {
    (void) timer;
    if ([self consumeMarker:@"cydia-confirmation-probe-dark"]) {
        dark_ = YES;
        [self applyTraits];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-confirmation-probe-light"]) {
        dark_ = NO;
        [self applyTraits];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-confirmation-probe-accessibility"]) {
        accessibilityLarge_ = YES;
        [self installPhase:@"normal-accessibility"];
    }
    for (NSString *phase in @[@"normal", @"normal-confirm", @"normal-continue", @"normal-cancel",
                               @"issues", @"essential-blocked", @"essential-force"]) {
        if ([self consumeMarker:[NSString stringWithFormat:@"cydia-confirmation-probe-%@", phase]]) {
            [self installPhase:phase];
            break;
        }
    }
    if ([self consumeMarker:@"cydia-confirmation-probe-confirm"])
        [controller_ confirmButtonClicked];
    if ([self consumeMarker:@"cydia-confirmation-probe-continue"])
        [self selectContinueQueuingRow];
    if ([self consumeMarker:@"cydia-confirmation-probe-cancel"])
        [controller_ cancelButtonClicked];
    if (settleTicks_ != 0)
        --settleTicks_;
    [self writeState];
}

- (void) writeState {
    [navigation_.view layoutIfNeeded];
    UITableView *table((UITableView *) ConfirmationProbeView(controller_.view,
        @"cydia.confirmation.table"));
    NSUInteger sections(table.numberOfSections);
    NSMutableArray *headers([NSMutableArray array]);
    NSMutableArray *identifiers([NSMutableArray array]);
    NSMutableArray *values([NSMutableArray array]);
    NSMutableArray *cellTitles([NSMutableArray array]);
    NSMutableArray *cellDetails([NSMutableArray array]);
    NSMutableArray *sectionKinds([NSMutableArray array]);
    NSString *continueTitle(@"");
    NSString *issueHeaderAccessibilityIdentity(@"");
    NSString *installTitle(@"");
    NSString *installDetail(@"");
    NSString *downloadingDetail(@"");
    NSString *resumingDetail(@"");
    NSString *issueRelationship(@"");
    NSString *issueDetail(@"");
    NSUInteger modificationRowCount(0);
    NSUInteger queueAccessory(UITableViewCellAccessoryNone);
    NSArray<CydiaConfirmationTableSection *> *plannedSections(
        [controller_ valueForKey:@"sections"]);
    for (NSUInteger section = 0; section < sections; ++section) {
        [sectionKinds addObject:ConfirmationProbeSectionKindName(
            [[plannedSections objectAtIndex:section] kind])];
        NSString *header([controller_ tableView:table titleForHeaderInSection:section]);
        if (header != nil) {
            [headers addObject:header];
            UITableViewHeaderFooterView *headerView(
                [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:nil]);
            [[headerView textLabel] setText:header];
            [controller_ tableView:table willDisplayHeaderView:headerView forSection:section];
            if ([[headerView accessibilityValue] length] != 0)
                issueHeaderAccessibilityIdentity = [headerView accessibilityValue];
        }
        for (NSUInteger row = 0; row < [table numberOfRowsInSection:section]; ++row) {
            NSIndexPath *path([NSIndexPath indexPathForRow:row inSection:section]);
            UITableViewCell *cell([table cellForRowAtIndexPath:path]);
            if (cell == nil)
                cell = [controller_ tableView:table cellForRowAtIndexPath:path];
            if (cell.accessibilityIdentifier != nil)
                [identifiers addObject:cell.accessibilityIdentifier];
            if (cell.accessibilityValue != nil)
                [values addObject:cell.accessibilityValue];
            UILabel *title([cell valueForKey:@"confirmationTitleLabel"]);
            UILabel *detail([cell valueForKey:@"confirmationDetailLabel"]);
            [cellTitles addObject:[title text] ?: @""];
            [cellDetails addObject:[detail text] ?: @""];
            NSString *identifier([cell accessibilityIdentifier]);
            if ([cell.accessibilityIdentifier
                    isEqualToString:@"cydia.confirmation.continue-queuing"]) {
                continueTitle = cell.accessibilityLabel ?: @"";
                queueAccessory = [cell accessoryType];
            }
            if ([identifier hasPrefix:@"cydia.confirmation.modifications."]) {
                ++modificationRowCount;
                if ([identifier isEqualToString:@"cydia.confirmation.modifications.0"]) {
                    installTitle = [title text] ?: @"";
                    installDetail = [detail text] ?: @"";
                }
            } else if ([identifier isEqualToString:@"cydia.confirmation.sizes.downloading"])
                downloadingDetail = [detail text] ?: @"";
            else if ([identifier isEqualToString:@"cydia.confirmation.sizes.resuming"])
                resumingDetail = [detail text] ?: @"";
            else if ([identifier hasPrefix:@"cydia.confirmation.issue."]) {
                issueRelationship = [title text] ?: @"";
                issueDetail = [detail text] ?: @"";
            }
        }
    }
    UIView *root(controller_.view);
    UIAlertController *alert([controller_ valueForKey:@"essentialAlert"]);
    BOOL hasCannotComplyHeader([[controller_.navigationItem title]
        isEqualToString:UCLocalize("CANNOT_COMPLY")]);
    BOOL hasQualifiedCell(NO);
    for (NSString *value in values)
        if ([value rangeOfString:@"foreign-package:iphoneos-arm"].location != NSNotFound)
            hasQualifiedCell = YES;
    BOOL visibleRowsFit(YES);
    for (UITableViewCell *cell in table.visibleCells) {
        UILabel *title([cell valueForKey:@"confirmationTitleLabel"]);
        UILabel *detail([cell valueForKey:@"confirmationDetailLabel"]);
        if (title == nil || detail == nil) {
            visibleRowsFit = NO;
            break;
        }
        CGRect titleFrame([title convertRect:title.bounds toView:cell.contentView]);
        CGRect labels(titleFrame);
        if (!detail.hidden) {
            CGRect detailFrame([detail convertRect:detail.bounds toView:cell.contentView]);
            labels = CGRectUnion(labels, detailFrame);
        }
        if (CGRectGetMinY(labels) < -1.0 ||
            CGRectGetMaxY(labels) > CGRectGetHeight(cell.contentView.bounds) + 1.0) {
            visibleRowsFit = NO;
            break;
        }
    }
    NSDictionary *state = @{
        @"ready": @(settleTicks_ == 0 && table != nil && sections != 0),
        @"phase": phase_ ?: @"",
        @"style": dark_ ? @"dark" : @"light",
        @"sections": @(sections),
        @"sectionKinds": sectionKinds,
        @"headers": headers,
        @"cellIdentifiers": identifiers,
        @"cellValues": values,
        @"cellTitles": cellTitles,
        @"cellDetails": cellDetails,
        @"hasCannotComplyHeader": @(hasCannotComplyHeader),
        @"hasQualifiedCell": @(hasQualifiedCell),
        @"issueHeaderAccessibilityIdentity": issueHeaderAccessibilityIdentity,
        @"visibleRowsFit": @(visibleRowsFit),
        @"hasConfirm": @(controller_.navigationItem.rightBarButtonItem != nil),
        @"hasCancel": @(controller_.navigationItem.leftBarButtonItem != nil),
        @"continueTitle": continueTitle,
        @"expectedContinueTitle": UCLocalize("CONTINUE_QUEUING"),
        @"queueAccessory": @(queueAccessory),
        @"lastAction": delegate_.lastAction ?: @"",
        @"lastInteraction": lastInteraction_ ?: @"",
        @"modificationRowCount": @(modificationRowCount),
        @"installTitle": installTitle,
        @"expectedInstallTitle": UCLocalize("INSTALL"),
        @"installDetail": installDetail,
        @"downloadingDetail": downloadingDetail,
        @"resumingDetail": resumingDetail,
        @"issueRelationship": issueRelationship,
        @"issueDetail": issueDetail,
        @"alertVisible": @(alert != nil),
        @"alertTitle": alert.title ?: @"",
        @"alertActionCount": @(alert.actions.count),
        @"backgroundLuminance": @(ConfirmationProbeLuminance(root.backgroundColor)),
        @"contentSizeCategory": controller_.traitCollection.preferredContentSizeCategory ?: @"",
        @"expectedDefaultContentSizeCategory": UIContentSizeCategoryLarge,
        @"expectedAccessibilityContentSizeCategory": UIContentSizeCategoryAccessibilityLarge,
        @"visibleWebViews": @(ConfirmationProbeEmbeddedBrowserCount(root)),
        @"navigationBarHidden": @(navigation_.navigationBar.hidden),
        @"navigationBarFrame": NSStringFromCGRect(navigation_.navigationBar.frame),
    };
    [state writeToFile:[self markerPath:@"cydia-confirmation-probe.plist"] atomically:YES];
}

@end

UIViewController *CydiaConfirmationControllerProbeRootController(void) {
    return [[CydiaConfirmationProbeHostController alloc] init];
}

#endif
