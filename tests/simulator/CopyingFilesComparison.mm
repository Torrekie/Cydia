/* Committed UIKit/browser renderers. Inert package destination and HTTP
 * transport fixtures only; no APT, file transfers or actual OS focus claim.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <UIKit/UIKit.h>
#import "Cydia/CopyingFilesGuideController.h"
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
@interface CopyingFilesComparisonApplication : UIResponder <UIApplicationDelegate, UINavigationControllerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) NSTimer *observation;
@property(nonatomic, copy) NSString *lastMetrics, *profile;
@property(nonatomic) NSUInteger routes, guides;
@end
@implementation CopyingFilesComparisonApplication
- (void)openGuide {
    CydiaUIRouteDescriptor *route = CydiaUIParseRouteURL([NSURL URLWithString:@"cydia://home/copying-files"], NULL);
    NSAssert(route.kind == CydiaUIRouteKindCopyingFiles &&
        CydiaUIEvaluateRoute(route, CydiaUIRouteContext.trustedNativeContext).allowed, @"guide route policy");
    CopyingFilesGuideController *guide = [[CopyingFilesGuideController alloc] init];
    NSAssert(guide != nil, @"bundled content"); [guide setDelegate:self];
    ++_guides; [_navigation pushViewController:guide animated:NO];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    _profile = NSProcessInfo.processInfo.environment[@"COPYING_PROFILE"] ?: @"light";
    UIViewController *origin = [[UIViewController alloc] init]; origin.title = @"Cydia";
    origin.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:origin.traitCollection];
    UIButton *open = [UIButton buttonWithType:UIButtonTypeSystem];
    [open setTitle:@"Open Copying Files" forState:UIControlStateNormal];
    open.accessibilityIdentifier = @"copying.fixture.open";
    [open addTarget:self action:@selector(openGuide) forControlEvents:UIControlEventTouchUpInside];
    open.frame = CGRectMake(20, 120, 335, 64); [origin.view addSubview:open];
    _status = [[UILabel alloc] initWithFrame:CGRectMake(20, 200, 335, 100)];
    _status.numberOfLines = 0; _status.accessibilityIdentifier = @"copying.fixture.status";
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
        [referrer isEqual:@"cydia://home/copying-files"], @"typed route/referrer policy");
    ++_routes;
    Record(@"fixture-events.jsonl", @{@"event":@"route", @"profile":_profile, @"url":URL.absoluteString,
        @"referrer":referrer, @"kind":@(route.kind), @"count":@(_routes),
        @"guide":@(_guides), @"packageWrites":@0});
    if (route.kind == CydiaUIRouteKindPackage) {
        CyteViewController *page = [[CyteViewController alloc] init]; page.title = @"Package fixture";
        page.view = [[UIView alloc] init];
        page.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:page.traitCollection];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, 335, 100)];
        label.text = [@"Inert package destination: " stringByAppendingString:route.arguments.firstObject];
        label.numberOfLines = 0; label.accessibilityIdentifier = @"copying.fixture.package";
        [page.view addSubview:label]; return page;
    }
    NSAssert(route.kind == CydiaUIRouteKindExternalOpen, @"only finite navigation kinds");
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *original = [route.externalURL.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *fixture = [NSURL URLWithString:[@"http://127.0.0.1:18946/out?url=" stringByAppendingString:original]];
    return [[ExternalURLController alloc] initWithRouteDescriptor:CydiaUIParseRouteURL(CydiaExternalURLRouteURL(fixture), NULL)];
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    _status.text = [NSString stringWithFormat:@"Guides: %lu Routes: %lu", (unsigned long)_guides, (unsigned long)_routes];
    Record(@"fixture-events.jsonl", @{@"event":@"navigation", @"profile":_profile,
        @"controller":NSStringFromClass(controller.class), @"depth":@(navigation.viewControllers.count),
        @"guide":@(_guides), @"instance":[NSString stringWithFormat:@"%p", controller]});
}
- (void)observe {
    UIViewController *top = _navigation.topViewController;
    if (![top isKindOfClass:CopyingFilesGuideController.class] || top.presentedViewController) return;
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
    NSDictionary *metrics = @{@"profile":_profile, @"style":@(top.traitCollection.userInterfaceStyle),
        @"category":top.traitCollection.preferredContentSizeCategory, @"offset":@(table.contentOffset.y),
        @"guide":@(_guides), @"rows":rows, @"scope":@"actual UIKit geometry; not actual VoiceOver focus"};
    NSString *key = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:metrics options:NSJSONWritingSortedKeys error:NULL] encoding:NSUTF8StringEncoding];
    if (![_lastMetrics isEqual:key]) { _lastMetrics = key; Record(@"native-metrics.jsonl", metrics); }
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(CopyingFilesComparisonApplication.class)); }
}
