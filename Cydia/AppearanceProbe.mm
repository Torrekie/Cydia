/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AppearanceProbe.h"

#include "Cydia/Appearance.h"
#include "Cydia/LoadingView.h"
#include "Cydia/PackageViews.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"
#include "CyteKit/WebViewController.h"
#include "CyteKit/extern.h"

#include <UIKit/UIKit.h>
#include <QuartzCore/QuartzCore.h>

#include <cmath>
#include <cstdio>

#if TARGET_OS_SIMULATOR

@class CydiaAppearanceProbeViewController;

@interface CydiaAppearanceProbeWebController : CyteWebViewController
@property(nonatomic, weak) CydiaAppearanceProbeViewController *probeController;
@end

@interface CydiaAppearanceProbeViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (void) scheduleProbeStateWrite;
- (void) webProbeDidLoad;
@end

@interface CydiaAppearanceProbeHostController : UIViewController
- (id) initWithControlledTraits:(BOOL)controlledTraits;
@end

@interface PackageCell (CydiaAppearanceProbe)
- (void) configureAppearanceProbe;
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

    [CyteWebViewController _initialize];
    ProbePalettePassed = ProbePaletteAssertions();

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    BOOL controlledTraits = [[[NSProcessInfo processInfo] arguments]
        containsObject:@"--cydia-appearance-probe-controlled-traits"];
    self.window.rootViewController = [[CydiaAppearanceProbeHostController alloc]
        initWithControlledTraits:controlledTraits];
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

@implementation CydiaAppearanceProbeWebController

- (bool) retainsNetworkActivityIndicator {
    return false;
}

- (bool) usesDocumentAppearanceFallback {
    return true;
}

- (void) didFinishLoading {
    [self.probeController webProbeDidLoad];
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
    UITableViewCell *webCell_;
    CydiaAppearanceProbeWebController *webController_;
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
    resultLabel_.text = @"Cells, UIKit, and web content update live";
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
    [packageCell_ configureAppearanceProbe];

    sectionCell_ = [[SectionCell alloc] initWithFrame:CGRectZero reuseIdentifier:@"AppearanceProbeSection"];
    [sectionCell_ setSection:nil editing:NO];

    Class sourceClass = NSClassFromString(@"SourceCell");
    if (sourceClass != Nil) {
        sourceCell_ = [[sourceClass alloc] initWithFrame:CGRectZero reuseIdentifier:@"AppearanceProbeSource"];
        if ([sourceCell_ respondsToSelector:@selector(setAllSource)])
            [sourceCell_ performSelector:@selector(setAllSource)];
    }

    loadingCell_ = [[UITableViewCell alloc] initWithFrame:CGRectMake(0, 0, 320, 72)
                                           reuseIdentifier:@"AppearanceProbeLoading"];
    loadingCell_.selectionStyle = UITableViewCellSelectionStyleNone;
    loadingView_ = [[CydiaLoadingView alloc] initWithFrame:loadingCell_.contentView.bounds];
    loadingView_.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [loadingCell_.contentView addSubview:loadingView_];

    webCell_ = [[UITableViewCell alloc] initWithFrame:CGRectMake(0, 0, 320, 112)
                                       reuseIdentifier:@"AppearanceProbeWeb"];
    webCell_.selectionStyle = UITableViewCellSelectionStyleNone;
    webController_ = [[CydiaAppearanceProbeWebController alloc] init];
    webController_.probeController = self;
    [self addChildViewController:webController_];
    UIView *webView(webController_.view);
    webView.frame = webCell_.contentView.bounds;
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    webView.userInteractionEnabled = NO;
    [webCell_.contentView addSubview:webView];
    [webController_ didMoveToParentViewController:self];

    NSString *html =
        @"<!doctype html><html><head><meta name='viewport' content='width=device-width'>"
        @"<style>html,body{height:100%;margin:0}body{display:flex;align-items:center;"
        @"justify-content:center;font:600 16px -apple-system;background:#000;color:#fff;"
        @"background-image:-webkit-linear-gradient(#fff,#fff)}</style><script>"
        @"window.cydiaAppearanceEvents=0;"
        @"window.cydiaChildAppearanceEvents=0;"
        @"document.addEventListener('CydiaAppearanceChanged',function(){"
        @"window.cydiaAppearanceEvents++;},false);"
        @"</script></head><body class='pinstripe'>Cyte Web Appearance Event"
        @"<iframe id='appearance-child' style='display:none' srcdoc=\""
        @"<style>html,body{background:#000;color:#fff}</style>"
        @"<script>document.addEventListener('CydiaAppearanceChanged',function(){"
        @"parent.cydiaChildAppearanceEvents++;},false);</script>\"></iframe>"
        @"</body></html>";
    NSString *base64([[html dataUsingEncoding:NSUTF8StringEncoding]
        base64EncodedStringWithOptions:0]);
    NSURL *probeURL([NSURL URLWithString:[@"data:text/html;base64," stringByAppendingString:base64]]);
    [webController_ loadRequest:[NSURLRequest requestWithURL:probeURL]];

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

- (void) webProbeDidLoad {
    [self scheduleProbeStateWrite];
}

- (void) writeProbeState {
    UIUserInterfaceStyle style(self.traitCollection.userInterfaceStyle);
    CyteWebView *webView(webController_.webView);
    NSString *webReady([webView stringByEvaluatingJavaScriptFromString:@"document.readyState"] ?: @"");
    NSString *webStyle([webView stringByEvaluatingJavaScriptFromString:
        @"document.documentElement.getAttribute('data-cydia-appearance')||''"] ?: @"");
    NSString *webEvents([webView stringByEvaluatingJavaScriptFromString:
        @"String(window.cydiaAppearanceEvents||0)"] ?: @"0");
    NSString *webLuminance([webView stringByEvaluatingJavaScriptFromString:
        @"(function(){var c=getComputedStyle(document.body).backgroundColor.match(/\\d+/g);"
        @"return c?String(Math.round((Number(c[0])+Number(c[1])+Number(c[2]))/3)):'-1';})()"] ?: @"-1");
    NSString *webLabelLuminance([webView stringByEvaluatingJavaScriptFromString:
        @"(function(){var c=getComputedStyle(document.body).color.match(/\\d+/g);"
        @"return c?String(Math.round((Number(c[0])+Number(c[1])+Number(c[2]))/3)):'-1';})()"] ?: @"-1");
    NSString *webBackgroundImage([webView stringByEvaluatingJavaScriptFromString:
        @"getComputedStyle(document.body).backgroundImage || ''"] ?: @"");
    NSString *childStyle([webView stringByEvaluatingJavaScriptFromString:
        @"(function(){var f=document.getElementById('appearance-child');return f&&f.contentDocument?"
         "(f.contentDocument.documentElement.getAttribute('data-cydia-appearance')||''):'';})()"] ?: @"");
    NSString *childEvents([webView stringByEvaluatingJavaScriptFromString:
        @"String(window.cydiaChildAppearanceEvents||0)"] ?: @"0");
    NSString *childLuminance([webView stringByEvaluatingJavaScriptFromString:
        @"(function(){var f=document.getElementById('appearance-child');if(!f||!f.contentWindow)return'-1';"
         "var c=f.contentWindow.getComputedStyle(f.contentDocument.body).backgroundColor.match(/\\d+/g);"
         "return c?String(Math.round((Number(c[0])+Number(c[1])+Number(c[2]))/3)):'-1';})()"] ?: @"-1");
    NSDictionary *state = @{
        @"style": style == UIUserInterfaceStyleDark ? @"dark" : @"light",
        @"updates": @(appearanceUpdateCount_),
        @"paletteAssertions": @(ProbePalettePassed),
        @"packageBackgroundLuminance": @((NSInteger) lround(ProbeLuminance(packageCell_.content.backgroundColor) * 1000)),
        @"sectionBackgroundLuminance": @((NSInteger) lround(ProbeLuminance(sectionCell_.content.backgroundColor) * 1000)),
        @"sourceBackgroundLuminance": @((NSInteger) lround(ProbeLuminance(sourceCell_.content.backgroundColor) * 1000)),
        @"loadingBackgroundLuminance": @((NSInteger) lround(ProbeLuminance(loadingView_.backgroundColor) * 1000)),
        @"webReady": @([webReady isEqualToString:@"complete"]),
        @"webStyle": webStyle,
        @"webAppearanceEvents": @([webEvents integerValue]),
        @"webBackgroundLuminance": @([webLuminance integerValue]),
        @"webLabelLuminance": @([webLabelLuminance integerValue]),
        @"webBackgroundImage": webBackgroundImage,
        @"webChildStyle": childStyle,
        @"webChildAppearanceEvents": @([childEvents integerValue]),
        @"webChildBackgroundLuminance": @([childLuminance integerValue]),
    };
    [state writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"cydia-appearance-probe.plist"] atomically:YES];
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void) tableView;
    (void) section;
    return 5;
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
        default: return 112;
    }
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void) tableView;
    switch (indexPath.row) {
        case 0: return packageCell_;
        case 1: return sectionCell_;
        case 2: return sourceCell_;
        case 3: return loadingCell_;
        default: return webCell_;
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
