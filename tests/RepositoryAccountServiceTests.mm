/* Exercises the production account-service implementation with test-only
 * platform substitutes. All identifiers and tokens below are synthetic. */
#import "Cydia/RepositoryAccountService.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <Security/Security.h>
#import "Cydia/AppState.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

static NSMutableDictionary<NSString *, NSData *> *credentialData;
static NSMutableArray<ASWebAuthenticationSession *> *browserSessions;
static NSUInteger storedTokens, deletedTokens, deviceCalls;
static BOOL storeFails, deleteFails, browserStarts = YES;
static NSString *const SyntheticToken = @"fixture-account-token-aaaaaaaa";
static NSString *const SyntheticSecondToken = @"fixture-account-token-bbbbbbbb";
static NSString *const SyntheticDevice = @"fixture-device-identifier";
static NSString *const SyntheticModel = @"FixturePhone1,1";

static void Require(bool condition, const char *message) {
    if (!condition) { std::fprintf(stderr, "[repository-account][FAIL] %s\n", message); std::exit(1); }
}
static void Main(void (^operation)(void)) {
    if (NSThread.isMainThread) operation();
    else dispatch_sync(dispatch_get_main_queue(), operation);
}
static void Await(BOOL (^condition)(void), const char *message) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (true) {
        __block BOOL done = NO; Main(^{ done = condition(); });
        if (done) return;
        if (std::chrono::steady_clock::now() >= deadline) Require(false, message);
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
static NSString *StorageKey(NSDictionary *query) {
    Require([query[@"service"] isEqual:@"com.saurik.Cydia.repository-account.v1"], "credential service escaped fixture scope");
    NSString *key = query[@"account"];
    Require([key isKindOfClass:NSString.class] && key.length, "credential scope missing"); return key;
}
static NSString *AccountKey(CydiaRepositoryAccount *account) {
    return [NSString stringWithFormat:@"%@\n%@", account.sourceURL.absoluteString, account.providerURL.absoluteString];
}
static void SeedToken(CydiaRepositoryAccount *account, NSString *token) {
    credentialData[AccountKey(account)] = [NSJSONSerialization dataWithJSONObject:@{@"token": token} options:0 error:nil];
}
static NSString *StoredToken(CydiaRepositoryAccount *account) {
    NSData *data = credentialData[AccountKey(account)];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil][@"token"] : nil;
}
OSStatus CydiaTestSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    Require(NSThread.isMainThread, "credential read escaped main queue");
    NSData *data = credentialData[StorageKey((__bridge NSDictionary *)query)];
    if (!data) return errSecItemNotFound;
    if (result) *result = CFBridgingRetain(data); return errSecSuccess;
}
OSStatus CydiaTestSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    Require(NSThread.isMainThread, "credential update escaped main queue");
    if (storeFails) return -1;
    NSString *key = StorageKey((__bridge NSDictionary *)query);
    if (!credentialData[key]) return errSecItemNotFound;
    NSDictionary *values = (__bridge NSDictionary *)attributes;
    Require([values[@"accessible"] isEqual:@"unlocked-device-only"], "credential accessibility weakened");
    credentialData[key] = values[@"data"]; ++storedTokens; return errSecSuccess;
}
OSStatus CydiaTestSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    Require(NSThread.isMainThread, "credential addition escaped main queue");
    if (storeFails) return -1;
    NSDictionary *values = (__bridge NSDictionary *)attributes;
    Require([values[@"accessible"] isEqual:@"unlocked-device-only"], "credential accessibility weakened");
    credentialData[StorageKey(values)] = values[@"data"]; ++storedTokens; return errSecSuccess;
}
OSStatus CydiaTestSecItemDelete(CFDictionaryRef query) {
    Require(NSThread.isMainThread, "credential deletion escaped main queue");
    if (deleteFails) return -1;
    NSString *key = StorageKey((__bridge NSDictionary *)query);
    if (!credentialData[key]) return errSecItemNotFound;
    [credentialData removeObjectForKey:key]; ++deletedTokens; return errSecSuccess;
}
NSString *UniqueIdentifier(UIDevice *) { Require(false, "real device identifier entry reached"); return nil; }
NSDictionary *CydiaRepositoryAccountTestDeviceFields(void) {
    Require(NSThread.isMainThread, "device fields escaped main queue"); ++deviceCalls;
    return @{@"udid": SyntheticDevice, @"device": SyntheticModel};
}
@implementation UIWindow
@end
@implementation UIView
@end
@implementation UIViewController
@end
@implementation ASWebAuthenticationSession
- (instancetype)initWithURL:(NSURL *)URL callbackURLScheme:(NSString *)scheme completionHandler:(void (^)(NSURL *, NSError *))completion {
    if ((self = [super init])) {
        _testURL = [URL copy]; _testScheme = [scheme copy]; _testCompletion = [completion copy];
        [browserSessions addObject:self];
    } return self;
}
- (BOOL)start { ++_testStarts; return browserStarts; }
- (void)cancel { ++_testCancels; [self testEmitURL:nil error:[NSError errorWithDomain:@"FixtureBrowser" code:1 userInfo:nil]]; }
- (void)testEmitURL:(NSURL *)URL error:(NSError *)error { if (_testCompletion) _testCompletion(URL, error); }
@end

@interface CydiaRepositoryAccountService (FixturePrivate)
- (void)request:(NSURL *)URL body:(NSDictionary *)body completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion;
@end
@interface CydiaAccountRequest : NSObject
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic) NSUInteger redirects;
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion;
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
    completionHandler:(void (^)(NSURLSessionResponseDisposition))completion;
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data;
@end
@interface FixtureRequest : NSObject
@property(nonatomic, copy) NSURL *URL;
@property(nonatomic, copy) NSDictionary *body;
@property(nonatomic, copy) void (^completion)(NSData *, NSHTTPURLResponse *, NSError *);
@end
@implementation FixtureRequest
@end
@interface FixtureService : CydiaRepositoryAccountService
@property(nonatomic, strong) NSMutableArray<FixtureRequest *> *requests;
@end
@implementation FixtureService
- (instancetype)init { if ((self = [super init])) _requests = [NSMutableArray array]; return self; }
- (void)request:(NSURL *)URL body:(NSDictionary *)body completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    Require(NSThread.isMainThread, "service transport escaped main queue");
    FixtureRequest *request = [FixtureRequest new]; request.URL = URL;
    request.body = body ? [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]
        options:0 error:nil] : nil;
    request.completion = completion; [_requests addObject:request];
}
@end
@interface FixtureTask : NSObject
@property(nonatomic, strong) NSURLRequest *originalRequest;
@property(nonatomic) NSUInteger cancellations;
- (void)cancel;
@end
@implementation FixtureTask
- (void)cancel { ++_cancellations; }
@end

static void Reset(void) {
    Main(^{ credentialData = [NSMutableDictionary dictionary]; browserSessions = [NSMutableArray array];
        storedTokens = deletedTokens = deviceCalls = 0; storeFails = deleteFails = NO; browserStarts = YES; });
}
static FixtureRequest *Take(FixtureService *service, NSString *suffix) {
    __block FixtureRequest *result = nil;
    Main(^{
        Require(service.requests.count != 0, "expected service request was not made");
        result = service.requests.firstObject; [service.requests removeObjectAtIndex:0];
        Require([result.URL.absoluteString hasSuffix:suffix], "service request used a different endpoint");
    }); return result;
}
static void RespondData(FixtureRequest *request, NSData *data, NSInteger status, NSError *error = nil) {
    Main(^{
        void (^completion)(NSData *, NSHTTPURLResponse *, NSError *) = request.completion;
        Require(completion != nil, "fixture response replayed transport completion"); request.completion = nil;
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        completion(data, response, error);
    });
}
static void Respond(FixtureRequest *request, NSDictionary *object, NSInteger status = 200) {
    RespondData(request, object ? [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] : nil, status);
}
static UIViewController *Presenter(void) {
    UIViewController *presenter = [UIViewController new]; presenter.view = [UIView new]; presenter.view.window = [UIWindow new]; return presenter;
}
static CydiaRepositoryAccount *Discover(FixtureService *service, NSString *source, NSString *provider) {
    __block CydiaRepositoryAccount *account = nil; __block NSError *failure = nil;
    Main(^{ [service discoverSource:[NSURL URLWithString:source] name:@"Fixture source" completion:^(CydiaRepositoryAccount *value, NSError *error) {
        account = value; failure = error;
    }]; });
    FixtureRequest *endpoint = Take(service, @"/payment_endpoint");
    Require(endpoint.body == nil, "public endpoint discovery sent account/device fields");
    RespondData(endpoint, [provider dataUsingEncoding:NSUTF8StringEncoding], 200);
    FixtureRequest *info = Take(service, @"/info");
    Require(info.body == nil, "public provider discovery sent account/device fields");
    Respond(info, @{@"name": @"Fixture vendor"});
    Require(account != nil && failure == nil, "valid fixture account discovery failed"); return account;
}
static NSURL *Callback(NSString *token) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"sileo://authentication_success?token=%@", token]];
}
static ASWebAuthenticationSession *LastBrowser(void) {
    __block ASWebAuthenticationSession *session; Main(^{ session = browserSessions.lastObject; });
    Require(session != nil, "authentication browser was not created"); return session;
}
static FixtureRequest *BeginValidation(FixtureService *service, CydiaRepositoryAccount *account,
    UIViewController *presenter, NSString *token, void (^completion)(NSError *)) {
    Main(^{ [service signIn:account presenter:presenter completion:completion]; });
    ASWebAuthenticationSession *session = LastBrowser();
    Main(^{
        Require([session.testScheme isEqual:@"sileo"] && session.testStarts == 1, "auth browser session contract changed");
        NSURLComponents *URL = [NSURLComponents componentsWithURL:session.testURL resolvingAgainstBaseURL:NO];
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in URL.queryItems) fields[item.name] = item.value;
        Require([fields[@"udid"] isEqual:SyntheticDevice] && [fields[@"model"] isEqual:SyntheticModel], "synthetic device consent fields changed");
        [session testEmitURL:Callback(token) error:nil];
    });
    Await(^BOOL { return service.requests.count != 0; }, "auth callback did not validate with provider");
    FixtureRequest *validation = Take(service, @"/user_info");
    Require([validation.body[@"token"] isEqual:token] && [validation.body[@"udid"] isEqual:SyntheticDevice] &&
        [validation.body[@"device"] isEqual:SyntheticModel], "auth server validation omitted exact callback/device binding");
    return validation;
}

static void DiscoveryAndEndpointScope(void) {
    Reset(); __block FixtureService *service; Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor-a.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken); });
    auto changed = Discover(service, @"https://source.example.invalid/", @"https://vendor-b.example.invalid/");
    __block NSUInteger completed = 0, beforeAnonymousDeviceCalls = 0;
    Main(^{
        Require(!changed.signedIn && account.signedIn, "changed endpoint reused another provider token");
        Require(deviceCalls == 0, "public discovery consulted device identity");
        [service userInfo:changed completion:^(NSDictionary *info, NSError *error) {
            Require(info == nil && error.code == CydiaAccountErrorAuthentication, "changed endpoint did not require fresh login"); ++completed;
        }];
        Require(service.requests.count == 0 && completed == 1, "changed endpoint sent another provider credentials");
        beforeAnonymousDeviceCalls = deviceCalls;
        [service anonymousPackageInfo:@"fixture.package" account:changed completion:^(NSDictionary *info, NSError *error) {
            Require(error == nil && [info[@"available"] isEqual:@YES], "anonymous package information failed"); ++completed;
        }];
    });
    FixtureRequest *anonymous = Take(service, @"/package/fixture.package/info");
    Require(anonymous.body.count == 0, "anonymous package request sent account/device fields");
    Respond(anonymous, @{@"available": @YES});
    Main(^{ Require(completed == 2 && deviceCalls == beforeAnonymousDeviceCalls, "anonymous discovery consulted device identity"); });
}
static void ValidAuthenticationAndReplay(void) {
    Reset(); __block FixtureService *service; __block UIViewController *presenter;
    Main(^{ service = [FixtureService new]; presenter = Presenter(); });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    __block NSUInteger completed = 0; __block NSError *failure;
    auto validation = BeginValidation(service, account, presenter, SyntheticToken, ^(NSError *error) { failure = error; ++completed; });
    Main(^{ Require(storedTokens == 0 && !account.signedIn, "unvalidated auth callback stored credentials");
        [LastBrowser() testEmitURL:Callback(SyntheticSecondToken) error:nil]; });
    Main(^{ Require(service.requests.count == 0, "auth callback replay scheduled another validation"); });
    Respond(validation, @{@"user": @{@"name": @"Fixture user"}});
    Await(^BOOL { return completed == 1; }, "validated auth callback did not settle once");
    Main(^{ Require(failure == nil && storedTokens == 1 && [StoredToken(account) isEqual:SyntheticToken], "valid auth did not store exact scoped token");
        [LastBrowser() testEmitURL:Callback(SyntheticSecondToken) error:nil]; });
    Main(^{ Require(completed == 1 && storedTokens == 1 && service.requests.count == 0, "settled callback replay stored credentials"); });
}
static void InvalidAuthenticationCallbacks(void) {
    NSString *oversize = [@"x" stringByPaddingToLength:8193 withString:@"x" startingAtIndex:0];
    NSArray<NSString *> *invalid = @[@"other://authentication_success?token=fixture", @"sileo://other?token=fixture",
        @"sileo://authentication_success/path?token=fixture", @"sileo://authentication_success:9?token=fixture",
        @"sileo://user@authentication_success?token=fixture", @"sileo://authentication_success?token=fixture#fragment",
        @"sileo://authentication_success?token=fixture&token=duplicate", @"sileo://authentication_success?token=",
        @"sileo://authentication_success?payment_secret=ignored",
        [NSString stringWithFormat:@"sileo://authentication_success?token=%@", oversize]];
    for (NSString *URL in invalid) {
        Reset(); __block FixtureService *service; __block UIViewController *presenter;
        Main(^{ service = [FixtureService new]; presenter = Presenter(); });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        __block NSUInteger completed = 0; __block NSError *failure;
        Main(^{ [service signIn:account presenter:presenter completion:^(NSError *error) { failure = error; ++completed; }];
            [LastBrowser() testEmitURL:[NSURL URLWithString:URL] error:nil]; });
        Await(^BOOL { return completed == 1; }, "invalid callback did not settle");
        Main(^{ Require(failure.code == CydiaAccountErrorInvalidResponse && storedTokens == 0 && service.requests.count == 0,
            "invalid callback reached provider or credential storage"); });
    }
}
static void BrowserFailureAndCancellation(void) {
    for (BOOL startFails : {YES, NO}) {
        Reset(); __block FixtureService *service; __block UIViewController *presenter;
        Main(^{ service = [FixtureService new]; presenter = Presenter(); browserStarts = !startFails; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        __block NSUInteger completed = 0; __block NSError *failure;
        Main(^{ [service signIn:account presenter:presenter completion:^(NSError *error) { failure = error; ++completed; }];
            if (!startFails) [LastBrowser() testEmitURL:nil error:[NSError errorWithDomain:@"FixtureBrowser" code:1 userInfo:nil]]; });
        Await(^BOOL { return completed == 1; }, "browser start/cancel did not settle");
        Main(^{ Require(failure.code == (startFails ? CydiaAccountErrorUnavailable : CydiaAccountErrorAuthentication), "browser failure classified incorrectly");
            [LastBrowser() testEmitURL:Callback(SyntheticToken) error:nil]; });
        Main(^{ Require(completed == 1 && storedTokens == 0 && service.requests.count == 0, "late cancelled callback stored token"); });
    }
}
static void LogoutAndNewLoginRaces(void) {
    Reset(); __block FixtureService *service; __block UIViewController *presenter;
    Main(^{ service = [FixtureService new]; presenter = Presenter(); });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    __block NSUInteger oldCompleted = 0, newCompleted = 0, logoutCompleted = 0;
    __block NSError *oldFailure, *newFailure;
    auto oldValidation = BeginValidation(service, account, presenter, SyntheticToken,
        ^(NSError *error) { oldFailure = error; ++oldCompleted; });
    auto oldBrowser = LastBrowser();
    Main(^{ [service signOut:account completion:^(NSError *error) { Require(error == nil, "empty credential logout failed"); ++logoutCompleted; }]; });
    Await(^BOOL { return oldCompleted == 1; }, "logout did not cancel auth validation");
    Main(^{ Require(oldBrowser.testCancels == 0 && oldFailure.code == CydiaAccountErrorAuthentication && logoutCompleted == 1,
        "logout did not settle callback-owned validation"); });
    auto newValidation = BeginValidation(service, account, presenter, SyntheticSecondToken,
        ^(NSError *error) { newFailure = error; ++newCompleted; });
    Respond(oldValidation, @{@"user": @{}});
    Main(^{ Require(storedTokens == 0 && newCompleted == 0 && oldCompleted == 1, "old validation stole a new login or stored late token");
        [oldBrowser testEmitURL:Callback(SyntheticToken) error:nil]; });
    Respond(newValidation, @{@"user": @{}});
    Await(^BOOL { return newCompleted == 1; }, "new auth validation did not settle");
    Main(^{ Require(newFailure == nil && [StoredToken(account) isEqual:SyntheticSecondToken] && storedTokens == 1,
        "new login did not own its exact scoped token"); });
    __block NSUInteger signOutCompleted = 0;
    Main(^{ [service signOut:account completion:^(NSError *error) { Require(error == nil, "signed-in logout failed"); ++signOutCompleted; }];
        Require(!account.signedIn && deletedTokens == 1, "logout did not remove local token before remote request"); });
    FixtureRequest *signOut = Take(service, @"/sign_out");
    Require(signOut.body.count == 1 && [signOut.body[@"token"] isEqual:SyntheticSecondToken], "logout transmitted device fields or wrong token");
    Respond(signOut, @{@"success": @YES});
    Main(^{ Require(signOutCompleted == 1 && storedTokens == 1, "logout did not settle once"); });
}
static void LogoutBeforeBrowserCallback(void) {
    Reset(); __block FixtureService *service; __block UIViewController *presenter;
    Main(^{ service = [FixtureService new]; presenter = Presenter(); });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    __block NSUInteger completed = 0;
    Main(^{ [service signIn:account presenter:presenter completion:^(NSError *error) { Require(error.code == CydiaAccountErrorAuthentication,
        "logout did not fail active auth"); ++completed; }]; });
    auto browser = LastBrowser();
    Main(^{ [service signOut:account completion:^(NSError *error) { Require(error == nil, "empty logout failed"); }];
        Require(browser.testCancels == 1, "logout did not cancel active browser");
        [browser testEmitURL:Callback(SyntheticToken) error:nil]; });
    Await(^BOOL { return completed == 1; }, "browser logout did not settle");
    Main(^{ Require(storedTokens == 0 && service.requests.count == 0, "cancelled browser callback stored token"); });
}
static void StoreAndServerValidationFailures(void) {
    for (BOOL storageFailure : {YES, NO}) {
        Reset(); __block FixtureService *service; __block UIViewController *presenter;
        Main(^{ service = [FixtureService new]; presenter = Presenter(); storeFails = storageFailure; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        __block NSUInteger completed = 0; __block NSError *failure;
        auto validation = BeginValidation(service, account, presenter, SyntheticToken,
            ^(NSError *error) { failure = error; ++completed; });
        Respond(validation, storageFailure ? @{@"user": @{}} : @{@"user": @"malformed"});
        Await(^BOOL { return completed == 1; }, "auth storage/server failure did not settle");
        Main(^{ Require(failure.code == (storageFailure ? CydiaAccountErrorKeychain : CydiaAccountErrorInvalidResponse) &&
            storedTokens == 0 && !account.signedIn, "failed storage/server validation created signed-in account"); });
    }
}
static void InvalidationScope(void) {
    Reset(); __block FixtureService *service; Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    auto other = Discover(service, @"https://another-source.example.invalid/", @"https://vendor.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken); SeedToken(other, SyntheticSecondToken); });
    __block NSUInteger completed = 0; __block NSError *failure;
    Main(^{ [service userInfo:account completion:^(NSDictionary *info, NSError *error) { failure = error; ++completed; }]; });
    auto request = Take(service, @"/user_info");
    Respond(request, @{@"invalidate": @YES, @"error": @"Fixture revoked account"}, 403);
    Main(^{ Require(completed == 1 && failure.code == CydiaAccountErrorAuthentication && !account.signedIn && other.signedIn &&
        deletedTokens == 1, "invalidation crossed source/account scope"); });
    Main(^{ SeedToken(account, SyntheticToken); [service userInfo:account completion:^(NSDictionary *info, NSError *error) { ++completed; }]; });
    auto stale = Take(service, @"/user_info");
    Main(^{ [service signOut:account completion:^(NSError *error) {}]; SeedToken(account, SyntheticSecondToken); });
    auto signOut = Take(service, @"/sign_out");
    Respond(stale, @{@"invalidate": @YES, @"error": @"Fixture old response"}, 403);
    Main(^{ Require([StoredToken(account) isEqual:SyntheticSecondToken] && other.signedIn && deletedTokens == 2,
        "stale invalidation deleted replacement credentials"); });
    Respond(signOut, @{@"success": @YES});
}
static void ExactGrantAndFailures(void) {
    Reset(); __block FixtureService *service; Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken); });
    __block CydiaRepositoryDownloadGrant *grant; __block NSError *failure; __block NSUInteger completed = 0;
    Main(^{ [service authorizePackage:@"fixture.package" version:@"2:1.4-1" architecture:@"iphoneos-arm64e" account:account
        completion:^(CydiaRepositoryDownloadGrant *value, NSError *error) { grant = value; failure = error; ++completed; }]; });
    auto request = Take(service, @"/package/fixture.package/authorize_download");
    Require([request.body[@"version"] isEqual:@"2:1.4-1"] && [request.body[@"architecture"] isEqual:@"iphoneos-arm64e"] &&
        [request.body[@"repo"] isEqual:account.sourceURL.absoluteString] && [request.body[@"token"] isEqual:SyntheticToken],
        "grant request changed exact selected identity");
    NSString *transport = @"https://cdn.example.invalid/archive?grant=fixture-temporary-capability";
    Respond(request, @{@"url": transport});
    Main(^{ Require(completed == 1 && failure == nil && [grant.package isEqual:@"fixture.package"] &&
        [grant.version isEqual:@"2:1.4-1"] && [grant.architecture isEqual:@"iphoneos-arm64e"] &&
        [grant.sourceURL isEqual:account.sourceURL] && [grant.transportURL.absoluteString isEqual:transport] && grant.obtainedAt != nil,
        "download grant lost exact owning selection");
        Require(![grant.description containsString:@"fixture-temporary-capability"] && ![grant.debugDescription containsString:SyntheticToken] &&
            ![account.description containsString:SyntheticToken], "grant/account description exposed secrets"); });
    NSArray<NSString *> *unsafe = @[@"http://cdn.example.invalid/archive", @"https://user:pass@cdn.example.invalid/archive",
        @"https://cdn.example.invalid/archive#fragment",
        [NSString stringWithFormat:@"https://cdn.example.invalid/archive?token=%@", SyntheticToken],
        @"https://cdn.example.invalid/archive?token=fixture%2Daccount%2Dtoken%2Daaaaaaaa"];
    for (NSString *URL in unsafe) {
        Main(^{ grant = nil; failure = nil; [service authorizePackage:@"fixture.package" version:@"2:1.4-1" architecture:@"iphoneos-arm64e" account:account
            completion:^(CydiaRepositoryDownloadGrant *value, NSError *error) { grant = value; failure = error; ++completed; }]; });
        Respond(Take(service, @"/authorize_download"), @{@"url": URL});
        Main(^{ Require(grant == nil && failure != nil, "unsafe or credential-leaking grant accepted"); });
    }
    Main(^{ grant = nil; failure = nil; [service authorizePackage:@"fixture.package" version:@"2:1.4-1" architecture:@"iphoneos-arm64e" account:account
        completion:^(CydiaRepositoryDownloadGrant *value, NSError *error) { grant = value; failure = error; ++completed; }]; });
    auto pending = Take(service, @"/authorize_download");
    Main(^{ [service signOut:account completion:^(NSError *error) {}]; });
    auto signOut = Take(service, @"/sign_out");
    Respond(pending, @{@"url": transport});
    Main(^{ Require(grant == nil && failure.code == CydiaAccountErrorAuthentication, "grant survived logout/generation change"); });
    Respond(signOut, @{@"success": @YES});
}
static void MutableGrantSelectionSnapshot(void) {
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    __block NSMutableString *package, *version, *architecture;
    __block CydiaRepositoryDownloadGrant *grant; __block NSError *failure;
    Main(^{
        SeedToken(account, SyntheticToken);
        package = [@"fixture.package" mutableCopy]; version = [@"2:1.4-1" mutableCopy];
        architecture = [@"iphoneos-arm64e" mutableCopy];
        [service authorizePackage:package version:version architecture:architecture account:account
            completion:^(CydiaRepositoryDownloadGrant *value, NSError *error) { grant = value; failure = error; }];
    });
    auto request = Take(service, @"/package/fixture.package/authorize_download");
    Main(^{
        [package setString:@"different.package"]; [version setString:@"9:9.9"];
        [architecture setString:@"iphoneos-arm"];
    });
    Respond(request, @{@"url": @"https://cdn.example.invalid/archive?grant=fixture-temporary-capability"});
    Main(^{
        Require([request.body[@"version"] isEqual:@"2:1.4-1"] && [request.body[@"architecture"] isEqual:@"iphoneos-arm64e"],
            "fixture did not retain serialized request identity");
        Require(failure == nil && grant != nil && [grant.package isEqual:@"fixture.package"] &&
            [grant.version isEqual:@"2:1.4-1"] && [grant.architecture isEqual:@"iphoneos-arm64e"] &&
            [grant.sourceURL isEqual:account.sourceURL], "mutable caller arguments changed an in-flight grant selection");
    });
}
static void RedirectAndResponseBounds(void) {
    Main(^{
        CydiaAccountRequest *operation = [CydiaAccountRequest new]; operation.URL = [NSURL URLWithString:@"https://vendor.example.invalid/info"];
        FixtureTask *task = [FixtureTask new]; task.originalRequest = [NSURLRequest requestWithURL:operation.URL];
        for (NSUInteger index = 0; index < 4; ++index) {
            __block NSURLRequest *accepted = nil;
            [operation URLSession:nil task:(NSURLSessionTask *)(id)task willPerformHTTPRedirection:nil
                newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://vendor.example.invalid/redirect"]]
                completionHandler:^(NSURLRequest *request) { accepted = request; }];
            Require((accepted != nil) == (index < 3), "GET redirect count is not bounded");
        }
        NSArray<NSString *> *refused = @[@"https://other.example.invalid/redirect", @"http://vendor.example.invalid/redirect",
            @"https://user:pass@vendor.example.invalid/redirect", @"https://vendor.example.invalid/redirect#fragment"];
        for (NSString *URL in refused) {
            operation.redirects = 0; __block NSURLRequest *accepted = nil;
            [operation URLSession:nil task:(NSURLSessionTask *)(id)task willPerformHTTPRedirection:nil
                newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:URL]] completionHandler:^(NSURLRequest *request) { accepted = request; }];
            Require(accepted == nil, "redirect escaped exact secure origin");
        }
        operation.redirects = 0; NSMutableURLRequest *POST = [NSMutableURLRequest requestWithURL:operation.URL]; POST.HTTPMethod = @"POST";
        task.originalRequest = POST; __block NSURLRequest *accepted = nil;
        [operation URLSession:nil task:(NSURLSessionTask *)(id)task willPerformHTTPRedirection:nil
            newRequest:[NSURLRequest requestWithURL:operation.URL] completionHandler:^(NSURLRequest *request) { accepted = request; }];
        Require(accepted == nil, "credential-bearing POST followed a redirect");
        __block NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;
        NSURLResponse *oversize = [[NSURLResponse alloc] initWithURL:operation.URL MIMEType:@"application/json" expectedContentLength:1024 * 1024 + 1 textEncodingName:@"utf-8"];
        [operation URLSession:nil dataTask:(NSURLSessionDataTask *)(id)task didReceiveResponse:oversize completionHandler:^(NSURLSessionResponseDisposition value) { disposition = value; }];
        Require(disposition == NSURLSessionResponseCancel, "oversize declared response accepted");
        operation.data = [NSMutableData dataWithLength:1024 * 1024];
        [operation URLSession:nil dataTask:(NSURLSessionDataTask *)(id)task didReceiveData:[NSData dataWithBytes:"x" length:1]];
        Require(task.cancellations == 1 && operation.data.length == 1024 * 1024, "stream response bound failed");
    });
}
static void UnsupportedIntegrationAndInvalidDiscovery(void) {
    for (NSString *source in @[@"http://source.example.invalid/", @"https://user:pass@source.example.invalid/",
        @"https://source.example.invalid/?query=ignored", @"https://source.example.invalid/#fragment"]) {
        Reset(); __block FixtureService *service; __block NSUInteger completed = 0;
        Main(^{ service = [FixtureService new]; [service discoverSource:[NSURL URLWithString:source] name:@"Fixture source"
            completion:^(CydiaRepositoryAccount *account, NSError *error) {
            Require(account == nil && error.code == CydiaAccountErrorUnsupported, "invalid source discovery was accepted"); ++completed;
        }];
        Require(completed == 1 && service.requests.count == 0 && deviceCalls == 0, "invalid source discovery reached transport/device fields"); });
    }
    Reset(); __block FixtureService *service; __block CydiaRepositoryAccount *account;
    Main(^{ service = [FixtureService new]; [service discoverSource:[NSURL URLWithString:@"https://havoc.app/"] name:@"Fixture unsupported source"
        completion:^(CydiaRepositoryAccount *value, NSError *error) {
        Require(error == nil, "unsupported vendor public discovery failed"); account = value;
    }]; });
    RespondData(Take(service, @"/payment_endpoint"), [@"https://havoc.app/api/" dataUsingEncoding:NSUTF8StringEncoding], 200);
    Main(^{
        Require(account != nil && !account.supportsAccountIntegration && !account.signedIn && service.requests.count == 0,
            "unsupported vendor advertised paid acceptance");
        __block NSUInteger completed = 0;
        [service signIn:account presenter:Presenter() completion:^(NSError *error) {
            Require(error.code == CydiaAccountErrorUnsupported, "unsupported vendor initiated auth"); ++completed;
        }];
        [service authorizePackage:@"fixture.package" version:@"1" architecture:@"iphoneos-arm64" account:account
            completion:^(CydiaRepositoryDownloadGrant *grant, NSError *error) {
            Require(grant == nil && error.code == CydiaAccountErrorUnsupported, "unsupported vendor authorized paid archive"); ++completed;
        }];
        Require(completed == 2 && browserSessions.count == 0 && service.requests.count == 0 && deviceCalls == 0,
            "unsupported paid integration touched browser/transport/device fields");
    });
}
static void Run(void) {
    DiscoveryAndEndpointScope(); ValidAuthenticationAndReplay(); InvalidAuthenticationCallbacks();
    BrowserFailureAndCancellation(); LogoutAndNewLoginRaces(); LogoutBeforeBrowserCallback();
    StoreAndServerValidationFailures(); InvalidationScope(); ExactGrantAndFailures(); MutableGrantSelectionSnapshot(); RedirectAndResponseBounds();
    UnsupportedIntegrationAndInvalidDiscovery();
    std::puts("[repository-account] actual service lifecycle and refusal boundaries passed");
}
int main() {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool { Run(); std::exit(0); }
    });
    /* dispatch_main can retire the physical main thread in a command-line
     * process. Keep Foundation's main run loop alive for UIKit-style calls. */
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (std::chrono::steady_clock::now() < deadline) {
        @autoreleasepool {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
    Require(false, "account fixture main run loop timed out");
}
