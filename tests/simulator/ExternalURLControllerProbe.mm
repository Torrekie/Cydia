/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "tests/simulator/ExternalURLControllerProbe.h"

#if TARGET_OS_SIMULATOR && defined(CYDIA_EXTERNAL_URL_SIMULATOR_PROBE)

#include "Cydia/ExternalURLController.h"
#include "Cydia/UIColor+Cydia.h"
#include "Cydia/UIRouteContext.h"

#import <SafariServices/SafariServices.h>

#include <cmath>
#include <unistd.h>

@interface ExternalURLController (CydiaExternalURLProbePrivate)
- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller;
@end

namespace {

NSString *ProbeEnvironment(NSString *key) {
    return [[[NSProcessInfo processInfo] environment] objectForKey:key] ?: @"";
}

NSUInteger CountViewsOfClassNamed(UIView *root, NSString *name) {
    if (root == nil)
        return 0;
    NSUInteger count([NSStringFromClass([root class]) isEqualToString:name] ? 1 : 0);
    for (UIView *child in root.subviews)
        count += CountViewsOfClassNamed(child, name);
    return count;
}

NSInteger ProbeLuminance(UIColor *color) {
    CGFloat red(0.0), green(0.0), blue(0.0), alpha(0.0), white(0.0);
    if ([color getRed:&red green:&green blue:&blue alpha:&alpha])
        return (NSInteger)std::lround(
            (0.2126 * red + 0.7152 * green + 0.0722 * blue) * 255.0);
    if ([color getWhite:&white alpha:&alpha])
        return (NSInteger)std::lround(white * 255.0);
    return -1;
}

BOOL ViewFitsSuperview(UIView *view) {
    if (view == nil || view.superview == nil || CGRectIsEmpty(view.bounds))
        return NO;
    CGRect frame([view convertRect:view.bounds toView:view.superview]);
    return CGRectContainsRect(CGRectInset(view.superview.bounds, -1.0, -1.0), frame);
}

CGFloat VisibleHeightInWindow(UIView *view) {
    UIWindow *window(view.window);
    if (view == nil || window == nil || view.hidden || view.alpha <= 0.0)
        return 0.0;
    CGRect frame([view convertRect:view.bounds toView:window]);
    CGRect visible(CGRectIntersection(window.bounds, frame));
    return CGRectIsNull(visible) || CGRectIsEmpty(visible) ? 0.0 :
        CGRectGetHeight(visible);
}

void AppendAccessibility(UIView *view, NSMutableArray *items) {
    if (view == nil)
        return;
    NSString *identifier(view.accessibilityIdentifier ?: @"");
    NSString *label(view.accessibilityLabel ?: @"");
    if ([identifier length] != 0 || [label length] != 0) {
        [items addObject:@{
            @"class": NSStringFromClass([view class]),
            @"identifier": identifier,
            @"label": label,
            @"frame": NSStringFromCGRect([view convertRect:view.bounds toView:nil]),
        }];
    }
    for (UIView *child in view.subviews)
        AppendAccessibility(child, items);
}

} // namespace


@interface CydiaExternalURLProbeHostController : UIViewController
@end

@implementation CydiaExternalURLProbeHostController {
    ExternalURLController *controller_;
    UINavigationController *navigation_;
    BOOL dark_;
    BOOL accessibilityLarge_;
    NSUInteger settleTicks_;
    NSUInteger safariPresentationCount_;
    BOOL previouslyPresented_;
}

- (NSString *)markerPath:(NSString *)name {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

- (BOOL)consumeMarker:(NSString *)name {
    NSString *path([self markerPath:name]);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return NO;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return YES;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return dark_ ? UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSURL *routeURL([NSURL URLWithString:
        @"cydia://url/https%3A%2F%2Fexample.com%2Fcydia-external-runtime%3Fx%3D1%23top"]);
    NSError *error(nil);
    CydiaUIRouteDescriptor *descriptor(CydiaUIParseRouteURL(routeURL, &error));
    NSAssert(descriptor != nil && error == nil, @"external route fixture parses");
    controller_ = [[ExternalURLController alloc] initWithRouteDescriptor:descriptor];
    NSAssert(controller_ != nil, @"external route fixture creates controller");
    navigation_ = [[UINavigationController alloc] initWithRootViewController:controller_];
    [self addChildViewController:navigation_];
    navigation_.view.frame = self.view.bounds;
    navigation_.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:navigation_.view];
    [navigation_ didMoveToParentViewController:self];
    [self applyTraits];
    settleTicks_ = 6;
    [self performSelector:@selector(probeTick) withObject:nil afterDelay:0.2];
}

- (void)applyTraits {
    UITraitCollection *style([UITraitCollection
        traitCollectionWithUserInterfaceStyle:dark_ ?
            UIUserInterfaceStyleDark : UIUserInterfaceStyleLight]);
    UITraitCollection *size([UITraitCollection
        traitCollectionWithPreferredContentSizeCategory:accessibilityLarge_ ?
            UIContentSizeCategoryAccessibilityLarge : UIContentSizeCategoryLarge]);
    [self setOverrideTraitCollection:[UITraitCollection
        traitCollectionWithTraitsFromCollections:@[style, size]]
        forChildViewController:navigation_];
    [navigation_.view setNeedsLayout];
    [navigation_.view layoutIfNeeded];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)probeTick {
    SFSafariViewController *safari([controller_.presentedViewController
        isKindOfClass:[SFSafariViewController class]] ?
        (SFSafariViewController *)controller_.presentedViewController : nil);
    BOOL presented(safari != nil);
    if (presented && !previouslyPresented_)
        ++safariPresentationCount_;
    previouslyPresented_ = presented;

    if ([self consumeMarker:@"cydia-external-url-probe-dismiss"] && safari != nil) {
        [controller_ safariViewControllerDidFinish:safari];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-external-url-probe-dark"]) {
        dark_ = YES;
        accessibilityLarge_ = NO;
        [self applyTraits];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-external-url-probe-accessibility"]) {
        dark_ = YES;
        accessibilityLarge_ = YES;
        [self applyTraits];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-external-url-probe-retry"]) {
        [controller_ retryButtonClicked];
        settleTicks_ = 5;
    }

    if (settleTicks_ != 0)
        --settleTicks_;
    [self writeState];
    [self performSelector:@selector(probeTick) withObject:nil afterDelay:0.2];
}

- (void)writeState {
    UIViewController *presented(controller_.presentedViewController);
    NSMutableArray *accessibility([NSMutableArray array]);
    AppendAccessibility(navigation_.view, accessibility);
    if (presented.view != nil)
        AppendAccessibility(presented.view, accessibility);

    BOOL safari([presented isKindOfClass:[SFSafariViewController class]]);
    UILabel *status([controller_ valueForKey:@"statusLabel"]);
    UILabel *detail([controller_ valueForKey:@"detailLabel"]);
    UIButton *retry([controller_ valueForKey:@"retryButton"]);
    UINavigationBar *navigationBar(navigation_.navigationBar);
    NSString *navigationTitle(navigationBar.topItem.title ?: @"");
    BOOL ready(settleTicks_ == 0 &&
        ((safari && controller_.state == CydiaExternalURLControllerStatePresented) ||
         (!safari && (controller_.state == CydiaExternalURLControllerStateComplete ||
                      controller_.state == CydiaExternalURLControllerStateFailed))));
    NSDictionary *state(@{
        @"schema": @2,
        @"fixtureVersion": @"native-external-url-v2",
        @"buildEvidence": @{
            @"sourceHEAD": ProbeEnvironment(@"CYDIA_PROBE_SOURCE_HEAD"),
            @"binarySHA256": ProbeEnvironment(@"CYDIA_PROBE_BINARY_SHA256"),
            @"bundleShortVersion": ProbeEnvironment(@"CYDIA_PROBE_BUNDLE_SHORT_VERSION"),
            @"bundleVersion": ProbeEnvironment(@"CYDIA_PROBE_BUNDLE_VERSION"),
        },
        @"ready": @(ready),
        @"processID": @((int)getpid()),
        @"systemVersion": [UIDevice currentDevice].systemVersion,
        @"style": dark_ ? @"dark" : @"light",
        @"contentSize": accessibilityLarge_ ? @"accessibility-large" : @"large",
        @"controllerClass": NSStringFromClass([controller_ class]),
        @"navigationURL": [[controller_ navigationURL] absoluteString] ?: @"",
        @"destinationURL": [[controller_ destinationURL] absoluteString] ?: @"",
        @"state": @(controller_.state),
        @"presentedClass": presented == nil ? @"" : NSStringFromClass([presented class]),
        @"safariPresented": @(safari),
        @"safariPresentationCount": @(safariPresentationCount_),
        @"navigationDepth": @(navigation_.viewControllers.count),
        @"navigationBarHidden": @(navigationBar.hidden),
        @"navigationBarWindowPresent": @(navigationBar.window != nil),
        @"navigationBarAlpha": @(navigationBar.alpha),
        @"navigationBarVisibleHeight": @(VisibleHeightInWindow(navigationBar)),
        @"navigationTitle": navigationTitle,
        @"navigationTitleMatchesController": @([navigationTitle
            isEqualToString:(controller_.title ?: @"")]),
        @"navigationBarStyle": @(navigationBar.barStyle),
        @"navigationTitleLuminance": @(ProbeLuminance(
            [navigationBar.titleTextAttributes
                objectForKey:NSForegroundColorAttributeName])),
        @"preferredStatusBarStyle": @([self preferredStatusBarStyle]),
        @"statusText": status.text ?: @"",
        @"detailText": detail.text ?: @"",
        @"retryTitle": [retry titleForState:UIControlStateNormal] ?: @"",
        @"retryHidden": @(retry.hidden),
        @"labelsFit": @(ViewFitsSuperview(status) && ViewFitsSuperview(detail)),
        @"retryMeetsTouchTarget": @(CGRectGetHeight(retry.bounds) >= 44.0),
        @"surfaceLuminance": @(ProbeLuminance(controller_.view.backgroundColor)),
        @"uiWebViewCount": @(CountViewsOfClassNamed(self.view, @"UIWebView")),
        @"wkWebViewCount": @(CountViewsOfClassNamed(self.view, @"WKWebView")),
        @"accessibility": accessibility,
    });
    [state writeToFile:[self markerPath:@"cydia-external-url-probe.plist"]
        atomically:YES];
}

@end


UIViewController *CydiaExternalURLControllerProbeRootController(void) {
    return [[CydiaExternalURLProbeHostController alloc] init];
}

#endif // TARGET_OS_SIMULATOR && CYDIA_EXTERNAL_URL_SIMULATOR_PROBE
