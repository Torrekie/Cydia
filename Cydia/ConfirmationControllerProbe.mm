/* Cydia Refurbished native confirmation simulator probe.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ConfirmationControllerProbe.h"

#if TARGET_OS_SIMULATOR

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/ConfirmationController.h"
#include "Cydia/ConfirmationViewModel.h"
#include "Cydia/Database.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"

#include <cmath>
#include <objc/runtime.h>
#include <unistd.h>

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

@interface CydiaConfirmationProbeController : ConfirmationController
- (NSDictionary *) legacyChangesForProbe;
- (BOOL) legacySubstrateForProbe;
- (void) setLegacySubstrateForProbe:(BOOL)substrate;
@end

@implementation CydiaConfirmationProbeController
- (NSDictionary *) legacyChangesForProbe {
    return changes_;
}
- (BOOL) legacySubstrateForProbe {
    return substrate_;
}
- (void) setLegacySubstrateForProbe:(BOOL)substrate {
    substrate_ = substrate;
}
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

static BOOL ConfirmationProbeColorsEqual(UIColor *left, UIColor *right) {
    if (left == nil || right == nil)
        return left == right;
    CGFloat lr(0), lg(0), lb(0), la(0), rr(0), rg(0), rb(0), ra(0);
    if ([left getRed:&lr green:&lg blue:&lb alpha:&la] &&
        [right getRed:&rr green:&rg blue:&rb alpha:&ra])
        return fabs(lr - rr) < 0.01 && fabs(lg - rg) < 0.01 &&
               fabs(lb - rb) < 0.01 && fabs(la - ra) < 0.01;
    CGFloat lw(0), rw(0);
    if ([left getWhite:&lw alpha:&la] && [right getWhite:&rw alpha:&ra])
        return fabs(lw - rw) < 0.01 && fabs(la - ra) < 0.01;
    return [left isEqual:right];
}

static UIColor *ConfirmationProbeResolvedColor(UIColor *color,
                                                UITraitCollection *traits) {
    if (color == nil)
        return nil;
    if (@available(iOS 13.0, *)) {
        if ([color respondsToSelector:@selector(resolvedColorWithTraitCollection:)])
            return [color resolvedColorWithTraitCollection:traits];
    }
    return color;
}

static NSString *ConfirmationProbePresentationStyleName(UIModalPresentationStyle style) {
    switch (style) {
        case UIModalPresentationFullScreen: return @"fullScreen";
        case UIModalPresentationFormSheet: return @"formSheet";
        case UIModalPresentationNone: return @"none";
        default: return @"other";
    }
}

static NSString *ConfirmationProbeSizeClassName(UIUserInterfaceSizeClass sizeClass) {
    switch (sizeClass) {
        case UIUserInterfaceSizeClassCompact: return @"compact";
        case UIUserInterfaceSizeClassRegular: return @"regular";
        case UIUserInterfaceSizeClassUnspecified: return @"unspecified";
    }
    return @"unknown";
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

static NSString *ConfirmationProbeApplicationStateName(UIApplicationState state) {
    switch (state) {
        case UIApplicationStateActive: return @"active";
        case UIApplicationStateInactive: return @"inactive";
        case UIApplicationStateBackground: return @"background";
    }
    return @"unknown";
}

static CydiaConfirmationViewModel *ConfirmationProbeModel(NSString *phase) {
    CydiaAPT::TransactionData transaction;
    /* Keep the empty phase genuinely zeroed so the probe can distinguish the
     * legacy Queue/Modifications shell from a sparse removal. */
    if ([phase isEqualToString:@"legacy-sparse"]) {
        transaction.removes.push_back("old-package");
    } else if (![phase isEqualToString:@"empty"]) {
        transaction.installs.push_back("runtime-native");
        transaction.reinstalls.push_back("same-package");
        transaction.upgrades.push_back("foreign-package:iphoneos-arm");
        transaction.downgrades.push_back("independent-package");
        transaction.removes.push_back("old-package");
        transaction.downloading = 4096;
        transaction.resuming = 1024;
        transaction.substrate = true;
    }

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
    CydiaConfirmationViewModel *viewModel_;
    ConfirmationController *controller_;
    UINavigationController *navigation_;
    CydiaConfirmationProbeDelegate *delegate_;
    NSString *phase_;
    BOOL dark_;
    BOOL accessibilityLarge_;
    BOOL formSheet_;
    BOOL formSheetPresentationComplete_;
    NSUInteger settleTicks_;
    NSString *lastInteraction_;
    NSMutableArray<NSString *> *lifecycleNotifications_;
    NSString *controllerToken_;
    NSString *modelToken_;
    BOOL lifecycleArmed_;
    BOOL lifecycleComplete_;
}

- (UIStatusBarStyle) preferredStatusBarStyle {
    return dark_ ? UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    UITraitCollection *traits([UITraitCollection
        traitCollectionWithTraitsFromCollections:@[style, size]]);
    if (formSheet_) {
        if (navigation_.presentationController != nil)
            navigation_.presentationController.overrideTraitCollection = traits;
    } else {
        [self setOverrideTraitCollection:traits forChildViewController:navigation_];
    }
    self.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                           traitCollection:traits];
    self.view.opaque = YES;
    [navigation_.view setNeedsLayout];
    [navigation_.view layoutIfNeeded];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void) detachNavigation {
    if (navigation_ == nil)
        return;
    if (navigation_.presentingViewController != nil) {
        [self dismissViewControllerAnimated:NO completion:nil];
    } else if (navigation_.parentViewController == self) {
        [navigation_ willMoveToParentViewController:nil];
        [navigation_.view removeFromSuperview];
        [navigation_ removeFromParentViewController];
    }
    navigation_ = nil;
    formSheetPresentationComplete_ = NO;
}

- (void) installPhase:(NSString *)phase {
    if (controller_.presentedViewController != nil)
        [controller_ dismissViewControllerAnimated:NO completion:nil];
    // Cancel and Continue Queuing dismiss the real sheet. A later fixture
    // needs a new presentation, not a stack update on the detached navigator.
    if (formSheet_ && navigation_ != nil &&
        navigation_.presentingViewController == nil)
        [self detachNavigation];
    phase_ = [phase copy];
    accessibilityLarge_ = [phase isEqualToString:@"normal-accessibility"];
    lastInteraction_ = @"";
    delegate_ = [[CydiaConfirmationProbeDelegate alloc] init];
    viewModel_ = ConfirmationProbeModel(phase_);
    modelToken_ = [[NSUUID UUID] UUIDString];
    RestartSubstrate_ = false;
    controller_ = [[CydiaConfirmationProbeController alloc]
        initWithViewModel:viewModel_ delegate:delegate_];
    if ([phase isEqualToString:@"normal-confirm-substrate-cleared"])
        [(CydiaConfirmationProbeController *) controller_
            setLegacySubstrateForProbe:NO];
    controllerToken_ = [[NSUUID UUID] UUIDString];
    if (navigation_ == nil) {
        navigation_ = [[UINavigationController alloc] initWithRootViewController:controller_];
        if (formSheet_) {
            navigation_.modalPresentationStyle = UIModalPresentationFormSheet;
            formSheetPresentationComplete_ = NO;
            UINavigationController *presentedNavigation(navigation_);
            [self presentViewController:presentedNavigation animated:NO completion:^{
                if (navigation_ != presentedNavigation)
                    return;
                formSheetPresentationComplete_ = YES;
                settleTicks_ = 5;
                [self applyTraits];
                [navigation_.view layoutIfNeeded];
            }];
        } else {
            navigation_.modalPresentationStyle = UIModalPresentationFullScreen;
            [self addChildViewController:navigation_];
            navigation_.view.frame = self.view.bounds;
            navigation_.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                                 UIViewAutoresizingFlexibleHeight;
            [self.view addSubview:navigation_.view];
            [navigation_ didMoveToParentViewController:self];
        }
    } else {
        [navigation_ setViewControllers:@[controller_] animated:NO];
    }
    [self applyTraits];
    [navigation_.view layoutIfNeeded];
    settleTicks_ = 5;
}

- (void) observeApplicationLifecycle {
    NSNotificationCenter *center([NSNotificationCenter defaultCenter]);
    for (NSNotificationName name in @[
            UIApplicationWillResignActiveNotification,
            UIApplicationDidEnterBackgroundNotification,
            UIApplicationWillEnterForegroundNotification,
            UIApplicationDidBecomeActiveNotification]) {
        [center addObserver:self selector:@selector(applicationLifecycleNotification:)
                      name:name object:nil];
    }
}

- (void) applicationLifecycleNotification:(NSNotification *)notification {
    if (!lifecycleArmed_)
        return;
    [lifecycleNotifications_ addObject:notification.name];
    if ([lifecycleNotifications_ count] == 4 &&
        [notification.name isEqualToString:UIApplicationDidBecomeActiveNotification]) {
        lifecycleArmed_ = NO;
        lifecycleComplete_ = YES;
    }
    [self writeState];
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
    lifecycleNotifications_ = [NSMutableArray array];
    [self installPhase:@"normal"];
    [self observeApplicationLifecycle];
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
        selector:@selector(probeTimerFired:) userInfo:nil repeats:YES];
}

- (void) probeTimerFired:(NSTimer *)timer {
    (void) timer;
    if ([self consumeMarker:@"cydia-confirmation-probe-arm-lifecycle"]) {
        [lifecycleNotifications_ removeAllObjects];
        lifecycleComplete_ = NO;
        lifecycleArmed_ = YES;
        settleTicks_ = 5;
    }
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
    if ([self consumeMarker:@"cydia-confirmation-probe-form-sheet"] && !formSheet_) {
        formSheet_ = YES;
        [self detachNavigation];
        [self installPhase:phase_ ?: @"normal"];
    }
    if ([self consumeMarker:@"cydia-confirmation-probe-accessibility"]) {
        accessibilityLarge_ = YES;
        [self installPhase:@"normal-accessibility"];
    }
    for (NSString *phase in @[@"normal", @"normal-confirm", @"normal-confirm-substrate-cleared",
                               @"normal-continue", @"normal-cancel", @"legacy-sparse",
                               @"empty", @"issues", @"essential-blocked", @"essential-force"]) {
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
    BOOL rowsMeetTouchTarget(YES);
    for (UITableViewCell *cell in table.visibleCells) {
        if (CGRectGetHeight(cell.bounds) < 43.5)
            rowsMeetTouchTarget = NO;
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
    CydiaConfirmationProbeController *probeController(
        (CydiaConfirmationProbeController *) controller_);
    NSDictionary *legacyChanges([probeController legacyChangesForProbe]);
    NSArray *actualLegacyChangeKeys([[legacyChanges allKeys]
        sortedArrayUsingSelector:@selector(compare:)]);
    /* Resolve semantic roles against the probe-controlled trait instead of
     * UIKit's transient adapted trait (compact form sheets may report an
     * unspecified style while their presentation controller is settling). */
    UITraitCollection *expectedTraits([UITraitCollection
        traitCollectionWithTraitsFromCollections:@[
            [UITraitCollection traitCollectionWithUserInterfaceStyle:
                dark_ ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight],
            [UITraitCollection traitCollectionWithPreferredContentSizeCategory:
                accessibilityLarge_ ? UIContentSizeCategoryAccessibilityLarge :
                    UIContentSizeCategoryLarge]]]);
    UIColor *expectedBackground([UIColor cydiaColorForRole:CydiaColorRoleBackground
                                             traitCollection:expectedTraits]);
    UIColor *expectedCellBackground([UIColor cydiaColorForRole:CydiaColorRoleCellBackground
                                                 traitCollection:expectedTraits]);
    UIColor *expectedPresenterBackground([UIColor cydiaColorForRole:
        CydiaColorRoleGroupedBackground traitCollection:expectedTraits]);
    UINavigationBar *navigationBar(navigation_.navigationBar);
    UIColor *navigationBarBackground(ConfirmationProbeResolvedColor(
        navigationBar.backgroundColor, expectedTraits));
    UIColor *navigationBarTint(ConfirmationProbeResolvedColor(
        navigationBar.barTintColor, expectedTraits));
    BOOL navigationBarUsesPresentedSurface(
        ConfirmationProbeColorsEqual(navigationBarBackground, expectedCellBackground) ||
        ConfirmationProbeColorsEqual(navigationBarTint, expectedCellBackground));
    BOOL sheetUsesCellBackground(
        ConfirmationProbeColorsEqual(root.backgroundColor, expectedCellBackground) &&
        ConfirmationProbeColorsEqual(table.backgroundColor, expectedCellBackground));
    BOOL presenterUsesGroupedBackground(ConfirmationProbeColorsEqual(
        self.view.backgroundColor, expectedPresenterBackground));
    /* UIKit's UINavigationBar.opaque flag is not stable across iOS 12/13
     * implementations; the effective chrome is opaque when its owning
     * navigation surface is opaque and the bar is explicitly non-translucent. */
    BOOL navigationBarOpaque(navigationBar != nil && navigation_.view.opaque &&
        !navigationBar.translucent);
    BOOL navigationBarTranslucent(navigationBar != nil && navigationBar.translucent);
    UIWindow *window(self.view.window);
    UIPresentationController *presentationController(navigation_.presentationController);
    UIView *presentationContainer(presentationController.containerView);
    UIView *presentedView(presentationController.presentedView);
    UIView *presentingView(presentationController.presentingViewController.view);
    CGRect containerBounds(presentationContainer == nil ? CGRectZero :
        presentationContainer.bounds);
    CGRect sheetContainerFrame(presentationController == nil ? CGRectZero :
        presentationController.frameOfPresentedViewInContainerView);
    CGRect sheetFrame(window == nil || presentationContainer == nil ? CGRectZero :
        [presentationContainer convertRect:sheetContainerFrame toView:window]);
    BOOL actualModal(formSheet_ && self.presentedViewController == navigation_ &&
        navigation_.presentingViewController == self && presentationController != nil);
    BOOL confirmationIsTopController(navigation_.topViewController == controller_);
    BOOL formSheetFrameInset(formSheet_ && actualModal && presentationContainer != nil &&
        CGRectGetMinX(sheetContainerFrame) >= CGRectGetMinX(containerBounds) + 1.0 &&
        CGRectGetMinY(sheetContainerFrame) >= CGRectGetMinY(containerBounds) + 1.0 &&
        CGRectGetMaxX(sheetContainerFrame) <= CGRectGetMaxX(containerBounds) - 1.0 &&
        CGRectGetMaxY(sheetContainerFrame) <= CGRectGetMaxY(containerBounds) - 1.0);
    UIView *outsideHit(nil);
    if (formSheetFrameInset) {
        CGPoint outsidePoint(CGPointMake(
            (CGRectGetMinX(containerBounds) + CGRectGetMinX(sheetContainerFrame)) / 2.0,
            CGRectGetMidY(sheetContainerFrame)));
        outsideHit = [presentationContainer hitTest:outsidePoint withEvent:nil];
    }
    BOOL backdropInterceptsOutsideSheet(outsideHit != nil &&
        presentationContainer != nil &&
        (outsideHit == presentationContainer ||
            [outsideHit isDescendantOfView:presentationContainer]) &&
        outsideHit != presentedView &&
        ![outsideHit isDescendantOfView:presentedView] &&
        outsideHit != presentingView &&
        ![outsideHit isDescendantOfView:presentingView]);
    UIUserInterfaceSizeClass horizontalSizeClass(self.traitCollection.horizontalSizeClass);
    UIModalPresentationStyle requestedPresentationStyle(navigation_ == nil ?
        UIModalPresentationFullScreen : navigation_.modalPresentationStyle);
    UIModalPresentationStyle adaptivePresentationStyle(presentationController == nil ?
        requestedPresentationStyle : presentationController.adaptivePresentationStyle);
    BOOL dimmingEvidenceEligible(formSheet_ && actualModal &&
        horizontalSizeClass == UIUserInterfaceSizeClassRegular &&
        formSheetFrameInset && backdropInterceptsOutsideSheet);
    BOOL presentationAttached(formSheet_ && actualModal && presentedView != nil &&
        presentedView.window == window && presentationContainer.window == window);
    // On compact iOS 12 UIKit adapts a requested form sheet to the host
    // controller instead of creating a presentation controller. That is a
    // settled, valid probe state, but it cannot satisfy the regular-width
    // attachment predicate above.
    BOOL compactFormSheetAdapted(formSheet_ &&
        requestedPresentationStyle == UIModalPresentationFullScreen &&
        !presentationAttached && !formSheetFrameInset);
    BOOL presentationReady(!formSheet_ || compactFormSheetAdapted ||
        (formSheetPresentationComplete_ && confirmationIsTopController &&
         presentationAttached));
    UIView *cancelTarget(controller_.navigationItem.leftBarButtonItem.customView);
    UIView *confirmTarget(controller_.navigationItem.rightBarButtonItem.customView);
    BOOL cancelTargetMeetsMinimum(cancelTarget != nil &&
        CGRectGetWidth(cancelTarget.bounds) >= 44.0 &&
        CGRectGetHeight(cancelTarget.bounds) >= 44.0);
    BOOL confirmTargetMeetsMinimum(![viewModel_ showsConfirmAction] ||
        (confirmTarget != nil && CGRectGetWidth(confirmTarget.bounds) >= 44.0 &&
         CGRectGetHeight(confirmTarget.bounds) >= 44.0));
    NSDictionary *state = @{
        @"ready": @(settleTicks_ == 0 && table != nil && sections != 0 &&
            presentationReady),
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
        @"hasChanges": @([viewModel_ hasChanges]),
        @"hasBlockingIssues": @([viewModel_ hasBlockingIssues]),
        @"showsConfirmAction": @([viewModel_ showsConfirmAction]),
        @"cancelTargetMeetsMinimum": @(cancelTargetMeetsMinimum),
        @"confirmTargetMeetsMinimum": @(confirmTargetMeetsMinimum),
        @"cancelTargetBounds": NSStringFromCGRect(cancelTarget.bounds),
        @"confirmTargetBounds": NSStringFromCGRect(confirmTarget.bounds),
        @"issueHeaderAccessibilityIdentity": issueHeaderAccessibilityIdentity,
        @"visibleRowsFit": @(visibleRowsFit),
        @"rowsMeetTouchTarget": @(rowsMeetTouchTarget),
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
        @"tableBackgroundLuminance": @(ConfirmationProbeLuminance(table.backgroundColor)),
        @"expectedBackgroundLuminance": @(ConfirmationProbeLuminance(expectedBackground)),
        @"expectedCellBackgroundLuminance": @(
            ConfirmationProbeLuminance(expectedCellBackground)),
        @"presenterBackgroundLuminance": @(ConfirmationProbeLuminance(
            self.view.backgroundColor)),
        @"expectedPresenterBackgroundLuminance": @(
            ConfirmationProbeLuminance(expectedPresenterBackground)),
        @"sheetUsesCellBackground": @(sheetUsesCellBackground),
        @"presenterUsesGroupedBackground": @(presenterUsesGroupedBackground),
        @"navigationBarUsesPresentedSurface": @(navigationBarUsesPresentedSurface),
        @"navigationBarOpaque": @(navigationBarOpaque),
        @"navigationBarTranslucent": @(navigationBarTranslucent),
        @"navigationBarBackgroundLuminance": @(ConfirmationProbeLuminance(
            navigationBarBackground)),
        @"contentSizeCategory": controller_.traitCollection.preferredContentSizeCategory ?: @"",
        @"expectedDefaultContentSizeCategory": UIContentSizeCategoryLarge,
        @"expectedAccessibilityContentSizeCategory": UIContentSizeCategoryAccessibilityLarge,
        @"visibleWebViews": @(ConfirmationProbeEmbeddedBrowserCount(root)),
        @"navigationBarHidden": @(navigation_.navigationBar.hidden),
        @"navigationBarFrame": NSStringFromCGRect(navigation_.navigationBar.frame),
        @"navigationDepth": @([navigation_.viewControllers count]),
        @"confirmationIsTopController": @(confirmationIsTopController),
        @"formSheetPresentation": @(requestedPresentationStyle == UIModalPresentationFormSheet),
        @"actualModalPresentation": @(actualModal),
        @"dismissalInFlight": @(navigation_.isBeingDismissed || controller_.isBeingDismissed),
        @"formSheetPresentationComplete": @(formSheetPresentationComplete_),
        @"formSheetRequested": @(formSheet_),
        @"settleTicks": @(settleTicks_),
        @"presentationAttached": @(presentationAttached),
        @"presentationFrame": NSStringFromCGRect(sheetFrame),
        @"requestedPresentationStyle": ConfirmationProbePresentationStyleName(
            requestedPresentationStyle),
        @"adaptivePresentationStyle": ConfirmationProbePresentationStyleName(
            adaptivePresentationStyle),
        @"horizontalSizeClass": ConfirmationProbeSizeClassName(horizontalSizeClass),
        @"formSheetFrameInset": @(formSheetFrameInset),
        @"backdropInterceptsOutsideSheet": @(backdropInterceptsOutsideSheet),
        @"dimmingEvidenceEligible": @(dimmingEvidenceEligible),
        @"backdropHitClass": outsideHit == nil ? @"" : NSStringFromClass([outsideHit class]),
        @"processID": @(getpid()),
        @"applicationState": ConfirmationProbeApplicationStateName(
            [UIApplication sharedApplication].applicationState),
        @"lifecycleArmed": @(lifecycleArmed_),
        @"lifecycleComplete": @(lifecycleComplete_),
        @"lifecycleNotificationCount": @([lifecycleNotifications_ count]),
        @"lifecycleNotifications": lifecycleNotifications_,
        @"lastLifecycleNotification": [lifecycleNotifications_ lastObject] ?: @"",
        @"controllerToken": controllerToken_ ?: @"",
        @"modelToken": modelToken_ ?: @"",
        @"legacyChangeKeys": actualLegacyChangeKeys ?: @[],
        @"legacyChangeKeyCount": @([actualLegacyChangeKeys count]),
        @"legacyInstalls": [legacyChanges objectForKey:@"installs"] ?: @[],
        @"legacyInstallsCount": @([[legacyChanges objectForKey:@"installs"] count]),
        @"legacyReinstalls": [legacyChanges objectForKey:@"reinstalls"] ?: @[],
        @"legacyReinstallsCount": @([[legacyChanges objectForKey:@"reinstalls"] count]),
        @"legacyUpgrades": [legacyChanges objectForKey:@"upgrades"] ?: @[],
        @"legacyUpgradesCount": @([[legacyChanges objectForKey:@"upgrades"] count]),
        @"legacyDowngrades": [legacyChanges objectForKey:@"downgrades"] ?: @[],
        @"legacyDowngradesCount": @([[legacyChanges objectForKey:@"downgrades"] count]),
        @"legacyRemoves": [legacyChanges objectForKey:@"removes"] ?: @[],
        @"legacyRemovesCount": @([[legacyChanges objectForKey:@"removes"] count]),
        @"legacySubstrate": @([probeController legacySubstrateForProbe]),
        @"restartSubstrate": @(RestartSubstrate_),
        @"legacyChangesIvarPresent": @(
            class_getInstanceVariable([ConfirmationController class], "changes_") != nullptr),
        @"legacySubstrateIvarPresent": @(
            class_getInstanceVariable([ConfirmationController class], "substrate_") != nullptr),
    };
    [state writeToFile:[self markerPath:@"cydia-confirmation-probe.plist"] atomically:YES];
}

@end

UIViewController *CydiaConfirmationControllerProbeRootController(void) {
    return [[CydiaConfirmationProbeHostController alloc] init];
}

#endif
