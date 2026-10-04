/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later
 * Production controller/provider/HTTP verifier/source writer. The database
 * inventory, HTTP transport and privileged file-copy boundary are fixtures.
 * No real APT initialization, privileged execution or external network.
 */
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include "Cydia/MoreSourcesController.h"
#include "Cydia/MoreSourcesProvider.h"
#include "Cydia/SourceControllers.h"
#include "Cydia/MoreSourcesModel.h"
#include "Cydia/DpkgRunner.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Sources.h"
#include "Menes/ObjectHandle.h"
#include "iPhonePrivate.h"
#include <sys/stat.h>
#include <unistd.h>

static NSString *FixtureRoot, *Scenario;
static std::string Parts, Managed, ArchitectureValue("iphoneos-arm");
static NSUInteger Adds, Syncs, FileInstalls, NetworkBalance, HTTPRequests;
static NSString *const Unowned = @"# user prefix\ndeb https://unowned.invalid/ stable main\n# user suffix\n";
_H<NSMutableDictionary> Sources_;
_H<NSString> UniqueID_;
_H<UIFont> Font12_, Font18Bold_;
CGFloat ScreenScale_ = 2;
char *Machine_ = nullptr;

static void Require(BOOL condition, NSString *reason) {
    if (!condition) { NSLog(@"RESTORATION FIXTURE FAIL: %@", reason); abort(); }
}
static void Record(NSDictionary *event) {
    @synchronized (Scenario) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:nil];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"restoration-events.jsonl"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
        [file seekToEndOfFile]; [file writeData:data]; [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [file closeFile];
    }
}
namespace CydiaAPT {
const std::string &Architecture() { return ArchitectureValue; }
const std::string &SourcePartsDirectory() { return Parts; }
const std::string &ManagedSourceListPath() { return Managed; }
std::string SourceArchitectureOption() { return "[arch=iphoneos-arm]"; }
}
// The catalog already has canonical trailing-slash URLs. Do not claim this
// adapter tests MobileCydia.mm's arbitrary-URL validation helper.
NSString *VerifySource(NSString *href) {
    Require([CydiaDefaultSourceCatalog() filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"rooturi == %@", href]].count == 1, @"only frozen catalog URLs");
    return href;
}
namespace CydiaRuntime {
namespace Dpkg {
Runner::Runner(Executable) : executable_("fixture-no-process") {}
bool Result::succeeded() const { return kind == ResultKind::Exited && code == 0; }
Result Runner::Run(const std::vector<std::string> &args, int statusFd) const {
    Require(statusFd == -1 && args.size() >= 3, @"only source-writer file operations");
    for (size_t i = 1; i < args.size(); ++i) {
        if (args[i][0] == '-') continue;
        NSString *path = [NSString stringWithUTF8String:args[i].c_str()];
        Require([[path stringByStandardizingPath] hasPrefix:[FixtureRoot stringByAppendingString:@"/"]], @"file effect outside owned fixture");
    }
    NSString *last = [NSString stringWithUTF8String:args.back().c_str()];
    BOOL okay = NO;
    if (args[0] == "/bin/cp") {
        NSString *from = [NSString stringWithUTF8String:args[args.size()-2].c_str()];
        NSData *data = [NSData dataWithContentsOfFile:from];
        okay = data != nil && [data writeToFile:last atomically:NO];
    } else if (args[0] == "/bin/mv") {
        okay = rename(args[args.size()-2].c_str(), args.back().c_str()) == 0;
        if (okay) ++FileInstalls;
    } else if (args[0] == "/bin/rm") okay = unlink(args.back().c_str()) == 0;
    Record(@{@"event":@"fixture-file-boundary", @"operation":[NSString stringWithUTF8String:args[0].c_str()], @"okay":@(okay)});
    return {ResultKind::Exited, okay ? 0 : 1, 0};
}
}
}

// Unused controller-link dependencies are fail-closed. The fixture database
// below only supplies the configured-source list; no package/source objects.
@interface Source : NSObject @end
@implementation Source @end
@interface SectionsController : UIViewController @end
@implementation SectionsController @end
@interface CydiaLegacyUIUndefinedValue : NSObject + (id)value; @end
@implementation CydiaLegacyUIUndefinedValue
+ (id)value { Require(NO, @"unexpected legacy session path"); return nil; }
@end
@interface RestorationDatabase : NSObject
- (NSArray *)sources;
@end
@implementation RestorationDatabase
- (NSArray *)sources { return @[]; }
@end
@interface RestorationHUD : NSObject
- (void)setText:(NSString *)text;
@end
@implementation RestorationHUD
- (void)setText:(NSString *)text { }
@end

@interface RestorationProtocol : NSURLProtocol
@property(atomic) BOOL stopped;
@end
@implementation RestorationProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSURL *url = self.request.URL;
    BOOL warning = [url.host isEqual:@"cydia.saurik.com"] && [url.path hasPrefix:@"/api/repotag/"];
    BOOL repository = [url.host isEqual:@"modmyi.saurik.com"] &&
        [url.path hasPrefix:@"/dists/stable/main/binary-iphoneos-arm/Packages."];
    Require(warning || repository, @"unexpected HTTP request (external network is never allowed)");
    @synchronized (Scenario) { ++HTTPRequests; }
    Record(@{@"event":@"fixture-http", @"scenario":Scenario, @"url":url.absoluteString,
        @"method":self.request.HTTPMethod, @"timeout":@(self.request.timeoutInterval), @"headers":self.request.allHTTPHeaderFields ?: @{}});
    if ([Scenario isEqual:@"cancel-pending"] && repository) return;
    if ([Scenario isEqual:@"network-error"] && repository) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
        return;
    }
    NSInteger status = repository && [Scenario isEqual:@"not-repository"] ? 404 : 200;
    NSData *body = warning && [Scenario hasPrefix:@"warning-"] ? [@"Owned test warning: verify trust before adding." dataUsingEncoding:NSUTF8StringEncoding] : [NSData data];
    [self.client URLProtocol:self didReceiveResponse:[[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{}] cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (body.length) [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading { self.stopped = YES; }
@end

@interface SourcesController (FixtureCallbacks)
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button;
@end
@interface RestorationApplication : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, strong) RestorationDatabase *database;
@property(nonatomic, strong) CydiaMoreSourcesProvider *provider;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) SourcesController *observedController;
@property(nonatomic, strong) UIAlertView *observedAlert;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *lastStatus;
@end
@implementation RestorationApplication
- (void)open {
    MoreSourcesController *page = [[MoreSourcesController alloc] initWithProvider:self.provider];
    page.delegate = self;
    [self.navigation pushViewController:page animated:NO];
}
- (void)replay {
    Require(self.observedController != nil && self.observedAlert != nil, @"no real prior callback to replay");
    [self.observedController alertView:self.observedAlert clickedButtonAtIndex:1];
    [self.observedController alertView:self.observedAlert clickedButtonAtIndex:1];
    Record(@{@"event":@"duplicate-callbacks-injected", @"count":@2});
    [self observe];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    Scenario = NSProcessInfo.processInfo.environment[@"RESTORATION_SCENARIO"] ?: @"cancel";
    Require(([@[@"cancel", @"accept", @"warning-cancel", @"warning-add", @"not-repository", @"network-error", @"cancel-pending", @"readonly"] containsObject:Scenario]), @"finite scenario");
    FixtureRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"source-fixture-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    Require([[NSFileManager defaultManager] createDirectoryAtPath:FixtureRoot withIntermediateDirectories:NO attributes:nil error:nil], @"create fixture");
    Parts = [FixtureRoot fileSystemRepresentation]; Managed = Parts + "/managed.list";
    Cache_ = FixtureRoot;
    Require([Unowned writeToFile:[NSString stringWithUTF8String:Managed.c_str()] atomically:YES encoding:NSUTF8StringEncoding error:nil], @"write preimage");
    Sources_ = [NSMutableDictionary dictionary];
    CydiaSetManagedSourceListPath([Scenario isEqual:@"readonly"] ? nil : [NSString stringWithUTF8String:Managed.c_str()]);
    Require(CydiaCanEditManagedSources() == ![Scenario isEqual:@"readonly"], @"real production edit policy");
    [NSURLProtocol registerClass:RestorationProtocol.class];
    self.database = [RestorationDatabase new]; self.provider = [[CydiaMoreSourcesProvider alloc] initWithDatabase:(id)self.database];
    UIViewController *root = [UIViewController new]; root.title = @"Fixture"; root.view.backgroundColor = UIColor.whiteColor;
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(16, 100, 343, 220)]; self.status.numberOfLines = 0;
    self.status.accessibilityIdentifier = @"restoration.status"; [root.view addSubview:self.status];
    UIButton *open = [UIButton buttonWithType:UIButtonTypeSystem]; open.frame = CGRectMake(16, 340, 343, 50);
    [open setTitle:@"Open More Sources" forState:UIControlStateNormal]; open.accessibilityIdentifier = @"restoration.open";
    [open addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside]; [root.view addSubview:open];
    UIButton *replay = [UIButton buttonWithType:UIButtonTypeSystem]; replay.frame = CGRectMake(16, 410, 343, 50);
    [replay setTitle:@"Replay prior callback twice" forState:UIControlStateNormal]; replay.accessibilityIdentifier = @"restoration.replay";
    [replay addTarget:self action:@selector(replay) forControlEvents:UIControlEventTouchUpInside]; [root.view addSubview:replay];
    self.navigation = [[UINavigationController alloc] initWithRootViewController:root];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController = self.navigation;
    [self.window makeKeyAndVisible]; [self open];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(observe) userInfo:nil repeats:YES];
    Record(@{@"event":@"start", @"scenario":Scenario, @"fixture":FixtureRoot, @"unowned":Unowned});
    return YES;
}
- (void)observe {
    id controller = [self.provider valueForKey:@"restoration"];
    if (controller) {
        Ivar ivar = class_getInstanceVariable([SourcesController class], "restorationAlert_");
        UIAlertView *alert = object_getIvar(controller, ivar);
        // Retention deliberately changes lifetime for replay fault injection.
        // Do not retain dismissed UIAlertViews in the background lifecycle case.
        BOOL replayCase = [@[@"cancel", @"accept", @"warning-cancel", @"warning-add"] containsObject:Scenario];
        if (alert && replayCase) { self.observedController = controller; self.observedAlert = alert; }
    }
    NSString *contents = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:Managed.c_str()] encoding:NSUTF8StringEncoding error:nil];
    Require([contents hasPrefix:Unowned], @"unowned source bytes changed");
    NSString *status = [NSString stringWithFormat:@"Adds:%lu Syncs:%lu Installs:%lu Network:%lu HTTP:%lu\nUnowned:unchanged\n%@",
        (unsigned long)Adds, (unsigned long)Syncs, (unsigned long)FileInstalls, (unsigned long)NetworkBalance, (unsigned long)HTTPRequests, Scenario];
    self.status.text = status;
    if (![status isEqual:self.lastStatus]) {
        self.lastStatus = status;
        Record(@{@"event":@"state", @"scenario":Scenario, @"adds":@(Adds), @"syncs":@(Syncs), @"installs":@(FileInstalls),
            @"network":@(NetworkBalance), @"http":@(HTTPRequests), @"contents":contents ?: @""});
    }
}
- (void)addSource:(NSDictionary *)source {
    ++Adds; CydiaAddSource(source); Record(@{@"event":@"production-add-delegate", @"source":source});
}
- (void)addTrivialSource:(NSString *)href { Require(NO, @"restoration incorrectly flattened stable/main"); }
- (void)syncData { ++Syncs; Require(CydiaWriteSources(), @"actual managed writer failed"); [self observe]; }
- (id)addProgressHUD { return [RestorationHUD new]; }
- (void)removeProgressHUD:(id)hud { }
- (void)retainNetworkActivityIndicator { ++NetworkBalance; }
- (void)releaseNetworkActivityIndicator { Require(NetworkBalance > 0, @"unbalanced network lifetime"); --NetworkBalance; }
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(RestorationApplication.class)); }
}
