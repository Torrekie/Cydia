/* Actual committed UIKit renderer with a source-list fixture only.
 * No real APT writer/verifier, source-add alert imitation or mutation proof.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <UIKit/UIKit.h>
#import "Cydia/MoreSourcesController.h"
#import "Cydia/MoreSourcesModel.h"
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
    [file seekToEndOfFile]; [file writeData:line]; [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
}

@interface MoreSourcesFixture : NSObject <CydiaMoreSourcesProviding>
@property(nonatomic, copy) NSString *scenario;
@property(nonatomic) NSUInteger requests;
@property(nonatomic, copy) NSString *lastIdentifier;
@end
@implementation MoreSourcesFixture
- (NSArray<NSDictionary *> *)configuredSources {
    if ([_scenario isEqual:@"all"]) return CydiaDefaultSourceCatalog();
    if ([_scenario isEqual:@"partial"]) return @[@{@"rooturi":@"http://apt.modmyi.com/", @"distribution":@"stable"}];
    return @[];
}
- (BOOL)canEditSources { return ![_scenario isEqual:@"readonly"]; }
- (void)restoreSourceIdentifier:(NSString *)identifier presenter:(CyteViewController *)presenter completion:(void (^)(BOOL))completion {
    ++_requests; _lastIdentifier = identifier;
    Record(@"fixture-events.jsonl", @{@"event":@"request-observed-no-backend", @"identifier":identifier,
        @"requests":@(_requests), @"sourceWrites":@0});
    completion(NO); // Explicit rejection; not a simulated successful mutation/Cancel.
}
- (void)cancelRestoration { }
@end

static void Collect(UIView *view, NSMutableArray *labels, NSMutableArray *images) {
    if (view.hidden || view.alpha == 0) return;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (label.text.length) {
            CGSize needed = [label sizeThatFits:CGSizeMake(label.bounds.size.width, CGFLOAT_MAX)];
            [labels addObject:@{@"text":label.text, @"width":@(label.bounds.size.width),
                @"height":@(label.bounds.size.height), @"neededHeight":@(needed.height),
                @"fontSize":@(label.font.pointSize), @"lines":@(label.numberOfLines)}];
        }
    }
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImage *image = [(UIImageView *)view image];
        if (image && view.bounds.size.width > 0)
            [images addObject:@{@"width":@(image.size.width), @"height":@(image.size.height),
                @"viewWidth":@(view.bounds.size.width), @"viewHeight":@(view.bounds.size.height)}];
    }
    for (UIView *child in view.subviews) Collect(child, labels, images);
}

@interface MoreSourcesComparisonApplication : UIResponder <UIApplicationDelegate, UINavigationControllerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) MoreSourcesFixture *fixture;
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) NSTimer *observation;
@property(nonatomic, copy) NSString *lastMetrics;
@end
@implementation MoreSourcesComparisonApplication
- (void)openGuide {
    NSURL *URL = [NSURL URLWithString:@"cydia://home/more-sources"];
    CydiaUIRouteDescriptor *route = CydiaUIParseRouteURL(URL, NULL);
    NSAssert(route.kind == CydiaUIRouteKindMoreSources &&
        CydiaUIEvaluateRoute(route, [CydiaUIRouteContext trustedNativeContext]).allowed, @"native route policy");
    MoreSourcesController *controller = [[MoreSourcesController alloc] initWithProvider:_fixture];
    [_navigation pushViewController:controller animated:NO];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSString *scenario = NSProcessInfo.processInfo.environment[@"MORE_SOURCES_SCENARIO"] ?: @"missing";
    NSAssert(([@[@"missing", @"partial", @"all", @"readonly"] containsObject:scenario]), @"finite fixture");
    _fixture = [[MoreSourcesFixture alloc] init]; _fixture.scenario = scenario;
    UIViewController *origin = [[UIViewController alloc] init]; origin.title = @"Cydia";
    origin.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:origin.traitCollection];
    UIButton *open = [UIButton buttonWithType:UIButtonTypeSystem];
    [open setTitle:@"Open More Sources" forState:UIControlStateNormal];
    open.accessibilityIdentifier = @"more-sources.fixture.open";
    [open addTarget:self action:@selector(openGuide) forControlEvents:UIControlEventTouchUpInside];
    open.frame = CGRectMake(20, 120, 335, 64); [origin.view addSubview:open];
    _status = [[UILabel alloc] initWithFrame:CGRectMake(20, 200, 335, 160)];
    _status.numberOfLines = 0; _status.accessibilityIdentifier = @"more-sources.fixture.status";
    _status.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:origin.traitCollection];
    [origin.view addSubview:_status];
    _navigation = [[UINavigationController alloc] initWithRootViewController:origin]; _navigation.delegate = self;
    _window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; _window.rootViewController = _navigation;
    [_window makeKeyAndVisible]; [self openGuide];
    _observation = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(observe) userInfo:nil repeats:YES];
    return YES;
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    _status.text = [NSString stringWithFormat:@"Fixture requests: %lu\nLast: %@\nSource writes: 0",
        (unsigned long)_fixture.requests, _fixture.lastIdentifier ?: @"none"];
    Record(@"fixture-events.jsonl", @{@"event":@"navigation", @"controller":NSStringFromClass(controller.class),
        @"depth":@(navigation.viewControllers.count), @"scenario":_fixture.scenario});
}
- (void)observe {
    UIViewController *top = _navigation.topViewController;
    if (![top isKindOfClass:[MoreSourcesController class]]) return;
    UITableView *table = (UITableView *)top.view;
    if (table.dragging || table.decelerating) return;
    NSMutableArray *rows = [NSMutableArray array];
    for (UITableViewCell *cell in table.visibleCells) {
        NSMutableArray *labels = [NSMutableArray array], *images = [NSMutableArray array];
        Collect(cell.contentView, labels, images);
        [rows addObject:@{@"identifier":cell.accessibilityIdentifier ?: @"", @"height":@(cell.bounds.size.height),
            @"traits":@(cell.accessibilityTraits), @"labels":labels, @"images":images}];
    }
    NSDictionary *metrics = @{@"scenario":_fixture.scenario, @"style":@(top.traitCollection.userInterfaceStyle),
        @"category":top.traitCollection.preferredContentSizeCategory, @"offset":@(table.contentOffset.y),
        @"rows":rows, @"scope":@"actual UIKit geometry; not actual VoiceOver focus"};
    NSString *key = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:metrics options:NSJSONWritingSortedKeys error:NULL]
        encoding:NSUTF8StringEncoding];
    if (![_lastMetrics isEqual:key]) { _lastMetrics = key; Record(@"native-metrics.jsonl", metrics); }
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(MoreSourcesComparisonApplication.class)); }
}
