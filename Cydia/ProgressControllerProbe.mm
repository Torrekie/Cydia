/* Cydia Refurbished native progress simulator probe.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ProgressControllerProbe.h"

#if TARGET_OS_SIMULATOR

#include "Cydia/ProgressController.h"
#include "Cydia/ProgressData.h"
#include "Cydia/ProgressEvent.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"

#include <cmath>

@interface ProgressController (CydiaProgressProbe)
- (id) initWithProgressModelForTesting:(CydiaProgressViewModel *)model delegate:(id)delegate;
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
    NSTimer *timer_;
    NSString *phase_;
    BOOL dark_;
    BOOL accessibilityLarge_;
    NSUInteger settleTicks_;
}

- (void) dealloc {
    [timer_ invalidate];
}

- (void) applyControlledTraits {
    UIUserInterfaceStyle style(dark_ ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight);
    UITraitCollection *appearance([UITraitCollection traitCollectionWithUserInterfaceStyle:style]);
    UITraitCollection *contentSize([UITraitCollection
        traitCollectionWithPreferredContentSizeCategory:accessibilityLarge_ ?
            UIContentSizeCategoryAccessibilityLarge : UIContentSizeCategoryLarge]);
    UITraitCollection *traits([UITraitCollection traitCollectionWithTraitsFromCollections:
        @[appearance, contentSize]]);
    [self setOverrideTraitCollection:traits forChildViewController:navigation_];
    [navigation_.view setNeedsLayout];
    [navigation_.view layoutIfNeeded];
}

- (void) installControllerForControlledTraits {
    if (navigation_ != nil) {
        [navigation_ willMoveToParentViewController:nil];
        [navigation_.view removeFromSuperview];
        [navigation_ removeFromParentViewController];
        controller_ = nil;
        navigation_ = nil;
    }

    controller_ = [[ProgressController alloc]
        initWithProgressModelForTesting:model_ delegate:self];
    navigation_ = [[UINavigationController alloc] initWithRootViewController:controller_];
    [self addChildViewController:navigation_];
    [self applyControlledTraits];
    navigation_.view.frame = self.view.bounds;
    navigation_.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                        UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:navigation_.view];
    [navigation_ didMoveToParentViewController:self];
    [navigation_.view layoutIfNeeded];
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
        eventWithMessage:@"A deliberately long resolver diagnostic remains readable at accessibility text sizes and wraps without clipping its final words."
                  ofType:@"Error"]);
    [error setPackage:@"runtime:iphoneos-arm64"];
    [model_ addProgressEvent:error];
    phase_ = @"running";
    settleTicks_ = 5;
}

- (void) loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];

    model_ = [[CydiaProgressViewModel alloc]
        initWithLegacyData:[[CydiaProgressData alloc] init]
        packageNameResolver:^NSString *(NSString *identifier) {
            return [identifier isEqualToString:@"runtime:iphoneos-arm64"] ?
                @"Runtime Native" : nil;
        }
        localizer:nil];
    [self installControllerForControlledTraits];
    [self addFixtures];
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
    if ([self consumeMarker:@"cydia-progress-probe-dark"]) {
        dark_ = YES;
        settleTicks_ = 5;
        [self applyControlledTraits];
    }
    if ([self consumeMarker:@"cydia-progress-probe-accessibility"] &&
        ![phase_ isEqualToString:@"complete"]) {
        accessibilityLarge_ = YES;
        phase_ = @"running-accessibility";
        settleTicks_ = 5;
        [self applyControlledTraits];
    }
    if ([self consumeMarker:@"cydia-progress-probe-finish"] &&
        ![phase_ isEqualToString:@"complete"]) {
        accessibilityLarge_ = NO;
        [self applyControlledTraits];
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
    UILabel *title((UILabel *) ProgressProbeView(root, @"cydia.progress.title"));
    UILabel *status((UILabel *) ProgressProbeView(root, @"cydia.progress.status"));
    UIProgressView *progress((UIProgressView *) ProgressProbeView(root, @"cydia.progress.percent"));
    UITableView *table((UITableView *) ProgressProbeView(root, @"cydia.progress.events"));
    [table layoutIfNeeded];

    NSInteger rows([table numberOfRowsInSection:0]);
    UITableViewCell *(^cellAtRow)(NSInteger) = ^UITableViewCell *(NSInteger row) {
        if (row < 0 || row >= rows)
            return nil;
        NSIndexPath *path([NSIndexPath indexPathForRow:row inSection:0]);
        UITableViewCell *cell([table cellForRowAtIndexPath:path]);
        return cell ?: [table.dataSource tableView:table cellForRowAtIndexPath:path];
    };
    UITableViewCell *first(cellAtRow(0));
    UITableViewCell *carriageReturn(cellAtRow(1));
    UITableViewCell *warning(rows <= 2 ? nil : [table cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:2 inSection:0]]);
    UITableViewCell *unknown(rows <= 3 ? nil : [table cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:3 inSection:0]]);
    UITableViewCell *last(rows == 0 ? nil : [table cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:rows - 1 inSection:0]]);
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
    UILabel *unknownMessage((UILabel *) ProgressProbeView(unknown,
        @"cydia.progress.event.message"));
    UILabel *errorMessage((UILabel *) ProgressProbeView(last,
        @"cydia.progress.event.message"));
    CGFloat lastHeight(rows == 0 ? 0 : [table rectForRowAtIndexPath:
        [NSIndexPath indexPathForRow:rows - 1 inSection:0]].size.height);
    CGFloat errorRequiredHeight([errorMessage sizeThatFits:CGSizeMake(
        CGRectGetWidth(errorMessage.bounds), CGFLOAT_MAX)].height);
    BOOL ready(settleTicks_ == 0 && rows == (NSInteger) [events count] &&
               firstMessage != nil && carriageReturnMessage != nil && warningMessage != nil &&
               unknownMessage != nil && errorMessage != nil &&
               [title.text length] != 0 &&
               [status.text isEqualToString:model_.state.statusText]);
    UIColor *expectedWarning([UIColor cydiaColorForRole:CydiaColorRoleWarningLabel
                                          traitCollection:controller_.traitCollection]);
    UIColor *expectedError([UIColor cydiaColorForRole:CydiaColorRoleErrorLabel
                                        traitCollection:controller_.traitCollection]);
    NSString *expectedUnknown([NSString stringWithFormat:UCLocalize("COLON_DELIMITED"),
        unknownEvent.rawType, unknownEvent.displayMessage]);

    NSDictionary *state = @{
        @"ready": @(ready),
        @"phase": phase_ ?: @"starting",
        @"style": dark_ ? @"dark" : @"light",
        @"revision": @(model_.state.revision),
        @"rows": @(rows),
        @"modelEvents": @([events count]),
        @"title": title.text ?: @"",
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
        @"expectedWarningVisibleText": warningEvent.accessibilityLabel ?: @"",
        @"unknownVisibleText": unknownMessage.text ?: @"",
        @"expectedUnknownVisibleText": expectedUnknown ?: @"",
        @"unknownCellAccessibilityLabel": unknown.accessibilityLabel ?: @"",
        @"expectedUnknownAccessibilityLabel": unknownEvent.accessibilityLabel ?: @"",
        @"errorVisibleText": errorMessage.text ?: @"",
        @"expectedErrorVisibleText": lastEvent.accessibilityLabel ?: @"",
        @"warningUsesSemanticColor": @(ProgressProbeColorsEqual(
            warningMessage.textColor, expectedWarning)),
        @"errorUsesSemanticColor": @(ProgressProbeColorsEqual(
            errorMessage.textColor, expectedError)),
        @"lastRowHeight": @((NSInteger) lround(lastHeight)),
        @"progress": @(progress.progress),
        @"progressAccessibilityLabel": progress.accessibilityLabel ?: @"",
        @"progressAccessibilityValue": progress.accessibilityValue ?: @"",
        @"expectedProgressAccessibilityValue": ProgressProbeAccessibilityValue(model_.state),
        @"expectedRunningAccessibilityLabel": UCLocalize("RUNNING"),
        @"expectedCompleteAccessibilityLabel": UCLocalize("COMPLETE"),
        @"cancelTitle": controller_.navigationItem.leftBarButtonItem.title ?: @"",
        @"finishTitle": controller_.navigationItem.rightBarButtonItem.title ?: @"",
        @"expectedFinishTitle": model_.state.finishTitle ?: @"",
        @"titleAdjustsFont": @(title.adjustsFontForContentSizeCategory),
        @"statusAdjustsFont": @(status.adjustsFontForContentSizeCategory),
        @"titlePointSize": @(title.font.pointSize),
        @"statusPointSize": @(status.font.pointSize),
        @"errorPointSize": @(errorMessage.font.pointSize),
        @"statusHidden": @(status.hidden),
        @"statusAlpha": @(status.alpha),
        @"statusFrame": NSStringFromCGRect(status.frame),
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
        @"navigationFrame": NSStringFromCGRect(navigation_.view.frame),
        @"statusBarHidden": @([UIApplication sharedApplication].statusBarHidden),
        @"contentSizeCategory": controller_.traitCollection.preferredContentSizeCategory ?: @"",
        @"expectedDefaultContentSizeCategory": UIContentSizeCategoryLarge,
        @"expectedAccessibilityContentSizeCategory": UIContentSizeCategoryAccessibilityLarge,
        @"backgroundLuminance": @(ProgressProbeLuminance(root.backgroundColor)),
        @"visibleWebViews": @(ProgressProbeEmbeddedBrowserCount(root)),
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
