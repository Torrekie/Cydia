/* Cydia Refurbished installed native-error probe.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "tests/simulator/ErrorViewRuntimeProbe.h"

#include "Cydia/ErrorViewController.h"
#include "Cydia/ErrorViewModel.h"
#include "Cydia/UIColor+Cydia.h"

#include <TargetConditionals.h>
#include <cmath>
#include <unistd.h>

#if !TARGET_OS_SIMULATOR
#error ErrorViewRuntimeProbe is simulator-only
#endif

namespace {

NSString *ProbeEnvironment(NSString *key) {
    return [[[NSProcessInfo processInfo] environment] objectForKey:key] ?: @"";
}

NSInteger ProbeLuminance(UIColor *color) {
    CGFloat red(0), green(0), blue(0), alpha(0), white(0);
    if ([color getRed:&red green:&green blue:&blue alpha:&alpha])
        return (NSInteger)std::lround(
            (0.2126 * red + 0.7152 * green + 0.0722 * blue) * 255.0);
    if ([color getWhite:&white alpha:&alpha])
        return (NSInteger)std::lround(white * 255.0);
    return -1;
}

NSUInteger CountViewsOfClassNamed(UIView *root, NSString *name) {
    if (root == nil)
        return 0;
    NSUInteger count([NSStringFromClass([root class]) isEqualToString:name] ? 1 : 0);
    for (UIView *child in root.subviews)
        count += CountViewsOfClassNamed(child, name);
    return count;
}

BOOL ViewFitsWindow(UIView *view) {
    UIWindow *window(view.window);
    if (view == nil || window == nil || CGRectIsEmpty(view.bounds))
        return NO;
    CGRect frame([view convertRect:view.bounds toView:window]);
    return CGRectContainsRect(CGRectInset(window.bounds, -1.0, -1.0), frame);
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
            @"hidden": @(view.hidden),
        }];
    }
    for (UIView *child in view.subviews)
        AppendAccessibility(child, items);
}

} // namespace


@interface CydiaErrorProbeHostController : UIViewController <ErrorViewControllerDelegate>
@end

@implementation CydiaErrorProbeHostController {
    ErrorViewController *errorController_;
    NSURLRequest *originalRequest_;
    NSURLRequest *lastRetryRequest_;
    UILabel *successLabel_;
    NSUInteger retryCount_;
    BOOL dark_;
    BOOL accessibilityLarge_;
    BOOL detailsRequested_;
    BOOL fixtureInstalled_;
    NSUInteger settleTicks_;
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
    if (dark_)
        return UIStatusBarStyleLightContent;
    if (@available(iOS 13.0, *))
        return UIStatusBarStyleDarkContent;
    return UIStatusBarStyleDefault;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor
        cydiaColorForRole:CydiaColorRoleGroupedBackground
        traitCollection:self.traitCollection];
    [self applyTraits];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (fixtureInstalled_)
        return;
    fixtureInstalled_ = YES;
    [self performSelector:@selector(installFixtureAfterAppearance)
        withObject:nil afterDelay:0];
}

- (void)installFixtureAfterAppearance {
    NSURL *URL([NSURL URLWithString:
        @"https://user:secret@example.com/private/index?token=abc123#frag"]);
    NSMutableURLRequest *request([NSMutableURLRequest requestWithURL:URL]);
    [request setValue:@"Bearer hidden" forHTTPHeaderField:@"Authorization"];
    originalRequest_ = [request copy];
    NSError *error([NSError errorWithDomain:NSURLErrorDomain
        code:NSURLErrorNotConnectedToInternet userInfo:@{
            NSLocalizedDescriptionKey:
                @"Could not load https://user:secret@example.com/private/index?token=abc123#frag\nplease retry",
        }]);
    CydiaErrorViewModel *model([[CydiaErrorViewModel alloc]
        initWithError:error destinationURL:URL]);
    errorController_ = [[ErrorViewController alloc]
        initWithViewModel:model retryAvailable:YES delegate:self];
    [self addChildViewController:errorController_];
    errorController_.view.frame = self.view.bounds;
    errorController_.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:errorController_.view];
    [errorController_ didMoveToParentViewController:self];
    [self applyTraits];
    settleTicks_ = 5;
    [self performSelector:@selector(probeTick) withObject:nil afterDelay:0.2];
}

- (void)applyTraits {
    UITraitCollection *style([UITraitCollection
        traitCollectionWithUserInterfaceStyle:dark_ ?
            UIUserInterfaceStyleDark : UIUserInterfaceStyleLight]);
    UITraitCollection *size([UITraitCollection
        traitCollectionWithPreferredContentSizeCategory:accessibilityLarge_ ?
            UIContentSizeCategoryAccessibilityLarge : UIContentSizeCategoryLarge]);
    UITraitCollection *traits([UITraitCollection
        traitCollectionWithTraitsFromCollections:@[style, size]]);
    if (errorController_ != nil) {
        [self setOverrideTraitCollection:traits
            forChildViewController:errorController_];
        [errorController_.view setNeedsLayout];
        [errorController_.view layoutIfNeeded];
    }
    self.view.backgroundColor = [UIColor
        cydiaColorForRole:CydiaColorRoleGroupedBackground
        traitCollection:traits];
    successLabel_.textColor = [UIColor
        cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits];
    successLabel_.backgroundColor = self.view.backgroundColor;
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)errorViewControllerDidRequestRetry:(ErrorViewController *)controller {
    if (controller != errorController_ || originalRequest_ == nil)
        return;
    ++retryCount_;
    lastRetryRequest_ = [originalRequest_ copy];
    [errorController_ willMoveToParentViewController:nil];
    [errorController_.view removeFromSuperview];
    [errorController_ removeFromParentViewController];

    successLabel_ = [[UILabel alloc] initWithFrame:self.view.bounds];
    successLabel_.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    successLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    successLabel_.adjustsFontForContentSizeCategory = YES;
    successLabel_.textAlignment = NSTextAlignmentCenter;
    successLabel_.text = @"Retry Succeeded";
    successLabel_.accessibilityIdentifier = @"native-error.retry-succeeded";
    [self.view addSubview:successLabel_];
    [self applyTraits];
}

- (void)probeTick {
    if ([self consumeMarker:@"cydia-native-error-probe-details"] &&
        errorController_ != nil) {
        [errorController_ detailsButtonClicked];
        detailsRequested_ = YES;
        settleTicks_ = 4;
    }
    if ([self consumeMarker:@"cydia-native-error-probe-dark"]) {
        dark_ = YES;
        accessibilityLarge_ = NO;
        [self applyTraits];
        settleTicks_ = 4;
    }
    if ([self consumeMarker:@"cydia-native-error-probe-accessibility"]) {
        dark_ = YES;
        accessibilityLarge_ = YES;
        [self applyTraits];
        settleTicks_ = 4;
    }
    if ([self consumeMarker:@"cydia-native-error-probe-retry"] &&
        errorController_ != nil) {
        [errorController_ retryButtonClicked];
        settleTicks_ = 4;
    }
    if (settleTicks_ != 0)
        --settleTicks_;
    [self writeState];
    [self performSelector:@selector(probeTick) withObject:nil afterDelay:0.2];
}

- (void)writeState {
    UILabel *title([errorController_ valueForKey:@"titleLabel"]);
    UILabel *summary([errorController_ valueForKey:@"summaryLabel"]);
    UILabel *details([errorController_ valueForKey:@"detailsLabel"]);
    UIButton *retry([errorController_ valueForKey:@"retryButton"]);
    UIButton *more([errorController_ valueForKey:@"detailsButton"]);
    NSMutableArray *accessibility([NSMutableArray array]);
    AppendAccessibility(errorController_.view, accessibility);

    NSURLRequest *retried(lastRetryRequest_);
    NSString *retriedURL(retried.URL.absoluteString ?: @"");
    BOOL hidden(errorController_.view.superview == nil);
    NSString *successText(successLabel_.text ?: @"");
    NSDictionary *state(@{
        @"schema": @1,
        @"fixtureVersion": @"native-error-v2",
        @"buildEvidence": @{
            @"sourceHEAD": ProbeEnvironment(@"CYDIA_PROBE_SOURCE_HEAD"),
            @"binarySHA256": ProbeEnvironment(@"CYDIA_PROBE_BINARY_SHA256"),
            @"bundleShortVersion": ProbeEnvironment(@"CYDIA_PROBE_BUNDLE_SHORT_VERSION"),
            @"bundleVersion": ProbeEnvironment(@"CYDIA_PROBE_BUNDLE_VERSION"),
        },
        @"ready": @(settleTicks_ == 0),
        @"processID": @((int)getpid()),
        @"systemVersion": [UIDevice currentDevice].systemVersion,
        @"style": dark_ ? @"dark" : @"light",
        @"contentSize": accessibilityLarge_ ? @"accessibility-large" : @"large",
        @"controllerClass": NSStringFromClass([errorController_ class]),
        @"detailsRequested": @(detailsRequested_),
        @"detailsVisible": @(errorController_.detailsVisible),
        @"overlayVisible": @(!hidden),
        @"retryCount": @(retryCount_),
        @"retryMethod": retried.HTTPMethod ?: @"",
        @"retryURLMatches": @([retriedURL isEqualToString:
            @"https://user:secret@example.com/private/index?token=abc123#frag"]),
        @"retryHeaderPreserved": @([[retried valueForHTTPHeaderField:@"Authorization"]
            isEqualToString:@"Bearer hidden"]),
        @"retrySucceeded": @([successText containsString:@"Retry Succeeded"]),
        @"title": title.text ?: @"",
        @"summary": summary.text ?: @"",
        @"details": details.text ?: @"",
        @"detailsLabelHidden": @(details.hidden),
        @"retryTitle": [retry titleForState:UIControlStateNormal] ?: @"",
        @"moreTitle": [more titleForState:UIControlStateNormal] ?: @"",
        @"retryHeight": @(CGRectGetHeight(retry.bounds)),
        @"moreHeight": @(CGRectGetHeight(more.bounds)),
        @"titleFits": @(ViewFitsWindow(title)),
        @"summaryFits": @(ViewFitsWindow(summary)),
        @"detailsFits": @(details.hidden || ViewFitsWindow(details)),
        @"surfaceLuminance": @(ProbeLuminance(errorController_.view.backgroundColor)),
        @"titleLuminance": @(ProbeLuminance(title.textColor)),
        @"preferredStatusBarStyle": @([self preferredStatusBarStyle]),
        @"uiWebViewCountInError": @(CountViewsOfClassNamed(errorController_.view, @"UIWebView")),
        @"wkWebViewCountInError": @(CountViewsOfClassNamed(errorController_.view, @"WKWebView")),
        @"accessibilityModal": @(errorController_.view.accessibilityViewIsModal),
        @"accessibility": accessibility,
    });
    [state writeToFile:[self markerPath:@"cydia-native-error-probe.plist"]
        atomically:YES];
}

@end


UIViewController *CydiaErrorViewRuntimeProbeRootController(void) {
    return [[CydiaErrorProbeHostController alloc] init];
}
