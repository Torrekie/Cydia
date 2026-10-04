/* Guide-only comparison host. Production controllers are compiled unchanged
 * from the requested source commit. No APT or device capability is supplied.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later
 */
#import <UIKit/UIKit.h>
#include <cstdlib>
#include <cstring>
#import "Cydia/ExternalURLController.h"
#import "Cydia/ExternalURLPolicy.h"
#import "Cydia/UIRouteContext.h"
#ifdef GUIDE_NATIVE_SOURCE
#import "Cydia/UpgradingGuideController.h"
#endif

@interface GuideComparisonContainer : UIViewController
@end
@implementation GuideComparisonContainer
- (UIStatusBarStyle)preferredStatusBarStyle {
    return self.childViewControllers.firstObject.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ?
        UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}
@end

@interface GuideComparisonApplication : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, copy) NSString *fixture;
@property(nonatomic, strong) UIViewController *container;
@end

@implementation GuideComparisonApplication
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    _fixture = environment[@"GUIDE_FIXTURE_URL"] ?: @"http://127.0.0.1:18943";
    NSString *page = environment[@"GUIDE_PAGE"] ?: @"root";
    UIViewController *origin = [[UIViewController alloc] init];
    origin.title = @"Cydia";
    _navigation = [[UINavigationController alloc] initWithRootViewController:origin];
    CyteViewController *guide;
#ifdef GUIDE_NATIVE_SOURCE
    guide = [[UpgradingGuideController alloc] initWithPageIdentifier:page];
#else
    NSString *path = [page isEqualToString:@"root"] ? @"index" : page;
    NSString *fixturePath = environment[@"GUIDE_FIXTURE_PATH"] ?: [NSString stringWithFormat:@"/upgrading/%@.html", path];
    NSURL *URL = [NSURL URLWithString:[_fixture stringByAppendingString:fixturePath]];
    guide = [[ExternalURLController alloc] initWithRouteDescriptor:
        CydiaUIParseRouteURL(CydiaExternalURLRouteURL(URL), NULL)];
#endif
    if (guide == nil)
        return NO;
    [guide setDelegate:self];
    [_navigation setViewControllers:@[origin, guide] animated:NO];
    _window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (environment[@"GUIDE_TRACE_MODE"] != nil) {
        // The recorder follows the real app's navigation/tab containment.
        // This focused test uses that shape, without changing production
        // traversal or pretending app-local traits change OS accessibility.
        _window.rootViewController = _navigation;
        [_window makeKeyAndVisible];
        return YES;
    }
    _container = [[GuideComparisonContainer alloc] init];
    _window.rootViewController = _container;
    [_container addChildViewController:_navigation];
    _navigation.view.frame = _container.view.bounds;
    _navigation.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_container.view addSubview:_navigation.view];
    [_navigation didMoveToParentViewController:_container];
    // iOS12 public trait overrides, same as the existing Home probe. No system
    // appearance or accessibility preference is changed by a comparison run.
    NSString *profile = environment[@"GUIDE_PROFILE"] ?: @"light";
    UITraitCollection *style = [UITraitCollection traitCollectionWithUserInterfaceStyle:
        [profile hasPrefix:@"dark"] ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight];
    UITraitCollection *size = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:
        [profile hasSuffix:@"ax"] ? UIContentSizeCategoryAccessibilityLarge : UIContentSizeCategoryLarge];
    [_container setOverrideTraitCollection:[UITraitCollection
        traitCollectionWithTraitsFromCollections:@[style, size]] forChildViewController:_navigation];
    [_window makeKeyAndVisible];
    return YES;
}

- (CyteViewController *)pageForURL:(NSURL *)URL
        context:(NSObject<CyteWebNavigationContext> *)context withReferrer:(NSString *)referrer {
    // Observe the unmodified URL emitted by the production native guide.
    NSDictionary *event = @{@"requestedURL": URL.absoluteString ?: @"",
        @"referrer": referrer ?: @""};
    [event writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"guide-route.plist"] atomically:YES];
    CydiaUIRouteDescriptor *descriptor = CydiaUIParseRouteURL(URL, NULL);
    if (descriptor.kind != CydiaUIRouteKindExternalOpen)
        return nil; // Package dispatch is outside this UI-only fixture.
    // Frozen transport fixture; the real coordinator still opens and returns
    // from SFSafariViewController. No third-party website is executed by tests.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *original = [descriptor.externalURL.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *fixtureURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/out?url=%@", _fixture, original]];
    return [[ExternalURLController alloc] initWithRouteDescriptor:
        CydiaUIParseRouteURL(CydiaExternalURLRouteURL(fixtureURL), NULL)];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        // Test-host-only opt-in, before NSProcessInfo snapshots the environment.
        // Each launch is a new process; the journal refuses existing paths.
        const char *traceMode = getenv("GUIDE_TRACE_MODE");
        if (traceMode != NULL) {
            if (strcmp(traceMode, "on") == 0) {
                NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"guide-ax.jsonl"];
                setenv("CYDIA_NATIVE_AX_TRACE_PATH", path.fileSystemRepresentation, 1);
            } else {
                unsetenv("CYDIA_NATIVE_AX_TRACE_PATH");
            }
        }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(GuideComparisonApplication.class));
    }
}
