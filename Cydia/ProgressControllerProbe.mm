/* Cydia Refurbished native progress simulator probe.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ProgressControllerProbe.h"

#if TARGET_OS_SIMULATOR

#include "Cydia/ProgressController.h"
#include "Cydia/ProgressData.h"
#include "Cydia/ProgressEvent.h"
#include "Cydia/ProgressEventCell.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"

#include <cmath>
#include <unistd.h>

@interface ProgressController (CydiaProgressProbe)
- (id) initWithProgressModelForTesting:(CydiaProgressViewModel *)model delegate:(id)delegate;
- (void) cancel;
@end

static UIView *ProgressProbeView(UIView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqualToString:identifier])
        return root;
    for (UIView *child in root.subviews) {
        UIView *match(ProgressProbeView(child, identifier));
        if (match != nil)
            return match;
    }
    return nil;
}

static NSUInteger ProgressProbeEmbeddedBrowserCount(UIView *root) {
    NSUInteger count(0);
    NSString *browserClassToken([@"Web" stringByAppendingString:@"View"]);
    if ([NSStringFromClass([root class]) rangeOfString:browserClassToken].location != NSNotFound)
        ++count;
    for (UIView *child in root.subviews)
        count += ProgressProbeEmbeddedBrowserCount(child);
    return count;
}

static NSInteger ProgressProbeLuminance(UIColor *color) {
    CGFloat red(0), green(0), blue(0), alpha(0);
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white(0);
        if (![color getWhite:&white alpha:&alpha])
            return -1;
        red = green = blue = white;
    }
    return (NSInteger) lround(((red + green + blue) / 3.0) * 1000.0);
}

static BOOL ProgressProbeColorsEqual(UIColor *left, UIColor *right) {
    CGFloat lr(0), lg(0), lb(0), la(0), rr(0), rg(0), rb(0), ra(0);
    return [left getRed:&lr green:&lg blue:&lb alpha:&la] &&
           [right getRed:&rr green:&rg blue:&rb alpha:&ra] &&
           fabs(lr - rr) < 0.01 && fabs(lg - rg) < 0.01 &&
           fabs(lb - rb) < 0.01 && fabs(la - ra) < 0.01;
}

static UIColor *ProgressProbeResolvedColor(UIColor *color,
                                           UITraitCollection *traits) {
    if (color == nil)
        return nil;
    if (@available(iOS 13.0, *)) {
        if ([color respondsToSelector:@selector(resolvedColorWithTraitCollection:)])
            return [color resolvedColorWithTraitCollection:traits];
    }
    return color;
}

static NSString *ProgressProbeApplicationStateName(UIApplicationState state) {
    switch (state) {
        case UIApplicationStateActive: return @"active";
        case UIApplicationStateInactive: return @"inactive";
        case UIApplicationStateBackground: return @"background";
    }
    return @"unknown";
}

static NSString *ProgressProbePresentationStyleName(UIModalPresentationStyle style) {
    switch (style) {
        case UIModalPresentationFullScreen: return @"fullScreen";
        case UIModalPresentationFormSheet: return @"formSheet";
        case UIModalPresentationNone: return @"none";
        default: return @"other";
    }
}

static NSString *ProgressProbeSizeClassName(UIUserInterfaceSizeClass sizeClass) {
    switch (sizeClass) {
        case UIUserInterfaceSizeClassCompact: return @"compact";
        case UIUserInterfaceSizeClassRegular: return @"regular";
        case UIUserInterfaceSizeClassUnspecified: return @"unspecified";
    }
    return @"unknown";
}

static NSString *ProgressProbeAccessibilityValue(CydiaProgressViewState *state) {
    NSString *percent(state.progressDeterminate ?
        [NSNumberFormatter localizedStringFromNumber:@(state.displayPercent)
                                         numberStyle:NSNumberFormatterPercentStyle] :
        UCLocalize("UNKNOWN"));
    if (state.running || [state.finishTitle length] == 0)
        return percent;
    return [NSString stringWithFormat:UCLocalize("COMMA_DELIMITED"),
        percent, state.finishTitle];
}

@interface CydiaProgressProbeHostController : UIViewController
@end

@implementation CydiaProgressProbeHostController {
    CydiaProgressViewModel *model_;
    ProgressController *controller_;
    UINavigationController *navigation_;
    UIViewController *confirmationPlaceholder_;
    NSTimer *timer_;
    NSString *phase_;
    BOOL dark_;
    BOOL accessibilityLarge_;
    BOOL formSheet_;
    BOOL formSheetPushComplete_;
    NSUInteger settleTicks_;
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
    [timer_ invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) applyControlledTraits {
    UIUserInterfaceStyle style(dark_ ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight);
    UITraitCollection *appearance([UITraitCollection traitCollectionWithUserInterfaceStyle:style]);
    UITraitCollection *contentSize([UITraitCollection
        traitCollectionWithPreferredContentSizeCategory:accessibilityLarge_ ?
            UIContentSizeCategoryAccessibilityLarge : UIContentSizeCategoryLarge]);
    UITraitCollection *traits([UITraitCollection traitCollectionWithTraitsFromCollections:
        @[appearance, contentSize]]);
    if (formSheet_) {
        if (navigation_.presentationController != nil)
            navigation_.presentationController.overrideTraitCollection = traits;
    } else {
        [self setOverrideTraitCollection:traits forChildViewController:navigation_];
    }
    self.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                           traitCollection:traits];
    if (confirmationPlaceholder_ != nil)
        confirmationPlaceholder_.view.backgroundColor = [UIColor cydiaColorForRole:
            CydiaColorRoleCellBackground traitCollection:traits];
    [navigation_.view setNeedsLayout];
    [navigation_.view layoutIfNeeded];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void) installControllerForControlledTraits {
    if (navigation_ != nil) {
        if (navigation_.presentingViewController != nil)
            [self dismissViewControllerAnimated:NO completion:nil];
        else {
            [navigation_ willMoveToParentViewController:nil];
            [navigation_.view removeFromSuperview];
            [navigation_ removeFromParentViewController];
        }
        controller_ = nil;
        navigation_ = nil;
        confirmationPlaceholder_ = nil;
    }

    controller_ = [[ProgressController alloc]
        initWithProgressModelForTesting:model_ delegate:self];
    controllerToken_ = [[NSUUID UUID] UUIDString];
    if (formSheet_) {
        confirmationPlaceholder_ = [[UIViewController alloc] init];
        confirmationPlaceholder_.navigationItem.title = UCLocalize("CONFIRM");
        confirmationPlaceholder_.view.accessibilityIdentifier =
            @"cydia.progress.confirmation-placeholder";
        confirmationPlaceholder_.view.backgroundColor = [UIColor cydiaColorForRole:
            CydiaColorRoleCellBackground traitCollection:self.traitCollection];
        navigation_ = [[UINavigationController alloc]
            initWithRootViewController:confirmationPlaceholder_];
        navigation_.modalPresentationStyle = UIModalPresentationFormSheet;
        formSheetPushComplete_ = NO;
        [self presentViewController:navigation_ animated:NO completion:^{
            [navigation_ pushViewController:controller_ animated:NO];
            formSheetPushComplete_ = YES;
            settleTicks_ = 5;
            [self applyControlledTraits];
        }];
    } else {
        navigation_ = [[UINavigationController alloc] initWithRootViewController:controller_];
        navigation_.modalPresentationStyle = UIModalPresentationFullScreen;
        [self addChildViewController:navigation_];
        navigation_.view.frame = self.view.bounds;
        navigation_.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                            UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:navigation_.view];
        [navigation_ didMoveToParentViewController:self];
    }
    [self applyControlledTraits];
    [navigation_.view layoutIfNeeded];
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
    [self writeProbeState];
}

- (void) addFixtures {
    [model_ beginWithTitle:@"RUNNING"];
    [model_ setCancellable:true];
    [model_ setProgressStatus:@{
        @"Percent": @0.42f,
        @"Current": @420000,
        @"Total": @1000000,
        @"Speed": @24000,
    }];

    CydiaProgressEvent *status([CydiaProgressEvent
        eventWithMessage:@"Downloading runtime:iphoneos-arm64"
                  ofType:@"Status"
               forPackage:@"runtime:iphoneos-arm64"]);
    [status setVersion:@"1:2.0-1"];
    [model_ addProgressEvent:status];
    [model_ addProgressEvent:[CydiaProgressEvent
        eventWithMessage:@"Preparing files\rConfiguring files\r"
                  ofType:@"Information"]];
    [model_ addProgressEvent:[CydiaProgressEvent
        eventWithMessage:@"The existing configuration file was kept for this package."
                  ofType:@"Warning"]];
    [model_ addProgressEvent:[CydiaProgressEvent
        eventWithMessage:@"A future event type remains visible by its original name."
                  ofType:@"FutureKind"]];
    CydiaProgressEvent *error([CydiaProgressEvent
        eventWithMessage:@"A deliberately long resolver diagnostic remains readable at regular and accessibility text sizes, wraps across multiple terminal lines, and keeps its final words visible after the package transaction has finished resolving dependencies and validating every configured path."
                  ofType:@"Error"]);
    [error setPackage:@"runtime:iphoneos-arm64"];
    [model_ addProgressEvent:error];
    phase_ = @"running";
    settleTicks_ = 5;
}

- (void) loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    lifecycleNotifications_ = [NSMutableArray array];

    model_ = [[CydiaProgressViewModel alloc]
        initWithLegacyData:[[CydiaProgressData alloc] init]
        packageNameResolver:^NSString *(NSString *identifier) {
            return [identifier isEqualToString:@"runtime:iphoneos-arm64"] ?
                @"Runtime Native" : nil;
        }
        localizer:nil];
    modelToken_ = [[NSUUID UUID] UUIDString];
    [self installControllerForControlledTraits];
    [self addFixtures];
    [self observeApplicationLifecycle];
    timer_ = [NSTimer scheduledTimerWithTimeInterval:0.1
        target:self selector:@selector(probeTimerFired:) userInfo:nil repeats:YES];
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

- (void) probeTimerFired:(NSTimer *)timer {
    (void) timer;
    if ([self consumeMarker:@"cydia-progress-probe-arm-lifecycle"]) {
        [lifecycleNotifications_ removeAllObjects];
        lifecycleComplete_ = NO;
        lifecycleArmed_ = YES;
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-progress-probe-dark"]) {
        dark_ = YES;
        settleTicks_ = 5;
        [self applyControlledTraits];
    }
    if ([self consumeMarker:@"cydia-progress-probe-light"]) {
        dark_ = NO;
        settleTicks_ = 5;
        [self applyControlledTraits];
    }
    if ([self consumeMarker:@"cydia-progress-probe-form-sheet"] && !formSheet_) {
        formSheet_ = YES;
        settleTicks_ = 5;
        [self installControllerForControlledTraits];
    }
    if ([self consumeMarker:@"cydia-progress-probe-accessibility"] &&
        ![phase_ isEqualToString:@"complete"]) {
        accessibilityLarge_ = YES;
        phase_ = @"running-accessibility";
        settleTicks_ = 5;
        [self applyControlledTraits];
    }
    if ([self consumeMarker:@"cydia-progress-probe-default"] &&
        ![phase_ isEqualToString:@"complete"]) {
        accessibilityLarge_ = NO;
        phase_ = @"running-default";
        /* A synthetic Accessibility-to-default override can publish its new
         * trait before UIKit completes the dependent table layout/display
         * passes. Keep readiness false through that transition. */
        settleTicks_ = 15;
        [self applyControlledTraits];
    }
    if ([self consumeMarker:@"cydia-progress-probe-cancel"] &&
        ![phase_ isEqualToString:@"complete"]) {
        /* Drive the same controller action as the visible Cancel item. The
         * model's requested state remains observable until the completion
         * marker explicitly clears cancellability. */
        [controller_ cancel];
        phase_ = @"running-cancelled";
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-progress-probe-finish"] &&
        ![phase_ isEqualToString:@"complete"]) {
        [model_ setCancellable:false];
        [model_ setTitle:@"COMPLETE"];
        [model_ completeWithFinishAction:CydiaProgressFinishActionReloadSpringBoard];
        phase_ = @"complete";
        settleTicks_ = 5;
    }
    if (settleTicks_ != 0)
        --settleTicks_;
    [self writeProbeState];
}

- (void) writeProbeState {
    [navigation_.view layoutIfNeeded];
    UIView *root(controller_.view);
    UILabel *status((UILabel *) ProgressProbeView(root, @"cydia.progress.status"));
    UIProgressView *progress((UIProgressView *) ProgressProbeView(root, @"cydia.progress.percent"));
    UIButton *finishButton((UIButton *) ProgressProbeView(root, @"cydia.progress.finish"));
    UIView *footer(ProgressProbeView(root, @"cydia.progress.footer"));
    UITableView *table((UITableView *) ProgressProbeView(root, @"cydia.progress.events"));
    [table layoutIfNeeded];

    NSInteger rows([table numberOfRowsInSection:0]);
    UITableViewCell *(^cellAtRow)(NSInteger) = ^UITableViewCell *(NSInteger row) {
        if (row < 0 || row >= rows)
            return nil;
        NSIndexPath *path([NSIndexPath indexPathForRow:row inSection:0]);
        return [table cellForRowAtIndexPath:path];
    };
    UITableViewCell *first(cellAtRow(0));
    UITableViewCell *carriageReturn(cellAtRow(1));
    UITableViewCell *warning(cellAtRow(2));
    UITableViewCell *unknown(cellAtRow(3));
    UITableViewCell *last(cellAtRow(rows - 1));
    CydiaProgressEventCell *firstEventCell((CydiaProgressEventCell *) first);
    CydiaProgressEventCell *lastEventCell((CydiaProgressEventCell *) last);
    NSArray<CydiaProgressPresentationEvent *> *events(model_.state.events);
    CydiaProgressPresentationEvent *firstEvent([events firstObject]);
    CydiaProgressPresentationEvent *carriageReturnEvent([events count] <= 1 ? nil :
        [events objectAtIndex:1]);
    CydiaProgressPresentationEvent *warningEvent([events count] <= 2 ? nil : [events objectAtIndex:2]);
    CydiaProgressPresentationEvent *unknownEvent([events count] <= 3 ? nil : [events objectAtIndex:3]);
    CydiaProgressPresentationEvent *lastEvent([events lastObject]);
    UILabel *firstMessage((UILabel *) ProgressProbeView(first,
        @"cydia.progress.event.message"));
    UILabel *carriageReturnMessage((UILabel *) ProgressProbeView(carriageReturn,
        @"cydia.progress.event.message"));
    UILabel *warningMessage((UILabel *) ProgressProbeView(warning,
        @"cydia.progress.event.message"));
    UILabel *warningMarker((UILabel *) ProgressProbeView(warning,
        @"cydia.progress.event.marker"));
    UILabel *unknownMessage((UILabel *) ProgressProbeView(unknown,
        @"cydia.progress.event.message"));
    UILabel *errorMessage((UILabel *) ProgressProbeView(last,
        @"cydia.progress.event.message"));
    UILabel *errorMarker((UILabel *) ProgressProbeView(last,
        @"cydia.progress.event.marker"));
    CGFloat lastHeight(rows == 0 ? 0 : [table rectForRowAtIndexPath:
        [NSIndexPath indexPathForRow:rows - 1 inSection:0]].size.height);
    CGFloat errorRequiredHeight([errorMessage sizeThatFits:CGSizeMake(
        CGRectGetWidth(errorMessage.bounds), CGFLOAT_MAX)].height);
    NSMutableArray<NSNumber *> *rowHeights([NSMutableArray arrayWithCapacity:(NSUInteger) rows]);
    BOOL allRowsHaveTerminalSurface(YES);
    for (NSInteger row(0); row != rows; ++row) {
        NSIndexPath *path([NSIndexPath indexPathForRow:row inSection:0]);
        [rowHeights addObject:@((NSInteger) lround(CGRectGetHeight(
            [table rectForRowAtIndexPath:path])))];
        UITableViewCell *eventCell(cellAtRow(row));
        if (eventCell == nil)
            allRowsHaveTerminalSurface = NO;
    }
    CGFloat firstMessageLineHeight(firstEventCell == nil ? 0.0 :
        firstEventCell.messageLineHeight);
    CGFloat firstMessageLineSpacing(firstEventCell == nil ? 0.0 :
        firstEventCell.messageLineSpacing);
    CGFloat firstMessageMinimumLineHeight(firstEventCell == nil ? 0.0 :
        firstEventCell.messageMinimumLineHeight);
    CGFloat firstMessageMaximumLineHeight(firstEventCell == nil ? 0.0 :
        firstEventCell.messageMaximumLineHeight);
    CGFloat errorLineHeight(lastEventCell == nil ? 0.0 : lastEventCell.messageLineHeight);
    CGFloat errorLineSpacing(lastEventCell == nil ? 0.0 : lastEventCell.messageLineSpacing);
    CGFloat errorMinimumLineHeight(lastEventCell == nil ? 0.0 :
        lastEventCell.messageMinimumLineHeight);
    CGFloat errorMaximumLineHeight(lastEventCell == nil ? 0.0 :
        lastEventCell.messageMaximumLineHeight);
    CGFloat firstRowHeight(rows == 0 ? 0.0 : [table rectForRowAtIndexPath:
        [NSIndexPath indexPathForRow:0 inSection:0]].size.height);
    UIEdgeInsets eventMargins(firstEventCell == nil ? UIEdgeInsetsZero :
        firstEventCell.eventLayoutMargins);
    BOOL actualModal(!formSheet_ || (self.presentedViewController == navigation_ &&
        navigation_.presentingViewController == self &&
        navigation_.presentationController != nil));
    BOOL confirmationPlaceholderIsRoot(!formSheet_ ||
        ([navigation_.viewControllers firstObject] == confirmationPlaceholder_ &&
         [confirmationPlaceholder_.view.accessibilityIdentifier
            isEqualToString:@"cydia.progress.confirmation-placeholder"]));
    BOOL contentReady(settleTicks_ == 0 && rows == (NSInteger) [events count] &&
                      firstMessage != nil && carriageReturnMessage != nil &&
                      warningMessage != nil && unknownMessage != nil &&
                      errorMessage != nil && footer != nil && finishButton != nil &&
                      [[controller_.navigationItem title] length] != 0 &&
                      [status.text isEqualToString:model_.state.statusText]);
    /* UIKit may temporarily report an unspecified/adapted trait on a compact
     * form-sheet controller. Resolve expected roles against the probe's
     * explicit appearance so the contract compares actual surfaces with the
     * requested dark/light palette rather than that transient trait. */
    UITraitCollection *expectedTraits([UITraitCollection
        traitCollectionWithUserInterfaceStyle:dark_ ? UIUserInterfaceStyleDark :
            UIUserInterfaceStyleLight]);
    UIColor *expectedBackground([UIColor cydiaColorForRole:CydiaColorRoleBackground
                                             traitCollection:expectedTraits]);
    UIColor *expectedCellBackground([UIColor cydiaColorForRole:CydiaColorRoleCellBackground
                                                 traitCollection:expectedTraits]);
    UITraitCollection *terminalTraits([UITraitCollection
        traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]);
    UIColor *expectedTerminalBackground([UIColor cydiaColorForRole:CydiaColorRoleBackground
                                                   traitCollection:terminalTraits]);
    UIColor *expectedTerminalLabel([UIColor cydiaColorForRole:CydiaColorRoleLabel
                                             traitCollection:terminalTraits]);
    UIColor *expectedTerminalSecondary([UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                                       traitCollection:terminalTraits]);
    UIColor *expectedTerminalSeparator([UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                                       traitCollection:terminalTraits]);
    UIColor *expectedTerminalAccent([UIColor cydiaColorForRole:CydiaColorRoleAccent
                                                   traitCollection:terminalTraits]);
    UIColor *expectedTerminalWarning([UIColor cydiaColorForRole:CydiaColorRoleWarningLabel
                                                    traitCollection:terminalTraits]);
    UIColor *expectedTerminalError([UIColor cydiaColorForRole:CydiaColorRoleErrorLabel
                                                  traitCollection:terminalTraits]);
    UIColor *navigationBarBackground(ProgressProbeResolvedColor(
        navigation_.navigationBar.backgroundColor, terminalTraits));
    UIColor *navigationBarTitleColor([navigation_.navigationBar.titleTextAttributes
        objectForKey:NSForegroundColorAttributeName]);
    BOOL confirmationPlaceholderUsesCellBackground(!formSheet_ ||
        ProgressProbeColorsEqual(confirmationPlaceholder_.view.backgroundColor,
            expectedCellBackground));
    BOOL eventCellsUseTerminalSurface(allRowsHaveTerminalSurface);
    for (UITableViewCell *eventCell in table.visibleCells) {
        eventCellsUseTerminalSurface = eventCellsUseTerminalSurface &&
            ProgressProbeColorsEqual(eventCell.backgroundColor, expectedTerminalBackground) &&
            ProgressProbeColorsEqual(eventCell.contentView.backgroundColor,
                expectedTerminalBackground);
    }
    BOOL terminalCanvasUsesFixedPalette(
        ProgressProbeColorsEqual(root.backgroundColor, expectedTerminalBackground) &&
        ProgressProbeColorsEqual(table.backgroundColor, expectedTerminalBackground) &&
        ProgressProbeColorsEqual(footer.backgroundColor, expectedTerminalBackground));
    UIColor *expectedPresenterBackground([UIColor cydiaColorForRole:
        CydiaColorRoleGroupedBackground traitCollection:expectedTraits]);
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
    BOOL formSheetFrameInset(formSheet_ && presentationContainer != nil &&
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
    UIModalPresentationStyle adaptivePresentationStyle(presentationController == nil ?
        UIModalPresentationFullScreen : presentationController.adaptivePresentationStyle);
    BOOL dimmingEvidenceEligible(formSheet_ && actualModal &&
        horizontalSizeClass == UIUserInterfaceSizeClassRegular &&
        formSheetFrameInset && backdropInterceptsOutsideSheet);
    BOOL presentationAttached(formSheet_ && actualModal && presentedView != nil &&
        presentedView.window == window && presentationContainer.window == window);
    BOOL presentationReady(!formSheet_ || (formSheetPushComplete_ &&
        confirmationPlaceholderIsRoot && presentationAttached));
    BOOL ready(contentReady && presentationReady);
    NSString *expectedUnknown([NSString stringWithFormat:UCLocalize("COLON_DELIMITED"),
        unknownEvent.rawType, unknownEvent.displayMessage]);

    NSDictionary *state = @{
        @"ready": @(ready),
        @"phase": phase_ ?: @"starting",
        @"style": dark_ ? @"dark" : @"light",
        @"revision": @(model_.state.revision),
        @"cancellationState": @(model_.state.cancellationState),
        @"progressCancelled": @([model_ isProgressCancelled]),
        @"rows": @(rows),
        @"modelEvents": @([events count]),
        @"title": controller_.navigationItem.title ?: @"",
        @"expectedTitle": model_.state.localizedTitle ?: @"",
        @"status": status.text ?: @"",
        @"expectedStatus": model_.state.statusText ?: @"",
        @"firstEvent": firstEvent.displayMessage ?: @"",
        @"firstVisibleText": firstMessage.text ?: @"",
        @"carriageReturnVisibleText": carriageReturnMessage.text ?: @"",
        @"expectedCarriageReturnVisibleText": carriageReturnEvent.displayMessage ?: @"",
        @"lastEvent": lastEvent.displayMessage ?: @"",
        @"multiarchIdentity": lastEvent.packageIdentifier ?: @"",
        @"multiarchCellIdentifier": last.accessibilityIdentifier ?: @"",
        @"lastCellAccessibilityLabel": last.accessibilityLabel ?: @"",
        @"warningVisibleText": warningMessage.text ?: @"",
        @"expectedWarningVisibleText": warningEvent.displayMessage ?: @"",
        @"unknownVisibleText": unknownMessage.text ?: @"",
        @"expectedUnknownVisibleText": expectedUnknown ?: @"",
        @"unknownCellAccessibilityLabel": unknown.accessibilityLabel ?: @"",
        @"expectedUnknownAccessibilityLabel": unknownEvent.accessibilityLabel ?: @"",
        @"errorVisibleText": errorMessage.text ?: @"",
        @"expectedErrorVisibleText": lastEvent.displayMessage ?: @"",
        @"warningMarker": warningMarker.text ?: @"",
        @"warningMarkerHidden": @(warningMarker.hidden),
        @"errorMarker": errorMarker.text ?: @"",
        @"errorMarkerHidden": @(errorMarker.hidden),
        @"warningUsesSemanticColor": @(ProgressProbeColorsEqual(
            warningMessage.textColor, expectedTerminalWarning)),
        @"errorUsesSemanticColor": @(ProgressProbeColorsEqual(
            errorMessage.textColor, expectedTerminalError)),
        @"eventCellsUseTerminalSurface": @(eventCellsUseTerminalSurface),
        @"terminalCanvasUsesFixedPalette": @(terminalCanvasUsesFixedPalette),
        @"confirmationPlaceholderUsesCellBackground":
            @(confirmationPlaceholderUsesCellBackground),
        @"statusUsesTerminalSecondaryColor": @(ProgressProbeColorsEqual(
            status.textColor, expectedTerminalSecondary)),
        @"navigationUsesTerminalPalette": @(ProgressProbeColorsEqual(
            navigationBarBackground, expectedTerminalBackground) &&
            ProgressProbeColorsEqual(navigationBarTitleColor, expectedTerminalLabel) &&
            navigation_.navigationBar.barStyle == UIBarStyleBlack),
        @"footerUsesTerminalBackground": @(ProgressProbeColorsEqual(
            footer.backgroundColor, expectedTerminalBackground)),
        @"progressUsesTerminalPalette": @(ProgressProbeColorsEqual(
            progress.progressTintColor, expectedTerminalAccent) &&
            ProgressProbeColorsEqual(progress.trackTintColor, expectedTerminalSeparator)),
        @"finishUsesTerminalLabelColor": @(ProgressProbeColorsEqual(
            [finishButton titleColorForState:UIControlStateNormal], expectedTerminalLabel)),
        @"preferredStatusBarStyle": @([controller_ preferredStatusBarStyle]),
        @"navigationBarStyle": @(navigation_.navigationBar.barStyle),
        @"firstRowHeight": @((NSInteger) lround(firstRowHeight)),
        @"rowHeights": rowHeights,
        @"eventLayoutMarginsTop": @(eventMargins.top),
        @"eventLayoutMarginsBottom": @(eventMargins.bottom),
        @"eventLayoutMarginsLeft": @(eventMargins.left),
        @"eventLayoutMarginsRight": @(eventMargins.right),
        @"messageLineHeight": @(firstMessageLineHeight),
        @"messageLineSpacing": @(firstMessageLineSpacing),
        @"messageMinimumLineHeight": @(firstMessageMinimumLineHeight),
        @"messageMaximumLineHeight": @(firstMessageMaximumLineHeight),
        @"errorLineHeight": @(errorLineHeight),
        @"errorLineSpacing": @(errorLineSpacing),
        @"errorMinimumLineHeight": @(errorMinimumLineHeight),
        @"errorMaximumLineHeight": @(errorMaximumLineHeight),
        @"lastRowHeight": @((NSInteger) lround(lastHeight)),
        @"progress": @(progress.progress),
        @"progressAccessibilityLabel": progress.accessibilityLabel ?: @"",
        @"progressAccessibilityValue": progress.accessibilityValue ?: @"",
        @"expectedProgressAccessibilityValue": ProgressProbeAccessibilityValue(model_.state),
        @"expectedRunningAccessibilityLabel": UCLocalize("RUNNING"),
        @"expectedCompleteAccessibilityLabel": UCLocalize("COMPLETE"),
        @"cancelTitle": controller_.navigationItem.leftBarButtonItem.title ?: @"",
        @"finishTitle": controller_.navigationItem.rightBarButtonItem.title ?: @"",
        @"finishButtonTitle": [finishButton titleForState:UIControlStateNormal] ?: @"",
        @"finishButtonHidden": @(finishButton.hidden),
        @"expectedFinishTitle": model_.state.finishTitle ?: @"",
        @"statusAdjustsFont": @(status.adjustsFontForContentSizeCategory),
        @"finishAdjustsFont": @(finishButton.titleLabel.adjustsFontForContentSizeCategory),
        @"statusPointSize": @(status.font.pointSize),
        @"errorPointSize": @(errorMessage.font.pointSize),
        @"statusHidden": @(status.hidden),
        @"statusAlpha": @(status.alpha),
        @"statusFrame": NSStringFromCGRect(status.frame),
        @"footerFrame": NSStringFromCGRect(footer.frame),
        @"tableFrame": NSStringFromCGRect(table.frame),
        @"tableContentOffset": NSStringFromCGPoint(table.contentOffset),
        @"tableContentSize": NSStringFromCGSize(table.contentSize),
        @"warningMessageFrame": NSStringFromCGRect(warningMessage.frame),
        @"warningMessageHidden": @(warningMessage.hidden),
        @"warningMessageAlpha": @(warningMessage.alpha),
        @"errorMessageFrame": NSStringFromCGRect(errorMessage.frame),
        @"errorMessageHeight": @((NSInteger) floor(CGRectGetHeight(errorMessage.bounds))),
        @"errorRequiredHeight": @((NSInteger) ceil(errorRequiredHeight)),
        @"errorMessageHidden": @(errorMessage.hidden),
        @"errorMessageAlpha": @(errorMessage.alpha),
        @"controllerFrame": NSStringFromCGRect(root.frame),
        @"eventTableAboveFooter": @(CGRectGetMaxY([table convertRect:table.bounds toView:root]) <=
            CGRectGetMinY([footer convertRect:footer.bounds toView:root]) + 1.0),
        @"footerInLowerHalf": @(CGRectGetMidY([footer convertRect:footer.bounds toView:root]) >
            CGRectGetMidY(root.bounds)),
        @"navigationFrame": NSStringFromCGRect(navigation_.view.frame),
        @"presentationFrame": NSStringFromCGRect(sheetFrame),
        @"statusBarHidden": @([UIApplication sharedApplication].statusBarHidden),
        @"contentSizeCategory": controller_.traitCollection.preferredContentSizeCategory ?: @"",
        @"expectedDefaultContentSizeCategory": UIContentSizeCategoryLarge,
        @"expectedAccessibilityContentSizeCategory": UIContentSizeCategoryAccessibilityLarge,
        @"backgroundLuminance": @(ProgressProbeLuminance(root.backgroundColor)),
        @"tableBackgroundLuminance": @(ProgressProbeLuminance(table.backgroundColor)),
        @"footerBackgroundLuminance": @(ProgressProbeLuminance(footer.backgroundColor)),
        @"terminalBackgroundLuminance": @(
            ProgressProbeLuminance(expectedTerminalBackground)),
        @"expectedBackgroundLuminance": @(ProgressProbeLuminance(expectedBackground)),
        @"expectedCellBackgroundLuminance": @(ProgressProbeLuminance(expectedCellBackground)),
        @"expectedTerminalBackgroundLuminance": @(
            ProgressProbeLuminance(expectedTerminalBackground)),
        @"expectedPresenterBackgroundLuminance": @(
            ProgressProbeLuminance(expectedPresenterBackground)),
        @"canvasUsesBackground": @(ProgressProbeColorsEqual(root.backgroundColor,
            expectedBackground) && ProgressProbeColorsEqual(table.backgroundColor,
            expectedBackground) && ProgressProbeColorsEqual(footer.backgroundColor,
            expectedBackground)),
        @"canvasUsesCellBackground": @(ProgressProbeColorsEqual(root.backgroundColor,
            expectedCellBackground) && ProgressProbeColorsEqual(table.backgroundColor,
            expectedCellBackground) && ProgressProbeColorsEqual(footer.backgroundColor,
            expectedCellBackground)),
        @"formSheetPresentation": @(navigation_.modalPresentationStyle ==
            UIModalPresentationFormSheet),
        @"actualModalPresentation": @(formSheet_ && actualModal),
        @"presentationAttached": @(presentationAttached),
        @"navigationDepth": @([navigation_.viewControllers count]),
        @"progressIsTopController": @(navigation_.topViewController == controller_),
        @"confirmationPlaceholderIsRoot": @(formSheet_ && confirmationPlaceholderIsRoot),
        @"confirmationPlaceholderIdentifier":
            confirmationPlaceholder_.view.accessibilityIdentifier ?: @"",
        @"expectedConfirmationPlaceholderIdentifier":
            @"cydia.progress.confirmation-placeholder",
        @"confirmationPlaceholderTitle":
            confirmationPlaceholder_.navigationItem.title ?: @"",
        @"presenterBackgroundLuminance": @(ProgressProbeLuminance(
            self.view.backgroundColor)),
        @"presenterUsesGroupedBackground": @(ProgressProbeColorsEqual(
            self.view.backgroundColor, expectedPresenterBackground)),
        @"deviceIdiom": [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad ?
            @"pad" : @"phone",
        @"horizontalSizeClass": ProgressProbeSizeClassName(horizontalSizeClass),
        @"requestedPresentationStyle": ProgressProbePresentationStyleName(
            presentationController == nil ? UIModalPresentationFullScreen :
                presentationController.presentationStyle),
        @"adaptivePresentationStyle": ProgressProbePresentationStyleName(
            adaptivePresentationStyle),
        @"formSheetFrameInset": @(formSheetFrameInset),
        @"backdropInterceptsOutsideSheet": @(backdropInterceptsOutsideSheet),
        @"dimmingEvidenceEligible": @(dimmingEvidenceEligible),
        @"backdropHitClass": outsideHit == nil ? @"" : NSStringFromClass([outsideHit class]),
        @"visibleWebViews": @(ProgressProbeEmbeddedBrowserCount(root)),
        @"processID": @(getpid()),
        @"applicationState": ProgressProbeApplicationStateName(
            [UIApplication sharedApplication].applicationState),
        @"lifecycleArmed": @(lifecycleArmed_),
        @"lifecycleComplete": @(lifecycleComplete_),
        @"lifecycleNotificationCount": @([lifecycleNotifications_ count]),
        @"lifecycleNotifications": lifecycleNotifications_,
        @"lastLifecycleNotification": [lifecycleNotifications_ lastObject] ?: @"",
        @"controllerToken": controllerToken_ ?: @"",
        @"modelToken": modelToken_ ?: @"",
    };
    [state writeToFile:[self markerPath:@"cydia-progress-probe.plist"] atomically:YES];
}

/* These are deliberately inert. The probe verifies action selection and
 * chrome without performing application termination or device side effects. */
- (void) saveState {}
- (void) returnToCydia {}
- (void) terminateWithSuccess {}
- (id) addProgressHUD { return nil; }
- (void) reloadSpringBoard {}

@end

UIViewController *CydiaProgressControllerProbeRootController(void) {
    return [[CydiaProgressProbeHostController alloc] init];
}

#else

UIViewController *CydiaProgressControllerProbeRootController(void) {
    return nil;
}

#endif
