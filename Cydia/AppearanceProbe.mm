/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AppearanceProbe.h"

#include "Cydia/Appearance.h"
#include "Cydia/AppState.h"
#include "Cydia/ConfirmationControllerProbe.h"
#include "Cydia/HomeTableAppearance.h"
#include "Cydia/LoadingView.h"
#include "Cydia/PackageViews.h"
#include "Cydia/PackageDetailControllerProbe.h"
#include "Cydia/ProgressControllerProbe.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"
#include "CyteKit/extern.h"

#include <UIKit/UIKit.h>
#include <QuartzCore/QuartzCore.h>

#include <cmath>
#include <cstdio>

#if defined(CYDIA_APPEARANCE_SIMULATOR_PROBE)
#if defined(CYDIA_HOME_SIMULATOR_PROBE)
#include "Cydia/HomeControllerProbe.h"
#endif
#if defined(CYDIA_EXTERNAL_URL_SIMULATOR_PROBE)
#include "tests/simulator/ExternalURLControllerProbe.h"
#endif
#if defined(CYDIA_ERROR_VIEW_SIMULATOR_PROBE)
#include "tests/simulator/ErrorViewRuntimeProbe.h"
#endif

@class CydiaAppearanceProbeViewController;

@interface CydiaAppearanceProbeViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (void) scheduleProbeStateWrite;
@end

@interface CydiaAppearanceProbeHostController : UIViewController
- (id) initWithControlledTraits:(BOOL)controlledTraits;
@end

@interface CydiaAppearanceProbeApplication : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

static CGFloat ProbeLuminance(UIColor *color) {
    CGFloat red(0), green(0), blue(0), alpha(0);
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white(0);
        if (![color getWhite:&white alpha:&alpha])
            return -1;
        red = green = blue = white;
    }
    return (red + green + blue) / 3.0;
}

static BOOL ProbePaletteAssertions(void) {
    UITraitCollection *light([UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]);
    UITraitCollection *dark([UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]);

    UIColor *lightBackground([UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:light]);
    UIColor *darkBackground([UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:dark]);
    UIColor *lightLabel([UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:light]);
    UIColor *darkLabel([UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:dark]);

    BOOL distinct = fabs(ProbeLuminance(lightBackground) - ProbeLuminance(darkBackground)) > 0.25 &&
                    fabs(ProbeLuminance(lightLabel) - ProbeLuminance(darkLabel)) > 0.25;
    NSLog(@"CydiaAppearanceProbe palette light/dark resolution: %@", distinct ? @"PASS" : @"FAIL");
    return distinct;
}

static BOOL ProbePalettePassed;

static BOOL ProbeTransparent(UIColor *color) {
    return color == nil || CGColorGetAlpha(color.CGColor) < 0.01;
}

static UIColor *ProbeCellSurface(UITableViewCell *cell) {
    UIColor *background(cell.backgroundView.backgroundColor);
    return ProbeTransparent(background) ? cell.backgroundColor : background;
}

/* Rasterize only in memory. Both samples lie below the content and arrow so
 * text/icon differences cannot masquerade as a whole-row press background. */
static CGFloat ProbeCellPixel(UITableViewCell *cell, CGPoint point) {
    unsigned char pixel[4] = {};
    CGColorSpaceRef space(CGColorSpaceCreateDeviceRGB());
    CGContextRef context(CGBitmapContextCreate(pixel, 1, 1, 8, 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(space);
    if (context == NULL)
        return -1;
    CGContextTranslateCTM(context, -point.x, -point.y);
    [cell.layer renderInContext:context];
    CGContextRelease(context);
    return pixel[3] < 250 ? -1 : (pixel[0] + pixel[1] + pixel[2]) / 765.0;
}

static BOOL ProbeCellPress(UITableViewCell *cell) {
    if (cell == nil || cell.selectionStyle == UITableViewCellSelectionStyleNone)
        return NO;
    const BOOL oldHighlighted(cell.isHighlighted), oldSelected(cell.isSelected);
    const BOOL custom([cell isKindOfClass:[CyteTableViewCell class]]);
    __block BOOL passed(YES);
    [UIView performWithoutAnimation:^{
        [cell setHighlighted:NO animated:NO];
        [cell setSelected:NO animated:NO];
        [cell layoutIfNeeded];
        const CGRect bounds(cell.bounds);
        const CGFloat y(CGRectGetHeight(bounds) - 4);
        const CGPoint center(CGPointMake(CGRectGetMidX(cell.contentView.frame), y));
        const CGPoint trailing(CGPointMake(CGRectGetWidth(bounds) - 8, y));
        const CGFloat normalCenter(ProbeCellPixel(cell, center));
        const CGFloat normalTrailing(ProbeCellPixel(cell, trailing));
        passed = normalCenter >= 0 && normalTrailing >= 0 &&
            ProbeTransparent(cell.contentView.backgroundColor);
        if (custom) {
            CyteTableViewCell *drawingCell((CyteTableViewCell *)cell);
            passed = passed && !drawingCell.content.opaque &&
                ProbeTransparent(drawingCell.content.backgroundColor) && !drawingCell.highlighted;
        }

        [cell setHighlighted:YES animated:NO];
        [cell layoutIfNeeded];
        const CGFloat pressedCenter(ProbeCellPixel(cell, center));
        const CGFloat pressedTrailing(ProbeCellPixel(cell, trailing));
        passed = passed && cell.isHighlighted && !cell.isSelected &&
            pressedCenter >= 0 && pressedTrailing >= 0 &&
            fabs(normalCenter - pressedCenter) > 0.02 &&
            fabs(normalTrailing - pressedTrailing) > 0.02 &&
            fabs(pressedCenter - pressedTrailing) < 0.03;
        if (custom)
            passed = passed && [(CyteTableViewCell *)cell highlighted];

        [cell setSelected:YES animated:NO];
        [cell setHighlighted:NO animated:NO];
        [cell layoutIfNeeded];
        const CGFloat selectedCenter(ProbeCellPixel(cell, center));
        const CGFloat selectedTrailing(ProbeCellPixel(cell, trailing));
        passed = passed && !cell.isHighlighted && cell.isSelected &&
            selectedCenter >= 0 && selectedTrailing >= 0 &&
            fabs(normalCenter - selectedCenter) > 0.02 &&
            fabs(normalTrailing - selectedTrailing) > 0.02 &&
            fabs(selectedCenter - selectedTrailing) < 0.03;
        if (custom)
            passed = passed && [(CyteTableViewCell *)cell highlighted];

        [cell setSelected:NO animated:NO];
        [cell layoutIfNeeded];
        passed = passed && !cell.isHighlighted && !cell.isSelected &&
            fabs(normalCenter - ProbeCellPixel(cell, center)) < 0.01 &&
            fabs(normalTrailing - ProbeCellPixel(cell, trailing)) < 0.01;
        if (custom)
            passed = passed && ![(CyteTableViewCell *)cell highlighted];
        if (!passed)
            NSLog(@"CydiaAppearanceProbe %@ press samples normal %.3f/%.3f, highlighted %.3f/%.3f, selected %.3f/%.3f; transparent content %d",
                NSStringFromClass(cell.class), normalCenter, normalTrailing, pressedCenter,
                pressedTrailing, selectedCenter, selectedTrailing,
                ProbeTransparent(cell.contentView.backgroundColor));
        [cell setSelected:oldSelected animated:NO];
        [cell setHighlighted:oldHighlighted animated:NO];
        [cell layoutIfNeeded];
    }];
    return passed;
}

static void EnsureProbeMetrics(void) {
    if (ScreenScale_ <= 0)
        ScreenScale_ = [UIScreen mainScreen].scale;
    if (ScreenScale_ <= 0)
        ScreenScale_ = 1;
}

@implementation CydiaAppearanceProbeApplication

- (BOOL) application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void) application;
    (void) options;

    Font12_ = [UIFont systemFontOfSize:12];
    Font12Bold_ = [UIFont boldSystemFontOfSize:12];
    Font14_ = [UIFont systemFontOfSize:14];
    Font18_ = [UIFont systemFontOfSize:18];
    Font18Bold_ = [UIFont boldSystemFontOfSize:18];
    Font22Bold_ = [UIFont boldSystemFontOfSize:22];
    Elision_ = UCLocalize("ELISION");
    EnsureProbeMetrics();

    /* The appearance entry point returns before MobileCydia's normal
     * bootstrap. Initialize shared platform fields (notably Machine_) so
     * the native Home footer is exercised with production values. */
    CyteInitialize([NSString stringWithFormat:@"Cydia/%@", Cydia_ ?: @""]);
    if ([UniqueID_ length] == 0) {
        /* MobileCydia normally obtains this through MobileGestalt before
         * UIApplicationMain. The simulator probe has no such bootstrap;
         * identifierForVendor is an equivalent local-only fixture value. */
        UniqueID_ = [UIDevice currentDevice].identifierForVendor.UUIDString ?:
            [[NSUUID UUID] UUIDString];
    }

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    BOOL progressProbe = [[[NSProcessInfo processInfo] arguments]
        containsObject:@"--cydia-progress-probe"];
    BOOL confirmationProbe = [[[NSProcessInfo processInfo] arguments]
        containsObject:@"--cydia-confirmation-probe"];
    BOOL packageDetailProbe = [[[NSProcessInfo processInfo] arguments]
        containsObject:@"--cydia-package-detail-probe"];
#if defined(CYDIA_HOME_SIMULATOR_PROBE)
    BOOL homeProbe = [[[NSProcessInfo processInfo] arguments]
        containsObject:@"--cydia-home-probe"];
#endif
#if defined(CYDIA_EXTERNAL_URL_SIMULATOR_PROBE)
    BOOL externalURLProbe = [[[NSProcessInfo processInfo] arguments]
        containsObject:@"--cydia-external-url-probe"];
#endif
#if defined(CYDIA_ERROR_VIEW_SIMULATOR_PROBE)
    BOOL errorViewProbe = [[[NSProcessInfo processInfo] arguments]
        containsObject:@"--cydia-native-error-probe"];
#endif
    BOOL controlledTraits = [[[NSProcessInfo processInfo] arguments]
        containsObject:@"--cydia-appearance-probe-controlled-traits"];
    UIViewController *rootController(nil);
#if defined(CYDIA_EXTERNAL_URL_SIMULATOR_PROBE)
    if (externalURLProbe)
        rootController = CydiaExternalURLControllerProbeRootController();
#endif
#if defined(CYDIA_ERROR_VIEW_SIMULATOR_PROBE)
    if (rootController == nil && errorViewProbe)
        rootController = CydiaErrorViewRuntimeProbeRootController();
#endif
#if defined(CYDIA_HOME_SIMULATOR_PROBE)
    if (rootController == nil && homeProbe)
        rootController = CydiaHomeControllerProbeRootController();
#endif
    if (rootController == nil && packageDetailProbe)
        rootController = CydiaPackageDetailControllerProbeRootController();
    if (rootController == nil && confirmationProbe)
        rootController = CydiaConfirmationControllerProbeRootController();
    if (rootController == nil && progressProbe)
        rootController = CydiaProgressControllerProbeRootController();
    if (rootController == nil) {
        ProbePalettePassed = ProbePaletteAssertions();
        rootController = [[CydiaAppearanceProbeHostController alloc]
            initWithControlledTraits:controlledTraits];
    }
    self.window.rootViewController = rootController;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

@implementation CydiaAppearanceProbeHostController {
    BOOL controlledTraits_;
    CydiaAppearanceProbeViewController *probeController_;
    NSTimer *traitTimer_;
}

- (UIStatusBarStyle) preferredStatusBarStyle {
    return probeController_.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ?
        UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}

- (id) initWithControlledTraits:(BOOL)controlledTraits {
    if ((self = [super init]) != nil)
        controlledTraits_ = controlledTraits;
    return self;
}

- (void) loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    probeController_ = [[CydiaAppearanceProbeViewController alloc] init];
    [self addChildViewController:probeController_];
    probeController_.view.frame = self.view.bounds;
    probeController_.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:probeController_.view];
    [probeController_ didMoveToParentViewController:self];

    if (controlledTraits_) {
        [self setOverrideTraitCollection:
            [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]
            forChildViewController:probeController_];
        traitTimer_ = [NSTimer scheduledTimerWithTimeInterval:0.1
            target:self selector:@selector(checkControlledTraitTrigger:)
            userInfo:nil repeats:YES];
    }
}

- (void) checkControlledTraitTrigger:(NSTimer *)timer {
    (void) timer;
    NSString *path([NSTemporaryDirectory()
        stringByAppendingPathComponent:@"cydia-appearance-probe-dark"]);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [traitTimer_ invalidate];
    traitTimer_ = nil;
    [self setOverrideTraitCollection:
        [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]
        forChildViewController:probeController_];
    [self setNeedsStatusBarAppearanceUpdate];
}

@end

@implementation CydiaAppearanceProbeViewController {
    UITableView *tableView_;
    UIView *headerView_;
    UILabel *titleLabel_;
    UILabel *styleLabel_;
    UILabel *resultLabel_;
    UIView *sectionHeaderView_;
    UILabel *sectionHeaderLabel_;
    PackageCell *packageCell_;
    SectionCell *sectionCell_;
    CyteTableViewCell *sourceCell_;
    UITableViewCell *loadingCell_;
    CydiaLoadingView *loadingView_;
    UITableViewCell *nativeSurfaceCell_;
    UITableViewCell *selectableSurfaceCell_;
    UILabel *nativeSurfaceLabel_;
    NSArray<UIView *> *swatches_;
    NSArray<UILabel *> *swatchLabels_;
    NSUInteger appearanceUpdateCount_;
}

- (void) loadView {
    EnsureProbeMetrics();
    tableView_ = [[UITableView alloc] initWithFrame:[UIScreen mainScreen].bounds style:UITableViewStylePlain];
    tableView_.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableView_.dataSource = self;
    tableView_.delegate = self;
    tableView_.sectionHeaderHeight = 44;
    tableView_.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    self.view = tableView_;

    sectionHeaderView_ = [[UIView alloc] init];
    sectionHeaderLabel_ = [[UILabel alloc] init];
    sectionHeaderLabel_.font = Font14_;
    sectionHeaderLabel_.text = @"Real Cydia appearance surfaces";
    sectionHeaderLabel_.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [sectionHeaderView_ addSubview:sectionHeaderLabel_];

    headerView_ = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView_.bounds.size.width, 278)];

    titleLabel_ = [[UILabel alloc] init];
    titleLabel_.text = @"Cydia Color Compatibility Test";
    titleLabel_.font = Font22Bold_;
    titleLabel_.textColor = UIColor.cydiaLabelColor;
    [headerView_ addSubview:titleLabel_];

    styleLabel_ = [[UILabel alloc] init];
    styleLabel_.font = Font14_;
    styleLabel_.textColor = UIColor.cydiaSecondaryLabelColor;
    [headerView_ addSubview:styleLabel_];

    resultLabel_ = [[UILabel alloc] init];
    resultLabel_.font = Font12_;
    resultLabel_.textColor = UIColor.cydiaSecondaryLabelColor;
    resultLabel_.text = @"Cells and UIKit update live";
    [headerView_ addSubview:resultLabel_];

    NSArray *roles = @[
        @(CydiaColorRoleBackground),
        @(CydiaColorRoleGroupedBackground),
        @(CydiaColorRoleInstallingBackground),
        @(CydiaColorRoleRemovingBackground),
    ];
    NSArray *roleNames = @[@"Background", @"Grouped Background", @"Installing Queue", @"Removing Queue"];
    NSMutableArray *swatches([NSMutableArray arrayWithCapacity:[roles count]]);
    NSMutableArray *swatchLabels([NSMutableArray arrayWithCapacity:[roles count]]);
    for (NSUInteger index(0); index != [roles count]; ++index) {
        NSNumber *role([roles objectAtIndex:index]);
        UIView *swatch([[UIView alloc] init]);
        swatch.layer.cornerRadius = 6;
        swatch.layer.borderWidth = 1;
        swatch.layer.borderColor = UIColor.cydiaSeparatorColor.CGColor;
        swatch.backgroundColor = [UIColor cydiaColorForRole:(CydiaColorRole) [role unsignedIntegerValue]];
        UILabel *label([[UILabel alloc] init]);
        label.text = [roleNames objectAtIndex:index];
        label.font = Font12Bold_;
        [swatch addSubview:label];
        [headerView_ addSubview:swatch];
        [swatches addObject:swatch];
        [swatchLabels addObject:label];
    }
    swatches_ = [swatches copy];
    swatchLabels_ = [swatchLabels copy];
    tableView_.tableHeaderView = headerView_;

    packageCell_ = [[PackageCell alloc] init];
    [packageCell_ setLibraryItemName:@"Semantic Package Row"
        description:@"Already-visible custom drawing updates live"
        source:@"Cydia Appearance Probe" architectureCaption:nil
        icon:[UIImage imageNamed:@"folder.png"] price:@"$1.99" unavailable:NO];

    sectionCell_ = [[SectionCell alloc] initWithFrame:CGRectZero reuseIdentifier:@"AppearanceProbeSection"];
    [sectionCell_ setSection:nil editing:NO];

    Class sourceClass = NSClassFromString(@"SourceCell");
    if (sourceClass != Nil) {
        sourceCell_ = [[sourceClass alloc] initWithFrame:CGRectZero reuseIdentifier:@"AppearanceProbeSource"];
        if ([sourceCell_ respondsToSelector:@selector(setAllSource)])
            [sourceCell_ performSelector:@selector(setAllSource)];
        sourceCell_.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    loadingCell_ = [[UITableViewCell alloc] initWithFrame:CGRectMake(0, 0, 320, 72)
                                           reuseIdentifier:@"AppearanceProbeLoading"];
    loadingCell_.selectionStyle = UITableViewCellSelectionStyleNone;
    loadingView_ = [[CydiaLoadingView alloc] initWithFrame:loadingCell_.contentView.bounds];
    loadingView_.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [loadingCell_.contentView addSubview:loadingView_];

    nativeSurfaceCell_ = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault
        reuseIdentifier:@"AppearanceProbeNativeSurface"];
    nativeSurfaceCell_.selectionStyle = UITableViewCellSelectionStyleNone;
    nativeSurfaceCell_.accessibilityIdentifier = @"appearance.native-surface";
    nativeSurfaceLabel_ = nativeSurfaceCell_.textLabel;
    nativeSurfaceLabel_.text = @"Native UIKit Appearance Surface";
    nativeSurfaceLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    nativeSurfaceLabel_.adjustsFontForContentSizeCategory = YES;
    nativeSurfaceLabel_.numberOfLines = 0;
    nativeSurfaceLabel_.accessibilityIdentifier = @"appearance.native-surface.label";

    selectableSurfaceCell_ = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AppearanceProbeSelectableSurface"];
    selectableSurfaceCell_.textLabel.text = @"Native UIKit Selectable Surface";
    selectableSurfaceCell_.selectionStyle = UITableViewCellSelectionStyleDefault;
    selectableSurfaceCell_.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    [tableView_ reloadData];
    [self updateProbeAppearance];
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    EnsureProbeMetrics();

    UIEdgeInsets safe(tableView_.safeAreaInsets);
    CGFloat width(tableView_.bounds.size.width);
    CGFloat left(safe.left + 18);
    CGFloat contentWidth(width - safe.left - safe.right - 36);
    CGFloat y(12);
    titleLabel_.frame = CGRectMake(left, y, contentWidth, 28);
    y += 34;
    styleLabel_.frame = CGRectMake(left, y, contentWidth, 22);
    y += 24;
    resultLabel_.frame = CGRectMake(left, y, contentWidth, 20);
    y += 28;

    for (NSUInteger index(0); index != [swatches_ count]; ++index) {
        UIView *swatch([swatches_ objectAtIndex:index]);
        swatch.frame = CGRectMake(left, y, contentWidth, 32);
        UILabel *label([swatchLabels_ objectAtIndex:index]);
        label.frame = CGRectInset(swatch.bounds, 10, 0);
        y += 38;
    }

    CGRect headerFrame(headerView_.frame);
    headerFrame.size.width = width;
    headerFrame.size.height = y + 8;
    if (!CGRectEqualToRect(headerView_.frame, headerFrame)) {
        headerView_.frame = headerFrame;
        tableView_.tableHeaderView = headerView_;
    }
}

- (void) updateProbeAppearance {
    ++appearanceUpdateCount_;
    UIUserInterfaceStyle style(self.traitCollection.userInterfaceStyle);
    UIColor *labelColor([UIColor cydiaColorForRole:CydiaColorRoleLabel
                                    traitCollection:self.traitCollection]);
    UIColor *secondaryLabelColor([UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                             traitCollection:self.traitCollection]);
    UIColor *groupedBackgroundColor([UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                                traitCollection:self.traitCollection]);
    UIColor *separatorColor([UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                        traitCollection:self.traitCollection]);
    styleLabel_.text = style == UIUserInterfaceStyleDark ? @"Trait: dark" : @"Trait: light (iOS 12 fallback when unavailable)";
    styleLabel_.textColor = secondaryLabelColor;
    resultLabel_.textColor = secondaryLabelColor;
    sectionHeaderView_.backgroundColor = groupedBackgroundColor;
    sectionHeaderLabel_.textColor = secondaryLabelColor;
    titleLabel_.textColor = labelColor;
    tableView_.backgroundColor = groupedBackgroundColor;
    headerView_.backgroundColor = groupedBackgroundColor;
    styleLabel_.backgroundColor = groupedBackgroundColor;
    resultLabel_.backgroundColor = groupedBackgroundColor;
    nativeSurfaceCell_.backgroundColor = [UIColor
        cydiaColorForRole:CydiaColorRoleBackground
        traitCollection:self.traitCollection];
    nativeSurfaceCell_.contentView.backgroundColor =
        nativeSurfaceCell_.backgroundColor;
    nativeSurfaceLabel_.textColor = labelColor;
    HomeApplyCellSurface(selectableSurfaceCell_, CydiaColorRoleCellBackground, self.traitCollection);
    selectableSurfaceCell_.textLabel.textColor = labelColor;
    for (NSUInteger index(0); index != [swatches_ count]; ++index) {
        UIView *swatch([swatches_ objectAtIndex:index]);
        CydiaColorRole role = index == 0 ? CydiaColorRoleBackground :
            index == 1 ? CydiaColorRoleGroupedBackground :
            index == 2 ? CydiaColorRoleInstallingBackground : CydiaColorRoleRemovingBackground;
        swatch.backgroundColor = [UIColor cydiaColorForRole:role traitCollection:self.traitCollection];
        swatch.layer.borderColor = separatorColor.CGColor;
        UILabel *label([swatchLabels_ objectAtIndex:index]);
        label.textColor = labelColor;
    }

    [self scheduleProbeStateWrite];
}

- (void) scheduleProbeStateWrite {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self writeProbeState];
    });
}

- (void) writeProbeState {
    [tableView_ layoutIfNeeded];
    BOOL pressAssertions(nativeSurfaceCell_.selectionStyle == UITableViewCellSelectionStyleNone);
    for (UITableViewCell *cell in @[packageCell_, sectionCell_, sourceCell_ ?: (id)[NSNull null], selectableSurfaceCell_]) {
        if (![cell isKindOfClass:[UITableViewCell class]]) {
            pressAssertions = NO;
            continue;
        }
        /* A small phone may not yet have displayed the last row. Give that
         * same real cell usable geometry without scrolling the table. */
        const CGRect originalFrame(cell.frame);
        const BOOL needsGeometry(CGRectGetWidth(cell.bounds) < 44 || CGRectGetHeight(cell.bounds) < 44);
        if (needsGeometry) {
            CGFloat height(cell == sectionCell_ ? 50 : cell == sourceCell_ ? 58 : 74);
            cell.frame = CGRectMake(0, 0, CGRectGetWidth(tableView_.bounds), height);
        }
        BOOL passed(ProbeCellPress(cell));
        if (needsGeometry)
            cell.frame = originalFrame;
        pressAssertions = pressAssertions && passed;
        NSLog(@"CydiaAppearanceProbe %@ whole-row press: %@", NSStringFromClass(cell.class),
            passed ? @"PASS" : @"FAIL");
    }
    UIUserInterfaceStyle style(self.traitCollection.userInterfaceStyle);
    NSDictionary *state = @{
        @"style": style == UIUserInterfaceStyleDark ? @"dark" : @"light",
        @"updates": @(appearanceUpdateCount_),
        @"paletteAssertions": @(ProbePalettePassed),
        @"pressAssertions": @(pressAssertions),
        @"packageBackgroundLuminance": @((NSInteger) lround(ProbeLuminance(ProbeCellSurface(packageCell_)) * 1000)),
        @"sectionBackgroundLuminance": @((NSInteger) lround(ProbeLuminance(ProbeCellSurface(sectionCell_)) * 1000)),
        @"sourceBackgroundLuminance": @((NSInteger) lround(ProbeLuminance(ProbeCellSurface(sourceCell_)) * 1000)),
        @"loadingBackgroundLuminance": @((NSInteger) lround(ProbeLuminance(loadingView_.backgroundColor) * 1000)),
        @"nativeSurfaceReady": @(nativeSurfaceLabel_.superview != nil &&
            [nativeSurfaceLabel_.text length] != 0),
        @"nativeSurfaceIdentifier":
            nativeSurfaceCell_.accessibilityIdentifier ?: @"",
        @"nativeSurfaceBackgroundLuminance": @((NSInteger) lround(
            ProbeLuminance(nativeSurfaceCell_.contentView.backgroundColor) * 1000)),
        @"nativeSurfaceLabelLuminance": @((NSInteger) lround(
            ProbeLuminance(nativeSurfaceLabel_.textColor) * 1000)),
    };
    [state writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"cydia-appearance-probe.plist"] atomically:YES];
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void) tableView;
    (void) section;
    return 6;
}

- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void) tableView;
    (void) section;
    return 44;
}

- (UIView *) tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void) tableView;
    (void) section;
    CGFloat width(tableView.bounds.size.width);
    sectionHeaderView_.frame = CGRectMake(0, 0, width, 44);
    sectionHeaderLabel_.frame = CGRectMake(18, 0, width - 36, 44);
    return sectionHeaderView_;
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void) tableView;
    switch (indexPath.row) {
        case 0: return 74;
        case 1: return 50;
        case 2: return 58;
        case 3: return 72;
        default: return 72;
    }
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void) tableView;
    switch (indexPath.row) {
        case 0: return packageCell_;
        case 1: return sectionCell_;
        case 2: return sourceCell_;
        case 3: return loadingCell_;
        case 4: return nativeSurfaceCell_;
        default: return selectableSurfaceCell_;
    }
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection))
        [self updateProbeAppearance];
}

@end

int CydiaAppearanceProbeMain(int argc, char *argv[]) {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([CydiaAppearanceProbeApplication class]));
}

#endif
