/* Committed UIKit/browser renderers. Inert package destination and HTTP
 * transport fixtures only; no APT, file transfers or actual OS focus claim.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <UIKit/UIKit.h>
#import "Cydia/CopyingFilesGuideController.h"
#import "Cydia/HomeGuideController.h"
#import "Cydia/HomePlaceholderController.h"
#import "Cydia/HomeStorageController.h"
#import "Cydia/ExternalURLController.h"
#import "Cydia/ExternalURLPolicy.h"
#import "Cydia/UIRouteContext.h"
#import "Cydia/UIColor+Cydia.h"

static void Record(NSString *name, NSDictionary *event) {
    NSData *line = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        file = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [file seekToEndOfFile]; [file writeData:line];
    [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
}
static UIColor *Resolved(UIColor *color, UITraitCollection *traits) {
    if (@available(iOS 13.0, *)) return [color resolvedColorWithTraitCollection:traits];
    return color;
}
static void Collect(UIView *view, NSMutableArray *labels) {
    if (view.hidden || view.alpha == 0) return;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (label.text.length) {
            CGSize needed = [label sizeThatFits:CGSizeMake(label.bounds.size.width, CGFLOAT_MAX)];
            CGFloat r=0,g=0,b=0,a=0;
            [Resolved(label.textColor, label.traitCollection) getRed:&r green:&g blue:&b alpha:&a];
            [labels addObject:@{@"text":label.text, @"width":@(label.bounds.size.width),
                @"height":@(label.bounds.size.height), @"neededHeight":@(needed.height),
                @"fontSize":@(label.font.pointSize), @"lines":@(label.numberOfLines), @"color":@[@(r),@(g),@(b),@(a)]}];
        }
    }
    for (UIView *child in view.subviews) Collect(child, labels);
}
// Capture the real production system-open call without launching a mail app or
// sending mail. The failure completion deliberately exercises the native error
// state. This adapter is NOT evidence of an installed OS mail handler.
@interface HomeGuidesFixtureApplication : UIApplication
@end
@implementation HomeGuidesFixtureApplication
- (void)openURL:(NSURL *)URL options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey,id> *)options
        completionHandler:(void (^)(BOOL))completion {
    NSAssert([URL.absoluteString isEqual:@"mailto:pathompol@gmail.com"], @"unexpected external system effect");
    Record(@"fixture-events.jsonl", @{@"event":@"system-open-adapter", @"url":URL.absoluteString,
        @"profile":NSProcessInfo.processInfo.environment[@"HOME_GUIDE_PROFILE"] ?: @"light", @"result":@NO});
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO); });
}
@end
@interface HomeGuidesComparisonApplication : UIResponder <UIApplicationDelegate, UINavigationControllerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) NSTimer *observation;
@property(nonatomic, copy) NSString *lastMetrics, *profile, *member;
@property(nonatomic) NSUInteger routes, guides;
@end
@implementation HomeGuidesComparisonApplication
- (void)openGuide {
    CydiaUIRouteDescriptor *route = CydiaUIParseRouteURL([NSURL URLWithString:[@"cydia://home/" stringByAppendingString:_member]], NULL);
    NSAssert((route.kind == CydiaUIRouteKindCopyingFiles || route.kind == CydiaUIRouteKindHomeGuide) &&
        CydiaUIEvaluateRoute(route, CydiaUIRouteContext.trustedNativeContext).allowed, @"guide route policy");
    CyteViewController *guide;
    if ([_member isEqual:@"copying-files"])
        guide = [[CopyingFilesGuideController alloc] init];
    else if ([_member isEqual:@"storage"])
        guide = [[HomeStorageController alloc] init];
    else if ([@[@"featured", @"themes", @"account"] containsObject:_member])
        guide = [[HomePlaceholderController alloc] initWithPageIdentifier:_member];
    else
        guide = [[HomeGuideController alloc] initWithPageIdentifier:_member];
    NSAssert(guide != nil, @"bundled content"); [guide setDelegate:self];
    ++_guides; [_navigation pushViewController:guide animated:NO];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    _profile = NSProcessInfo.processInfo.environment[@"HOME_GUIDE_PROFILE"] ?: @"light";
    _member = NSProcessInfo.processInfo.environment[@"HOME_GUIDE_PAGE"] ?: @"openssh";
    UIViewController *origin = [[UIViewController alloc] init]; origin.title = @"Cydia";
    origin.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:origin.traitCollection];
    UIButton *open = [UIButton buttonWithType:UIButtonTypeSystem];
    [open setTitle:@"Open Home Guide" forState:UIControlStateNormal];
    open.accessibilityIdentifier = @"home-guide.fixture.open";
    [open addTarget:self action:@selector(openGuide) forControlEvents:UIControlEventTouchUpInside];
    open.frame = CGRectMake(20, 120, 335, 64); [origin.view addSubview:open];
    _status = [[UILabel alloc] initWithFrame:CGRectMake(20, 200, 335, 100)];
    _status.numberOfLines = 0; _status.accessibilityIdentifier = @"home-guide.fixture.status";
    _status.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:origin.traitCollection];
    [origin.view addSubview:_status];
    _navigation = [[UINavigationController alloc] initWithRootViewController:origin]; _navigation.delegate = self;
    _window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; _window.rootViewController = _navigation;
    [_window makeKeyAndVisible]; [self openGuide];
    _observation = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(observe) userInfo:nil repeats:YES];
    return YES;
}
- (CyteViewController *)pageForURL:(NSURL *)URL context:(NSObject<CyteWebNavigationContext> *)context withReferrer:(NSString *)referrer {
    CydiaUIRouteDescriptor *route = CydiaUIParseRouteURL(URL, NULL);
    NSAssert(context.class == CydiaUIRouteContext.class &&
        CydiaUIEvaluateRoute(route, (CydiaUIRouteContext *)context).allowed &&
        [referrer hasPrefix:@"cydia://home/"], @"typed route/referrer policy");
    ++_routes;
    Record(@"fixture-events.jsonl", @{@"event":@"route", @"profile":_profile, @"url":URL.absoluteString,
        @"referrer":referrer, @"kind":@(route.kind), @"count":@(_routes),
        @"member":_member, @"guide":@(_guides), @"packageWrites":@0});
    if (route.kind == CydiaUIRouteKindPackage) {
        CyteViewController *page = [[CyteViewController alloc] init]; page.title = @"Package fixture";
        page.view = [[UIView alloc] init];
        page.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:page.traitCollection];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, 335, 100)];
        label.text = [@"Inert package destination: " stringByAppendingString:route.arguments.firstObject];
        label.numberOfLines = 0; label.accessibilityIdentifier = @"home-guide.fixture.package";
        [page.view addSubview:label]; return page;
    }
    if (route.kind == CydiaUIRouteKindHomeGuide) {
        NSString *member = route.arguments[0];
        if ([member isEqual:@"storage"])
            return [[HomeStorageController alloc] init];
        if ([@[@"featured", @"themes", @"account"] containsObject:member])
            return [[HomePlaceholderController alloc] initWithPageIdentifier:member];
        return [[HomeGuideController alloc] initWithPageIdentifier:member];
    }
    NSAssert(route.kind == CydiaUIRouteKindExternalOpen, @"only finite navigation kinds");
    if ([route.externalURL.scheme isEqual:@"mailto"])
        return [[ExternalURLController alloc] initWithRouteDescriptor:route];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *original = [route.externalURL.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *fixture = [NSURL URLWithString:[@"http://127.0.0.1:18948/out?url=" stringByAppendingString:original]];
    return [[ExternalURLController alloc] initWithRouteDescriptor:CydiaUIParseRouteURL(CydiaExternalURLRouteURL(fixture), NULL)];
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    _status.text = [NSString stringWithFormat:@"Guides: %lu Routes: %lu", (unsigned long)_guides, (unsigned long)_routes];
    Record(@"fixture-events.jsonl", @{@"event":@"navigation", @"profile":_profile,
        @"controller":NSStringFromClass(controller.class), @"depth":@(navigation.viewControllers.count),
        @"member":_member, @"guide":@(_guides), @"instance":[NSString stringWithFormat:@"%p", controller]});
}
- (void)observe {
    UIViewController *top = _navigation.topViewController;
    if ((! [top isKindOfClass:CopyingFilesGuideController.class] && ![top isKindOfClass:HomeGuideController.class] &&
         ![top isKindOfClass:HomeStorageController.class]) || top.presentedViewController) return;
    UITableView *table = (UITableView *)top.view;
    if (table.dragging || table.decelerating) return;
    NSMutableArray *rows = [NSMutableArray array];
    for (UITableViewCell *cell in table.visibleCells) {
        NSMutableArray *labels = [NSMutableArray array]; Collect(cell.contentView, labels);
        CGFloat r=0,g=0,b=0,a=0;
        [Resolved(cell.backgroundColor, top.traitCollection) getRed:&r green:&g blue:&b alpha:&a];
        [rows addObject:@{@"identifier":cell.accessibilityIdentifier ?: @"", @"height":@(cell.bounds.size.height),
            @"traits":@(cell.accessibilityTraits), @"label":cell.accessibilityLabel ?: @"", @"labels":labels,
            @"background":@[@(r),@(g),@(b),@(a)]}];
    }
    NSDictionary *metrics = @{@"profile":_profile, @"member":_member, @"surface":table.accessibilityIdentifier, @"style":@(top.traitCollection.userInterfaceStyle),
        @"category":top.traitCollection.preferredContentSizeCategory, @"offset":@(table.contentOffset.y),
        @"guide":@(_guides), @"rows":rows, @"scope":@"actual UIKit geometry; not actual VoiceOver focus"};
    NSString *key = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:metrics options:NSJSONWritingSortedKeys error:NULL] encoding:NSUTF8StringEncoding];
    if (![_lastMetrics isEqual:key]) { _lastMetrics = key; Record(@"native-metrics.jsonl", metrics); }
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, NSStringFromClass(HomeGuidesFixtureApplication.class), NSStringFromClass(HomeGuidesComparisonApplication.class)); }
}
