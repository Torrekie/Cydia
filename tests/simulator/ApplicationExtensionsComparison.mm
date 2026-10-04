/* Focused host for unchanged production native controllers/models. Fixture
 * local inventory replaces unavailable simulator private services, not UIKit.
 * Package destinations are inert, never represented as installed APT evidence.
 * GPL-3.0-or-later. */
#import <UIKit/UIKit.h>
#import "Cydia/ApplicationExtensionsController.h"
#import "Cydia/UIRouteContext.h"

@interface ExtensionsFixtureRequest : NSObject <CydiaExtensionsRequest>
@property(nonatomic) BOOL cancelled;
@end
@implementation ExtensionsFixtureRequest
- (void)cancel { _cancelled = YES; }
@end

@interface ExtensionsFixtureProvider : NSObject <CydiaApplicationExtensionsProviding>
@property(nonatomic) NSUInteger loads;
@end
@implementation ExtensionsFixtureProvider
- (NSData *)localIconDataForBundleIdentifier:(NSString *)identifier { return nil; }
- (NSString *)localizedNameForBundleIdentifier:(NSString *)identifier {
    return @{@"com.apple.mobilesafari":@"Safari", @"com.apple.mobilemail":@"Mail"}[identifier];
}
- (id<CydiaExtensionsRequest>)loadRowsForBundleIdentifier:(NSString *)identifier
        completion:(CydiaExtensionsRowsCompletion)completion {
    ExtensionsFixtureRequest *request = [[ExtensionsFixtureRequest alloc] init];
    NSString *scenario = NSProcessInfo.processInfo.environment[@"EXTENSIONS_SCENARIO"] ?: @"populated";
    NSUInteger load = ++_loads;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (request.cancelled) return;
        if ([scenario isEqual:@"retry"] && load == 1) {
            completion(nil, [NSError errorWithDomain:@"Fixture" code:1 userInfo:nil]); return;
        }
        if ([scenario isEqual:@"empty"]) { completion(@[], nil); return; }
        NSString *root = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Fixture"];
        NSError *error = nil;
        NSArray *rows;
        if (identifier == nil) {
            rows = CydiaExtensionApplicationRows([NSData dataWithContentsOfFile:
                [root stringByAppendingPathComponent:@"api-application.json"]],
                @{@"com.apple.mobilesafari":@"Safari", @"com.apple.mobilemail":@"Mail",
                  @"com.test.unlisted":@"Unlisted"}, @{}, &error);
        } else {
            NSString *page = [identifier isEqual:@"com.apple.mobilemail"] ? @"mail.html" : @"safari.html";
            rows = CydiaExtensionPackageRows([NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:page]], &error);
        }
        completion(rows, error);
    });
    return request;
}
- (id<CydiaExtensionsRequest>)loadIconURL:(NSURL *)URL completion:(void (^)(NSData *))completion {
    ExtensionsFixtureRequest *request = [[ExtensionsFixtureRequest alloc] init];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (request.cancelled) return;
        NSString *path = [NSBundle.mainBundle.resourcePath stringByAppendingFormat:@"/Fixture/assets%@", URL.path];
        completion([NSData dataWithContentsOfFile:path]);
    });
    return request;
}
@end

@interface ExtensionsComparisonApplication : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation ExtensionsComparisonApplication
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    UIViewController *origin = [[UIViewController alloc] init]; origin.title = @"Cydia";
    origin.view.backgroundColor = UIColor.whiteColor;
    ApplicationExtensionsController *controller = [[ApplicationExtensionsController alloc]
        initWithBundleIdentifier:nil provider:[[ExtensionsFixtureProvider alloc] init]];
    [controller setDelegate:self];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:origin];
    [navigation setViewControllers:@[origin, controller] animated:NO];
    _window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _window.rootViewController = navigation;
    // Actual simulator settings choose Light/Dark and text size. No test-only
    // product traits or global settings are secretly changed by this host.
    [_window makeKeyAndVisible];
    return YES;
}
- (CyteViewController *)pageForURL:(NSURL *)URL
        context:(NSObject<CyteWebNavigationContext> *)context withReferrer:(NSString *)referrer {
    CydiaUIRouteDescriptor *descriptor = CydiaUIParseRouteURL(URL, NULL);
    if (!descriptor || descriptor.kind != CydiaUIRouteKindPackage ||
        !CydiaUIEvaluateRoute(descriptor, (CydiaUIRouteContext *)context).allowed) return nil;
    CyteViewController *destination = [[CyteViewController alloc] init];
    destination.title = @"Package destination fixture";
    UITextView *text = [[UITextView alloc] initWithFrame:CGRectZero]; text.editable = NO;
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text.text = [NSString stringWithFormat:@"%@\n%@\nRead-only fixture; not an installed package test.", URL.absoluteString, referrer];
    text.accessibilityIdentifier = @"extensions.fixture.destination";
    destination.view = text;
    return destination;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ExtensionsComparisonApplication.class)); }
}
