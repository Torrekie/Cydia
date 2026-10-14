/* Exercises the production account-service implementation with test-only
 * platform substitutes. All identifiers and tokens below are synthetic. */
#import "Cydia/RepositoryAccountService.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import "Cydia/AppState.h"
#include <chrono>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <thread>

static NSMutableDictionary<NSString *, NSData *> *credentialData;
static NSMutableArray<ASWebAuthenticationSession *> *browserSessions;
static std::atomic<NSUInteger> storedTokens, deletedTokens, storedSecrets, deletedSecrets, secretReads;
static NSUInteger deviceCalls;
static BOOL storeFails, deleteFails, browserStarts = YES;
static BOOL passcodeAvailable = YES;
static OSStatus secretReadStatus = errSecSuccess;
static NSString *const SyntheticToken = @"fixture-account-token-aaaaaaaa";
static NSString *const SyntheticSecondToken = @"fixture-account-token-bbbbbbbb";
static NSString *const SyntheticDevice = @"fixture-device-identifier";
static NSString *const SyntheticModel = @"FixturePhone1,1";
static NSString *const SyntheticSecret = @"fixture-purchase-secret-cccccccc";
@interface CydiaRepositoryAccountService (FixtureCredentialGeneration)
- (NSUUID *)generationForAccount:(CydiaRepositoryAccount *)account advance:(BOOL)advance;
@end

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
    NSString *service = query[@"service"];
    Require([service isEqual:@"com.saurik.Cydia.repository-account.v1"] ||
        [service isEqual:@"com.saurik.Cydia.repository-account.v1.purchase"], "credential service escaped fixture scope");
    NSString *key = query[@"account"];
    Require([key isKindOfClass:NSString.class] && key.length, "credential scope missing");
    return [service hasSuffix:@".purchase"] ? [key stringByAppendingString:@".purchase"] : key;
}
static NSString *AccountKey(CydiaRepositoryAccount *account) {
    return [NSString stringWithFormat:@"%@\n%@", account.sourceURL.absoluteString, account.providerURL.absoluteString];
}
static void SeedToken(CydiaRepositoryAccount *account, NSString *token, NSString *mode = @"legacy",
    CydiaRepositoryAccountService *service = nil) {
    @synchronized (credentialData) {
        credentialData[AccountKey(account)] = [NSJSONSerialization dataWithJSONObject:
            @{@"token": token, @"purchase_auth": mode} options:0 error:nil];
    }
    [account setValue:token forKey:@"token"];
    [account setValue:mode forKey:@"purchaseCredentialMode"];
    if (service) [account setValue:[service generationForAccount:account advance:NO] forKey:@"credentialGeneration"];
}
static void SeedSecret(CydiaRepositoryAccount *account) {
    @synchronized (credentialData) {
        credentialData[[AccountKey(account) stringByAppendingString:@".purchase"]] =
            [SyntheticSecret dataUsingEncoding:NSUTF8StringEncoding];
    }
}
static NSString *StoredToken(CydiaRepositoryAccount *account) {
    @synchronized (credentialData) {
        NSData *data = credentialData[AccountKey(account)];
        return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil][@"token"] : nil;
    }
}
OSStatus CydiaTestSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    Require(!NSThread.isMainThread, "credential read blocked main queue");
    NSDictionary *values = (__bridge NSDictionary *)query;
    NSString *key = StorageKey(values);
    @synchronized (credentialData) {
        if ([key hasSuffix:@".purchase"]) {
            ++secretReads;
            Require([values[@"authentication-context"] isKindOfClass:LAContext.class] &&
                [values[@"operation-prompt"] isKindOfClass:NSString.class] &&
                [values[@"operation-prompt"] length] != 0, "purchase secret read omitted user presence context/prompt");
            if (secretReadStatus != errSecSuccess) return secretReadStatus;
        }
        NSData *data = credentialData[key];
        if (!data) return errSecItemNotFound;
        if (result) *result = CFBridgingRetain(data);
    }
    return errSecSuccess;
}
static void CheckCredentialAttributes(NSDictionary *values, BOOL secret) {
    if (secret) {
        NSDictionary *control = values[@"access-control"];
        Require([control isKindOfClass:NSDictionary.class] &&
            [control[@"protection"] isEqual:@"passcode-device-only"] &&
            [control[@"flags"] unsignedLongLongValue] == kSecAccessControlUserPresence,
            "purchase secret lost passcode/device-only user-presence protection");
        Require(values[@"accessible"] == nil, "protected credential used conflicting accessibility attribute");
    } else Require([values[@"accessible"] isEqual:@"unlocked-device-only"], "credential accessibility weakened");
}
OSStatus CydiaTestSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    Require(!NSThread.isMainThread, "credential update blocked main queue");
    if (storeFails) return -1;
    NSString *key = StorageKey((__bridge NSDictionary *)query);
    NSDictionary *values = (__bridge NSDictionary *)attributes;
    BOOL secret = [key hasSuffix:@".purchase"];
    CheckCredentialAttributes(values, secret);
    @synchronized (credentialData) {
        if (!credentialData[key]) return errSecItemNotFound;
        credentialData[key] = values[@"data"];
        if (secret) ++storedSecrets; else ++storedTokens;
    }
    return errSecSuccess;
}
OSStatus CydiaTestSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    Require(!NSThread.isMainThread, "credential addition blocked main queue");
    if (storeFails) return -1;
    NSDictionary *values = (__bridge NSDictionary *)attributes;
    NSString *key = StorageKey(values); BOOL secret = [key hasSuffix:@".purchase"];
    CheckCredentialAttributes(values, secret);
    @synchronized (credentialData) {
        credentialData[key] = values[@"data"];
        if (secret) ++storedSecrets; else ++storedTokens;
    }
    return errSecSuccess;
}
OSStatus CydiaTestSecItemDelete(CFDictionaryRef query) {
    Require(!NSThread.isMainThread, "credential deletion blocked main queue");
    if (deleteFails) return -1;
    NSString *key = StorageKey((__bridge NSDictionary *)query);
    @synchronized (credentialData) {
        if (!credentialData[key]) return errSecItemNotFound;
        [credentialData removeObjectForKey:key];
        if ([key hasSuffix:@".purchase"]) ++deletedSecrets; else ++deletedTokens;
    }
    return errSecSuccess;
}
SecAccessControlRef CydiaTestSecAccessControlCreateWithFlags(CFAllocatorRef allocator,
    CFTypeRef protection, SecAccessControlCreateFlags flags, CFErrorRef *error) {
    Require(!NSThread.isMainThread, "credential protection creation blocked main queue");
    return (SecAccessControlRef)CFBridgingRetain(@{@"protection": (__bridge id)protection, @"flags": @(flags)});
}
@implementation LAContext
- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError **)error {
    Require(policy == LAPolicyDeviceOwnerAuthentication, "purchase used an unexpected authentication policy");
    if (!passcodeAvailable && error) *error = [NSError errorWithDomain:LAErrorDomain code:LAErrorPasscodeNotSet userInfo:nil];
    return passcodeAvailable;
}
- (void)invalidate {}
@end
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
        storedTokens = deletedTokens = storedSecrets = deletedSecrets = secretReads = deviceCalls = 0;
        storeFails = deleteFails = NO; browserStarts = passcodeAvailable = YES; secretReadStatus = errSecSuccess;
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.saurik.Cydia.repository-account-fixtures"];
        [defaults removeObjectForKey:@"RepositoryAccounts.v1"]; [defaults removeObjectForKey:@"RepositoryPurchases.v1"];
    });
}
static FixtureRequest *Take(FixtureService *service, NSString *suffix) {
    Await(^BOOL { return service.requests.count != 0; }, "expected service request was not made");
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
    Await(^BOOL { return account != nil || failure != nil; }, "account discovery did not complete after credential load");
    Require(account != nil && failure == nil, "valid fixture account discovery failed"); return account;
}
static NSURL *Callback(NSString *token, NSString *secret = nil) {
    NSString *URL = [NSString stringWithFormat:@"sileo://authentication_success?token=%@", token];
    if (secret) URL = [URL stringByAppendingFormat:@"&payment_secret=%@", secret];
    return [NSURL URLWithString:URL];
}
static ASWebAuthenticationSession *LastBrowser(void) {
    __block ASWebAuthenticationSession *session; Main(^{ session = browserSessions.lastObject; });
    Require(session != nil, "authentication browser was not created"); return session;
}
static FixtureRequest *BeginValidation(FixtureService *service, CydiaRepositoryAccount *account,
    UIViewController *presenter, NSString *token, void (^completion)(NSError *), NSString *secret = nil) {
    Main(^{ [service signIn:account presenter:presenter completion:completion]; });
    ASWebAuthenticationSession *session = LastBrowser();
    Main(^{
        Require([session.testScheme isEqual:@"sileo"] && session.testStarts == 1, "auth browser session contract changed");
        NSURLComponents *URL = [NSURLComponents componentsWithURL:session.testURL resolvingAgainstBaseURL:NO];
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in URL.queryItems) fields[item.name] = item.value;
        Require([fields[@"udid"] isEqual:SyntheticDevice] && [fields[@"model"] isEqual:SyntheticModel], "synthetic device consent fields changed");
        [session testEmitURL:Callback(token, secret) error:nil];
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
    Await(^BOOL { return oldCompleted == 1 && logoutCompleted == 1; }, "logout did not cancel auth validation");
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
        Require(!account.signedIn, "logout did not immediately clear cached token"); });
    FixtureRequest *signOut = Take(service, @"/sign_out");
    Main(^{ Require(deletedTokens == 1, "logout did not remove local token before remote request"); });
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
static void SuccessfulHTTPInvalidationRefusesNewCredentials(void) {
    Reset(); __block FixtureService *service; __block UIViewController *presenter;
    Main(^{ service = [FixtureService new]; presenter = Presenter(); });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken, @"protected"); SeedSecret(account); });
    __block NSUInteger completed = 0; __block NSError *failure;
    auto validation = BeginValidation(service, account, presenter, SyntheticSecondToken,
        ^(NSError *error) { failure = error; ++completed; }, @"fixture-new-purchase-secret-dddddddd");
    Respond(validation, @{@"user": @{@"name": @"Fixture replacement user"}, @"invalidate": @YES}, 200);
    Await(^BOOL { return completed == 1; }, "successful HTTP invalidation did not settle login refusal");
    Main(^{
        Require(failure.code == CydiaAccountErrorAuthentication && storedTokens == 0 && storedSecrets == 0 &&
            deletedTokens == 0 && deletedSecrets == 0 && [StoredToken(account) isEqual:SyntheticToken] &&
            service.requests.count == 0 && secretReads == 0,
            "HTTP 200 invalidate stored new credentials or purged a different previously valid token");
        @synchronized (credentialData) {
            NSData *secret = credentialData[[AccountKey(account) stringByAppendingString:@".purchase"]];
            Require([[[NSString alloc] initWithData:secret encoding:NSUTF8StringEncoding] isEqual:SyntheticSecret],
                "invalid replacement login changed earlier purchase authority");
        }
    });
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
    Await(^BOOL { return completed == 1 && deletedTokens == 1; }, "account invalidation did not settle");
    Main(^{ Require(completed == 1 && failure.code == CydiaAccountErrorAuthentication && !account.signedIn && other.signedIn &&
        deletedTokens == 1, "invalidation crossed source/account scope"); });
    Await(^BOOL { return deletedTokens == 1; }, "invalidated token was not deleted off main queue");
    Main(^{ SeedToken(account, SyntheticToken, @"legacy", service); [service userInfo:account completion:^(NSDictionary *info, NSError *error) { ++completed; }]; });
    auto stale = Take(service, @"/user_info");
    Main(^{ [service signOut:account completion:^(NSError *error) {}]; });
    auto signOut = Take(service, @"/sign_out");
    Main(^{ SeedToken(account, SyntheticSecondToken, @"legacy", service); });
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
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://havoc.app/", @"https://havoc.app/api/sileo/");
    Main(^{
        Require(account.supportsAccountIntegration && !account.signedIn &&
            (account.capabilities & CydiaRepositoryCapabilityLogin) &&
            (account.capabilities & CydiaRepositoryCapabilityEntitlements) &&
            !(account.capabilities & CydiaRepositoryCapabilityDirectPurchase) &&
            !(account.capabilities & CydiaRepositoryCapabilityDownload) && account.compatibilityNotice.length != 0,
            "vendor policy was confused with missing account protocol");
        __block NSUInteger completed = 0;
        [service authorizePackage:@"fixture.package" version:@"1" architecture:@"iphoneos-arm64" account:account
            completion:^(CydiaRepositoryDownloadGrant *grant, NSError *error) {
            Require(grant == nil && error.code == CydiaAccountErrorClientPolicy, "vendor policy allowed paid archive"); ++completed;
        }];
        [service purchasePackage:@"fixture.package" version:@"1" architecture:@"iphoneos-arm64" price:@"$1.99"
            account:account presenter:Presenter() completion:^(CydiaRepositoryPurchaseResult *result) {
            Require(result.state == CydiaRepositoryPurchaseStateRejected && result.error.code == CydiaAccountErrorClientPolicy,
                "known unsupported paid client proceeded to purchase"); ++completed;
        }];
        Require(completed == 2 && browserSessions.count == 0 && service.requests.count == 0 && deviceCalls == 0,
            "unsupported paid integration touched browser/transport/device fields");
    });
}
@interface FixturePurchase : NSObject
@property(nonatomic, strong) CydiaRepositoryPurchaseResult *result;
@property(nonatomic) NSUInteger completions;
@end
@implementation FixturePurchase
@end
static NSDictionary *Offer(BOOL purchased, NSString *price = @"$1.99") {
    return @{@"available": @YES, @"purchased": @(purchased), @"price": price};
}
static FixturePurchase *BeginPurchase(FixtureService *service, CydiaRepositoryAccount *account,
    NSString *price = @"$1.99", BOOL (^selectionIsCurrent)(void) = nil,
    void (^prepareSelection)(void (^)(BOOL)) = nil) {
    FixturePurchase *run = [FixturePurchase new];
    Main(^{ [service purchasePackage:@"fixture.package" version:@"2:1.4-1" architecture:@"iphoneos-arm64e"
        price:price account:account presenter:Presenter() selectionIsCurrent:selectionIsCurrent
        prepareSelection:prepareSelection completion:^(CydiaRepositoryPurchaseResult *result) {
            Require(NSThread.isMainThread, "purchase completion escaped main queue");
            run.result = result; ++run.completions;
        }]; });
    return run;
}
static void AwaitPurchase(FixturePurchase *run) {
    Await(^BOOL { return run.completions != 0; }, "purchase did not settle");
    Main(^{ Require(run.completions == 1 && run.result != nil, "purchase completion was missing or repeated"); });
}
static FixtureRequest *Submit(FixtureService *service, CydiaRepositoryAccount *account) {
    auto info = Take(service, @"/package/fixture.package/info");
    Require([info.body[@"token"] isEqual:SyntheticToken] && info.body[@"payment_secret"] == nil,
        "fresh purchase information leaked secret or used another account");
    Respond(info, Offer(NO));
    if ([[account valueForKey:@"purchaseCredentialMode"] isEqual:@"protected"]) {
        auto afterOwnerAuthentication = Take(service, @"/package/fixture.package/info");
        Require(afterOwnerAuthentication.body[@"payment_secret"] == nil && secretReads != 0,
            "offer recheck after owner authentication disclosed purchase authority");
        Respond(afterOwnerAuthentication, Offer(NO));
    }
    auto sourceEndpoint = Take(service, @"/payment_endpoint");
    Require(sourceEndpoint.body == nil && [sourceEndpoint.URL isEqual:[account.sourceURL URLByAppendingPathComponent:@"payment_endpoint"]],
        "final provider binding recheck disclosed credentials or consulted another source");
    RespondData(sourceEndpoint, [account.providerURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding], 200);
    auto finalOffer = Take(service, @"/package/fixture.package/info");
    Require([finalOffer.body[@"token"] isEqual:SyntheticToken] && finalOffer.body[@"payment_secret"] == nil,
        "final offer recheck lost account binding or disclosed purchase authority");
    Respond(finalOffer, Offer(NO));
    auto charge = Take(service, @"/package/fixture.package/purchase");
    Require([charge.body[@"token"] isEqual:SyntheticToken] && [charge.body[@"udid"] isEqual:SyntheticDevice] &&
        [charge.body[@"device"] isEqual:SyntheticModel], "purchase lost confirmed provider/account device binding");
    Main(^{ Require([service hasUnresolvedPurchase:@"fixture.package" account:account],
        "chargeable request was sent without a durable unresolved marker"); });
    return charge;
}
static void AnonymousGETFallback(void) {
    for (NSInteger unsupported : {404, 405, 501}) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        __block NSUInteger completed = 0;
        Main(^{ [service anonymousPackageInfo:@"fixture.package" account:account completion:^(NSDictionary *info, NSError *error) {
            Require(error == nil && [info[@"available"] isEqual:@YES], "anonymous POST fallback failed"); ++completed;
        }]; });
        auto GET = Take(service, @"/info"); Require(GET.body == nil, "anonymous package info did not begin with GET");
        Respond(GET, nil, unsupported);
        auto POST = Take(service, @"/info");
        Require(POST.body != nil && POST.body.count == 0, "anonymous fallback disclosed device/account data");
        Respond(POST, Offer(NO));
        Main(^{ Require(completed == 1 && service.requests.count == 0 && deviceCalls == 0,
            "anonymous unsupported-method fallback was repeated or obtained device identity"); });
    }
    for (NSInteger denied : {403, 500}) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        __block NSUInteger completed = 0;
        Main(^{ [service anonymousPackageInfo:@"fixture.package" account:account completion:^(NSDictionary *info, NSError *error) {
            Require(info == nil && error != nil, "anonymous server/filter denial was ignored"); ++completed;
        }]; });
        RespondData(Take(service, @"/info"), [@"<html>Request filtered</html>" dataUsingEncoding:NSUTF8StringEncoding], denied);
        Main(^{ Require(completed == 1 && service.requests.count == 0 && deviceCalls == 0,
            "anonymous server/filter failure was retried as credential-bearing POST"); });
    }
}
static void ProtectedSecretAuthentication(void) {
    for (BOOL passcode : {YES, NO}) {
        Reset(); __block FixtureService *service; __block UIViewController *presenter;
        Main(^{ service = [FixtureService new]; presenter = Presenter(); passcodeAvailable = passcode; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        __block NSUInteger completed = 0;
        auto validation = BeginValidation(service, account, presenter, SyntheticToken, ^(NSError *error) {
            Require(error == nil, "protected/hosted account login failed"); ++completed;
        }, SyntheticSecret);
        Require(validation.body[@"payment_secret"] == nil, "authentication validation sent purchase authority");
        Respond(validation, @{@"user": @{}});
        Await(^BOOL { return completed == 1; }, "protected/hosted login did not settle");
        Main(^{
            Require(account.signedIn && storedTokens == 1 && storedSecrets == (passcode ? 1 : 0) && secretReads == 0,
                "login read a purchase secret or stored one without passcode protection");
            Require([[account valueForKey:@"purchaseCredentialMode"] isEqual:passcode ? @"protected" : @"hosted"],
                "login did not record protected or hosted-only purchase authority");
            @synchronized (credentialData) {
                NSString *tokenJSON = [[NSString alloc] initWithData:credentialData[AccountKey(account)] encoding:NSUTF8StringEncoding];
                Require(![tokenJSON containsString:SyntheticSecret], "token credential included purchase secret");
            }
            Require(![[service rememberedAccounts].description containsString:SyntheticToken] &&
                ![[service rememberedAccounts].description containsString:SyntheticSecret], "account metadata leaked credentials");
        });
        __block NSUInteger logout = 0;
        Main(^{ [service signOut:account completion:^(NSError *error) { Require(error == nil, "secret logout failed"); ++logout; }]; });
        auto revocation = Take(service, @"/sign_out");
        Require(revocation.body.count == 1 && [revocation.body[@"token"] isEqual:SyntheticToken],
            "server revocation lost old token or exposed secret/device fields");
        Respond(revocation, @{@"success": @YES});
        Await(^BOOL { return logout == 1; }, "secret logout did not settle");
        Main(^{ Require(!account.signedIn && deletedTokens == 1 && deletedSecrets == (passcode ? 1 : 0),
            "logout left token or protected secret installed"); });
    }
}
static void PurchaseOwnershipAndOffer(void) {
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken, @"protected"); SeedSecret(account); });
    auto run = BeginPurchase(service, account);
    auto charge = Submit(service, account);
    Require([charge.body[@"payment_secret"] isEqual:SyntheticSecret] && secretReads == 1,
        "confirmed purchase did not retrieve its scoped protected secret");
    Respond(charge, @{@"status": @0});
    auto ownership = Take(service, @"/info");
    Require(ownership.body[@"payment_secret"] == nil, "ownership confirmation disclosed purchase secret");
    Main(^{ Require(run.completions == 0, "purchase success response was mistaken for ownership"); });
    Respond(ownership, Offer(YES)); AwaitPurchase(run);
    Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateOwned && run.result.error == nil &&
        ![service hasUnresolvedPurchase:@"fixture.package" account:account], "fresh ownership did not settle confirmed purchase"); });
    auto alreadyOwned = BeginPurchase(service, account);
    Respond(Take(service, @"/info"), Offer(YES)); AwaitPurchase(alreadyOwned);
    Main(^{ Require(alreadyOwned.result.state == CydiaRepositoryPurchaseStateOwned && service.requests.count == 0 && secretReads == 1,
        "already owned package was charged again or prompted for purchase authority"); });
    auto changed = BeginPurchase(service, account);
    Respond(Take(service, @"/info"), Offer(NO, @"$2.99")); AwaitPurchase(changed);
    Main(^{ Require(changed.result.state == CydiaRepositoryPurchaseStateRejected && changed.result.error.code == CydiaAccountErrorOfferChanged &&
        service.requests.count == 0 && secretReads == 1 && ![service hasUnresolvedPurchase:@"fixture.package" account:account],
        "changed fresh price submitted a charge or read purchase authority"); });
}
static void PurchaseCredentialRefusals(void) {
    for (NSString *mode in @[@"legacy", @"missing", @"protected"]) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, mode); });
        auto run = BeginPurchase(service, account);
        Respond(Take(service, @"/info"), Offer(NO)); AwaitPurchase(run);
        Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateRejected && run.result.error.code == CydiaAccountErrorReauthentication &&
            service.requests.count == 0 && ![service hasUnresolvedPurchase:@"fixture.package" account:account],
            "missing/legacy purchase authority was replaced by an unprotected or empty secret"); });
    }
    for (OSStatus cancellation : {errSecUserCanceled, errSecAuthFailed}) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; secretReadStatus = cancellation; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"protected"); SeedSecret(account); });
        auto run = BeginPurchase(service, account);
        Respond(Take(service, @"/info"), Offer(NO)); AwaitPurchase(run);
        Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateCancelled && run.result.error.code == CydiaAccountErrorCancelled &&
            service.requests.count == 0 && ![service hasUnresolvedPurchase:@"fixture.package" account:account],
            "device-owner authentication cancellation submitted or recorded a charge"); });
    }
}
static void PendingAndUnknownNeverRecharge(void) {
    for (BOOL uncertain : {NO, YES}) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
        auto run = BeginPurchase(service, account); auto charge = Submit(service, account);
        Require([charge.body[@"payment_secret"] isEqual:NSNull.null] && secretReads == 0,
            "hosted-only purchase sent unprotected purchase authority");
        auto duplicate = BeginPurchase(service, account); AwaitPurchase(duplicate);
        Main(^{ Require(duplicate.result.state != CydiaRepositoryPurchaseStateOwned && service.requests.count == 0,
            "double Buy submitted another charge or reported ownership"); });
        RespondData(charge, uncertain ? nil : [NSJSONSerialization dataWithJSONObject:@{@"status": @0} options:0 error:nil],
            200, uncertain ? [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil] : nil);
        Respond(Take(service, @"/info"), Offer(NO)); AwaitPurchase(run);
        Main(^{ Require(run.result.state == (uncertain ? CydiaRepositoryPurchaseStateUnknown : CydiaRepositoryPurchaseStatePending) &&
            run.result.error.code == (uncertain ? CydiaAccountErrorPurchaseUnknown : CydiaAccountErrorPurchasePending) &&
            [service hasUnresolvedPurchase:@"fixture.package" account:account], "ambiguous submission was cleared or called owned");
            NSDictionary *attempts = [[[NSUserDefaults alloc] initWithSuiteName:@"com.saurik.Cydia.repository-account-fixtures"]
                dictionaryForKey:@"RepositoryPurchases.v1"];
            Require(![attempts.description containsString:SyntheticToken] && ![attempts.description containsString:SyntheticSecret],
                "durable purchase marker exposed credentials");
        });
        __block FixtureService *relaunched;
        Main(^{ relaunched = [FixtureService new]; });
        auto restored = Discover(relaunched, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        auto retry = BeginPurchase(relaunched, restored);
        Respond(Take(relaunched, @"/info"), Offer(NO)); AwaitPurchase(retry);
        Main(^{ Require(retry.result.state == CydiaRepositoryPurchaseStatePending && relaunched.requests.count == 0 && secretReads == 0,
            "unresolved charge was resubmitted after service relaunch"); });
        auto other = Discover(relaunched, @"https://another-source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ Require(![relaunched hasUnresolvedPurchase:@"fixture.package" account:other],
            "purchase marker crossed source scope for identical package identifier"); });
        __block NSUInteger refreshed = 0;
        Main(^{ [relaunched packageInfo:@"fixture.package" account:restored completion:^(NSDictionary *info, NSError *error) {
            Require(error == nil && [info[@"purchased"] isEqual:@YES], "pending purchase entitlement refresh failed"); ++refreshed;
        }]; });
        Respond(Take(relaunched, @"/info"), Offer(YES));
        Main(^{ Require(refreshed == 1 && ![relaunched hasUnresolvedPurchase:@"fixture.package" account:restored],
            "fresh provider ownership did not resolve durable pending purchase"); });
    }
}
static void HostedCheckoutAndStrictCallbacks(void) {
    NSArray *callbacks = @[@"sileo://payment_completed", @"other://payment_completed", @"sileo://authentication_success?token=fixture",
        @"sileo://payment_completed/path", @"sileo://payment_completed?result=success", @"sileo://payment_completed#fragment"];
    for (NSString *callback in callbacks) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
        auto run = BeginPurchase(service, account); auto charge = Submit(service, account);
        Respond(charge, @{@"status": @1, @"url": @"https://checkout.example.invalid/fixture"});
        auto browser = LastBrowser();
        Main(^{ Require(browser.testStarts == 1 && [browser.testScheme isEqual:@"sileo"] &&
            [browser.testURL.absoluteString isEqual:@"https://checkout.example.invalid/fixture"], "hosted checkout did not use system session");
            [browser testEmitURL:[NSURL URLWithString:callback] error:nil]; });
        auto confirmation = Take(service, @"/info");
        Main(^{ Require(run.completions == 0, "checkout callback was mistaken for receipt");
            [browser testEmitURL:[NSURL URLWithString:@"sileo://payment_completed"] error:nil]; });
        BOOL valid = [callback isEqual:@"sileo://payment_completed"];
        Respond(confirmation, Offer(valid)); AwaitPurchase(run);
        Main(^{ Require(run.result.state == (valid ? CydiaRepositoryPurchaseStateOwned : CydiaRepositoryPurchaseStateUnknown) &&
            (valid || run.result.error.code == CydiaAccountErrorPurchaseUnknown) &&
            service.requests.count == 0, "checkout callback action validation or duplicate guard failed");
            [browser testEmitURL:[NSURL URLWithString:@"sileo://payment_completed"] error:nil]; });
        Main(^{ Require(run.completions == 1 && service.requests.count == 0, "settled checkout callback replay changed payment outcome"); });
    }
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
    auto run = BeginPurchase(service, account); auto charge = Submit(service, account);
    Respond(charge, @{@"status": @1, @"url": @"https://checkout.example.invalid/fixture"});
    Main(^{ [LastBrowser() testEmitURL:nil error:[NSError errorWithDomain:ASWebAuthenticationSessionErrorDomain
        code:ASWebAuthenticationSessionErrorCodeCanceledLogin userInfo:nil]]; });
    Respond(Take(service, @"/info"), Offer(NO)); AwaitPurchase(run);
    Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStatePending &&
        [service hasUnresolvedPurchase:@"fixture.package" account:account] && service.requests.count == 0,
        "checkout cancellation assumed that no server-side charge occurred"); });
}
static void RejectedAndMalformedPurchases(void) {
    for (id status in @[@-1, @YES, @2, @0.5, NSNull.null]) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
        auto run = BeginPurchase(service, account); auto charge = Submit(service, account);
        Respond(charge, @{@"status": status});
        BOOL rejected = [status isEqual:@-1];
        if (!rejected) Respond(Take(service, @"/info"), Offer(NO));
        AwaitPurchase(run);
        Main(^{ Require(run.result.state == (rejected ? CydiaRepositoryPurchaseStateRejected : CydiaRepositoryPurchaseStateUnknown) &&
            [service hasUnresolvedPurchase:@"fixture.package" account:account] != rejected,
            "invalid purchase status was accepted or authoritative rejection remained ambiguous"); });
    }
    for (NSString *URL in @[@"http://checkout.example.invalid/fixture", @"https://user:pass@checkout.example.invalid/fixture",
        @"https://checkout.example.invalid/fixture#fragment",
        [NSString stringWithFormat:@"https://checkout.example.invalid/?token=%@", SyntheticToken],
        [NSString stringWithFormat:@"https://checkout.example.invalid/?secret=%@", SyntheticSecret]]) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"protected"); SeedSecret(account); });
        auto run = BeginPurchase(service, account); auto charge = Submit(service, account);
        Respond(charge, @{@"status": @1, @"url": URL});
        Respond(Take(service, @"/info"), Offer(NO)); AwaitPurchase(run);
        Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateUnknown && browserSessions.count == 0 &&
            [service hasUnresolvedPurchase:@"fixture.package" account:account], "unsafe credential-leaking checkout URL reached browser"); });
    }
}
static void OfferChangedDuringOwnerAuthentication(void) {
    for (NSDictionary *updated in @[Offer(NO, @"$2.99"), Offer(YES), @{@"available": @NO, @"purchased": @NO, @"price": @"$1.99"}]) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"protected"); SeedSecret(account); });
        auto run = BeginPurchase(service, account);
        Respond(Take(service, @"/info"), Offer(NO));
        auto afterOwnerAuthentication = Take(service, @"/info");
        Require(secretReads == 1 && afterOwnerAuthentication.body[@"payment_secret"] == nil,
            "fresh offer was not rechecked after potentially slow owner authentication");
        Respond(afterOwnerAuthentication, updated); AwaitPurchase(run);
        Main(^{
            BOOL alreadyOwned = [updated[@"purchased"] isEqual:@YES];
            Require(run.result.state == (alreadyOwned ? CydiaRepositoryPurchaseStateOwned : CydiaRepositoryPurchaseStateRejected) &&
                (alreadyOwned || run.result.error.code == ([updated[@"available"] isEqual:@YES] ? CydiaAccountErrorOfferChanged : CydiaAccountErrorUnavailable)) &&
                service.requests.count == 0 && ![service hasUnresolvedPurchase:@"fixture.package" account:account],
                "offer changed during authentication still submitted charge");
        });
    }
}
static void PurchaseCancellationBoundaries(void) {
    for (BOOL afterSubmission : {NO, YES}) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        auto other = Discover(service, @"https://another-source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
        auto run = BeginPurchase(service, account);
        FixtureRequest *pending = afterSubmission ? Submit(service, account) : Take(service, @"/info");
        Main(^{ [service cancelPurchaseForAccount:other]; Require(run.completions == 0, "another account canceled active purchase");
            [service cancelPurchaseForAccount:account]; });
        AwaitPurchase(run);
        Main(^{ Require(run.result.state == (afterSubmission ? CydiaRepositoryPurchaseStateUnknown : CydiaRepositoryPurchaseStateCancelled) &&
            run.result.error.code == (afterSubmission ? CydiaAccountErrorPurchaseUnknown : CydiaAccountErrorCancelled) &&
            [service hasUnresolvedPurchase:@"fixture.package" account:account] == afterSubmission,
            "cancellation confused pre-charge cancellation with submitted payment uncertainty"); });
        Respond(pending, afterSubmission ? @{@"status": @0} : Offer(NO));
        Main(^{ Require(run.completions == 1 && service.requests.count == 0, "late canceled purchase reply resumed checkout or charging"); });
    }
}
static void InvalidPackageIdentifiers(void) {
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken, @"protected"); SeedSecret(account); });
    NSArray *invalid = @[@"a", @".", @"..", @".name", @"-name", @"+name", @"UPPER", @"name/slash",
        @"name%2fslash", @"name?query", @"name#fragment", [@"a" stringByPaddingToLength:257 withString:@"a" startingAtIndex:0]];
    for (NSString *identifier in invalid) {
        __block NSUInteger completed = 0;
        Main(^{
            [service anonymousPackageInfo:identifier account:account completion:^(NSDictionary *info, NSError *error) {
                Require(info == nil && error != nil, "invalid anonymous package identifier was accepted"); ++completed;
            }];
            [service packageInfo:identifier account:account completion:^(NSDictionary *info, NSError *error) {
                Require(info == nil && error != nil, "invalid account package identifier was accepted"); ++completed;
            }];
            [service authorizePackage:identifier version:@"1.0" architecture:@"iphoneos-arm64e" account:account
                completion:^(CydiaRepositoryDownloadGrant *grant, NSError *error) {
                Require(grant == nil && error != nil, "invalid grant package identifier was accepted"); ++completed;
            }];
            [service purchasePackage:identifier version:@"1.0" architecture:@"iphoneos-arm64e" price:@"$1.99"
                account:account presenter:Presenter() completion:^(CydiaRepositoryPurchaseResult *result) {
                Require(result.state == CydiaRepositoryPurchaseStateRejected && result.error != nil,
                    "invalid purchase package identifier was accepted"); ++completed;
            }];
            Require(completed == 4 && service.requests.count == 0 && secretReads == 0 && browserSessions.count == 0,
                "path-traversing/non-Debian package identifier reached account transport or purchase authority");
        });
    }
}
static void ProviderChangeBeforeCharge(void) {
    for (BOOL transportFails : {NO, YES}) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"protected"); SeedSecret(account); });
        auto run = BeginPurchase(service, account);
        Respond(Take(service, @"/info"), Offer(NO)); Respond(Take(service, @"/info"), Offer(NO));
        auto endpoint = Take(service, @"/payment_endpoint");
        Require(endpoint.body == nil && secretReads == 1, "provider was not checked after owner authentication without credentials");
        RespondData(endpoint, transportFails ? nil : [@"https://replacement-vendor.example.invalid/" dataUsingEncoding:NSUTF8StringEncoding],
            200, transportFails ? [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil] : nil);
        AwaitPurchase(run);
        Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateRejected && run.result.error != nil &&
            (transportFails || run.result.error.code == CydiaAccountErrorProviderChanged) && service.requests.count == 0 &&
            ![service hasUnresolvedPurchase:@"fixture.package" account:account],
            "changed/unconfirmed provider received charge or old credentials"); });
    }
}
static void ChangedArchiveSelectionRefusesCharge(void) {
    for (NSUInteger changeAt : {0U, 1U, 2U}) {
        Reset(); __block FixtureService *service; __block BOOL current = changeAt != 0;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"protected"); SeedSecret(account); });
        auto run = BeginPurchase(service, account, @"$1.99", ^BOOL { return current; });
        if (changeAt != 0) {
            Respond(Take(service, @"/info"), Offer(NO));
            auto afterOwnerAuthentication = Take(service, @"/info");
            if (changeAt == 1) Main(^{ current = NO; });
            Respond(afterOwnerAuthentication, Offer(NO));
            if (changeAt == 2) {
                auto endpoint = Take(service, @"/payment_endpoint");
                Main(^{ current = NO; });
                RespondData(endpoint, [account.providerURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding], 200);
            }
        }
        AwaitPurchase(run);
        Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateRejected && run.result.error.code == CydiaAccountErrorUnavailable &&
            service.requests.count == 0 && ![service hasUnresolvedPurchase:@"fixture.package" account:account],
            "removed/changed archive selection charged after confirmation or owner authentication"); });
    }
}
static void AnotherAccountCannotResolveUncertainCharge(void) {
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
    auto first = BeginPurchase(service, account); auto charge = Submit(service, account);
    Respond(charge, @{@"status": @0}); Respond(Take(service, @"/info"), Offer(NO)); AwaitPurchase(first);
    __block NSUInteger logout = 0;
    Main(^{ [service signOut:account completion:^(NSError *error) { Require(error == nil, "first account logout failed"); ++logout; }]; });
    Respond(Take(service, @"/sign_out"), @{@"success": @YES});
    Await(^BOOL { return logout == 1; }, "first account logout did not settle");
    Main(^{ SeedToken(account, SyntheticSecondToken, @"hosted", service); });
    __block NSUInteger refreshed = 0;
    Main(^{ [service packageInfo:@"fixture.package" account:account completion:^(NSDictionary *info, NSError *error) {
        Require(error == nil && [info[@"purchased"] isEqual:@YES], "second account ownership lookup failed"); ++refreshed;
    }]; });
    auto secondAccount = Take(service, @"/info");
    Require([secondAccount.body[@"token"] isEqual:SyntheticSecondToken], "second account lookup used original purchaser token");
    Respond(secondAccount, Offer(YES));
    Main(^{ Require(refreshed == 1 && [service hasUnresolvedPurchase:@"fixture.package" account:account],
        "different account ownership erased original purchaser uncertain charge");
        [service generationForAccount:account advance:YES]; SeedToken(account, SyntheticToken, @"hosted", service);
    });
    auto originalRetry = BeginPurchase(service, account);
    Respond(Take(service, @"/info"), Offer(NO)); AwaitPurchase(originalRetry);
    Main(^{ Require(originalRetry.result.state == CydiaRepositoryPurchaseStatePending && service.requests.count == 0,
        "cross-account entitlement check enabled another charge for original uncertain purchaser"); });
    Main(^{ [service packageInfo:@"fixture.package" account:account completion:^(NSDictionary *info, NSError *error) {
        Require(error == nil && [info[@"purchased"] isEqual:@YES], "original account ownership lookup failed"); ++refreshed;
    }]; });
    Respond(Take(service, @"/info"), Offer(YES));
    Main(^{ Require(refreshed == 2 && ![service hasUnresolvedPurchase:@"fixture.package" account:account],
        "matching original account fresh ownership failed to resolve uncertain charge"); });
}
static void MalformedProviderFlagsDoNotAuthorize(void) {
    NSArray *malformed = @[@{@"success": @"false"}, @{@"success": @1}, @{@"error": @YES},
        @{@"error": @{}}, @{@"error": @""}];
    for (NSDictionary *flags in malformed) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
        auto run = BeginPurchase(service, account);
        NSMutableDictionary *offer = [Offer(NO) mutableCopy]; [offer addEntriesFromDictionary:flags];
        Respond(Take(service, @"/info"), offer); AwaitPurchase(run);
        Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateRejected &&
            run.result.error.code == CydiaAccountErrorInvalidResponse && service.requests.count == 0 &&
            ![service hasUnresolvedPurchase:@"fixture.package" account:account],
            "malformed success/error metadata authorized a charge"); });
        __block NSUInteger grants = 0;
        Main(^{ [service authorizePackage:@"fixture.package" version:@"1.0" architecture:@"iphoneos-arm64e" account:account
            completion:^(CydiaRepositoryDownloadGrant *grant, NSError *error) {
                Require(grant == nil && error.code == CydiaAccountErrorInvalidResponse,
                    "malformed success/error metadata authorized archive"); ++grants;
            }]; });
        NSMutableDictionary *grant = [@{@"url": @"https://cdn.example.invalid/archive?grant=fixture"} mutableCopy];
        [grant addEntriesFromDictionary:flags]; Respond(Take(service, @"/authorize_download"), grant);
        Main(^{ Require(grants == 1, "malformed archive response did not settle"); });
        auto submitted = BeginPurchase(service, account); auto charge = Submit(service, account);
        Respond(charge, @{@"status": @0});
        NSMutableDictionary *ownership = [Offer(YES) mutableCopy]; [ownership addEntriesFromDictionary:flags];
        Respond(Take(service, @"/info"), ownership); AwaitPurchase(submitted);
        Main(^{ Require(submitted.result.state == CydiaRepositoryPurchaseStateUnknown &&
            [service hasUnresolvedPurchase:@"fixture.package" account:account],
            "malformed ownership metadata erased uncertain charge or reported receipt"); });
    }
}
@interface FixtureAccess : NSObject
@property(nonatomic, strong) CydiaRepositoryAccessResult *result;
@property(nonatomic) NSUInteger completions;
@end
@implementation FixtureAccess
@end
static FixtureAccess *BeginAccess(FixtureService *service, NSURL *source,
    NSString *package = @"fixture.package", NSString *version = @"2:1.4-1", NSString *architecture = @"iphoneos-arm64e") {
    FixtureAccess *run = [FixtureAccess new];
    Main(^{ [service preflightPackage:package version:version architecture:architecture source:source name:@"Fixture source"
        completion:^(CydiaRepositoryAccessResult *result) {
            Require(NSThread.isMainThread, "access preparation completion escaped main queue");
            run.result = result; ++run.completions;
        }]; });
    return run;
}
static FixtureRequest *AccessDiscovery(FixtureService *service, NSString *provider) {
    auto endpoint = Take(service, @"/payment_endpoint");
    Require(endpoint.body == nil, "access preparation discovery sent device/account data");
    RespondData(endpoint, [provider dataUsingEncoding:NSUTF8StringEncoding], 200);
    auto info = Take(service, @"/info"); Require(info.body == nil, "access provider metadata contained credentials");
    Respond(info, @{@"name": @"Fixture vendor"});
    auto anonymous = Take(service, @"/package/fixture.package/info");
    Require(anonymous.body == nil, "access preparation did not inspect public offer without credentials");
    return anonymous;
}
static void AwaitAccess(FixtureAccess *run) {
    Await(^BOOL { return run.completions != 0; }, "access preparation did not settle");
    Main(^{ Require(run.completions == 1 && run.result != nil &&
        [run.result.package isEqual:@"fixture.package"] && [run.result.version isEqual:@"2:1.4-1"] &&
        [run.result.architecture isEqual:@"iphoneos-arm64e"] && ![run.result respondsToSelector:@selector(transportURL)],
        "license preparation lost selected identity or returned an archive capability"); });
}
static void ReadOnlyAccessPreparation(void) {
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    NSURL *source = [NSURL URLWithString:@"https://source.example.invalid/"];
    auto legacy = BeginAccess(service, source);
    Respond(Take(service, @"/payment_endpoint"), nil, 404); AwaitAccess(legacy);
    Main(^{ Require(legacy.result.state == CydiaRepositoryAccessStateNotRequired && legacy.result.error == nil &&
        service.requests.count == 0 && deviceCalls == 0, "legacy repository was forced into account/download authorization"); });
    for (NSInteger status : {404, 410, 501}) {
        Reset(); Main(^{ service = [FixtureService new]; });
        auto restricted = BeginAccess(service, [NSURL URLWithString:@"https://havoc.app/"]);
        Respond(Take(service, @"/payment_endpoint"), nil, status); AwaitAccess(restricted);
        Main(^{ Require(restricted.result.state == CydiaRepositoryAccessStateUnsupported &&
            restricted.result.error.code == CydiaAccountErrorClientPolicy && service.requests.count == 0 &&
            deviceCalls == 0 && secretReads == 0,
            "missing payment discovery downgraded a known restricted vendor to anonymous acquisition"); });
    }
    for (NSDictionary *offer in @[@{@"available": @YES, @"free": @YES}, @{@"available": @YES, @"price": @0}]) {
        Reset(); Main(^{ service = [FixtureService new]; });
        auto free = BeginAccess(service, source);
        Respond(AccessDiscovery(service, @"https://vendor.example.invalid/"), offer); AwaitAccess(free);
        Main(^{ Require(free.result.state == CydiaRepositoryAccessStateNotRequired && free.result.error == nil &&
            [free.result.sourceURL isEqual:source] && service.requests.count == 0 && deviceCalls == 0 && secretReads == 0,
            "free package preparation fetched a grant, account identity, or purchase secret"); });
    }
    for (BOOL purchased : {NO, YES}) {
        Reset(); Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, source.absoluteString, @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken); });
        auto run = BeginAccess(service, source);
        Respond(AccessDiscovery(service, @"https://vendor.example.invalid/"), Offer(NO));
        auto entitlement = Take(service, @"/package/fixture.package/info");
        Require([entitlement.body[@"token"] isEqual:SyntheticToken] && entitlement.body[@"payment_secret"] == nil,
            "access preparation queried ownership with purchase authority or another token");
        Respond(entitlement, Offer(purchased)); AwaitAccess(run);
        Main(^{ Require(run.result.state == (purchased ? CydiaRepositoryAccessStateReady : CydiaRepositoryAccessStatePurchaseRequired) &&
            run.result.error == nil && [run.result.sourceURL isEqual:source] && service.requests.count == 0 &&
            secretReads == 0 && browserSessions.count == 0 && ![service hasUnresolvedPurchase:@"fixture.package" account:run.result.account],
            "license preparation charged, authenticated, acquired an archive, or confused ownership"); });
    }
    Reset(); Main(^{ service = [FixtureService new]; });
    auto signIn = BeginAccess(service, source);
    Respond(AccessDiscovery(service, @"https://vendor.example.invalid/"), Offer(NO)); AwaitAccess(signIn);
    Main(^{ Require(signIn.result.state == CydiaRepositoryAccessStateSignIn && deviceCalls == 0 &&
        browserSessions.count == 0 && service.requests.count == 0, "read-only license preparation initiated login automatically"); });
    Reset(); Main(^{ service = [FixtureService new]; });
    auto unsupported = BeginAccess(service, [NSURL URLWithString:@"https://havoc.app/"]);
    Respond(AccessDiscovery(service, @"https://havoc.app/api/sileo/"), Offer(NO)); AwaitAccess(unsupported);
    Main(^{ Require(unsupported.result.state == CydiaRepositoryAccessStateUnsupported &&
        unsupported.result.error.code == CydiaAccountErrorClientPolicy && deviceCalls == 0 && service.requests.count == 0,
        "known unsupported vendor preparation advertised paid delivery or prompted for login"); });
    for (NSDictionary *offer in @[@{@"available": @NO}, @{@"available": @1}, @{@"available": @YES, @"error": @YES}]) {
        Reset(); Main(^{ service = [FixtureService new]; });
        auto run = BeginAccess(service, source);
        Respond(AccessDiscovery(service, @"https://vendor.example.invalid/"), offer); AwaitAccess(run);
        BOOL unavailable = [offer[@"available"] isEqual:@NO];
        Main(^{ Require(run.result.state == (unavailable ? CydiaRepositoryAccessStateUnavailable : CydiaRepositoryAccessStateFailed) &&
            run.result.error != nil && service.requests.count == 0 && deviceCalls == 0,
            "malformed/unavailable license preparation implied a download grant or silently bypassed account policy"); });
    }
}
static void AccessPreparationRetainsMutableIdentity(void) {
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    NSMutableString *package = [@"fixture.package" mutableCopy], *version = [@"2:1.4-1" mutableCopy];
    NSMutableString *architecture = [@"iphoneos-arm64e" mutableCopy];
    auto run = BeginAccess(service, [NSURL URLWithString:@"https://source.example.invalid/"], package, version, architecture);
    Main(^{ [package setString:@"different.package"]; [version setString:@"9:9.9"]; [architecture setString:@"iphoneos-arm"]; });
    Respond(AccessDiscovery(service, @"https://vendor.example.invalid/"), @{@"available": @YES, @"free": @YES});
    AwaitAccess(run);
    Main(^{ Require(run.result.state == CydiaRepositoryAccessStateNotRequired && service.requests.count == 0,
        "mutable caller selection altered in-flight read-only preparation identity"); });
}
static void RecoveryURLsStayPublicAndScoped(void) {
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken); });
    NSArray *valid = @[@"https://vendor.example.invalid/help", @"https://source.example.invalid/help"];
    NSArray *invalid = @[@"http://vendor.example.invalid/help", @"https://other.example.invalid/help",
        @"https://user:pass@vendor.example.invalid/help", @"https://vendor.example.invalid/help?public=1",
        @"https://vendor.example.invalid/help#fragment", @"https://vendor.example.invalid/help%0aextra",
        @"https://vendor.example.invalid/help%5cextra", @"cydia://package/fixture.package",
        [NSString stringWithFormat:@"https://vendor.example.invalid/help/%@", SyntheticToken],
        @"https://vendor.example.invalid/help/fixture%2Daccount%2Dtoken%2Daaaaaaaa",
        @"https://docs.chariz.com/help/faq", @"https://docs.havoc.app/docs/help/contact_us/"];
    for (NSString *URL in [valid arrayByAddingObjectsFromArray:invalid]) {
        __block NSError *failure; __block NSUInteger completed = 0;
        Main(^{ [service packageInfo:@"fixture.package" account:account completion:^(NSDictionary *info, NSError *error) {
            Require(info == nil && error != nil, "provider failure was mistaken for ownership"); failure = error; ++completed;
        }]; });
        Respond(Take(service, @"/info"), @{@"error": @"Fixture account recovery", @"recovery_url": URL});
        Main(^{
            NSURL *recovery = failure.userInfo[CydiaAccountRecoveryURLKey];
            BOOL allowed = [valid containsObject:URL];
            Require(completed == 1 && (recovery != nil) == allowed && (!allowed || [recovery.absoluteString isEqual:URL]) &&
                service.requests.count == 0 && browserSessions.count == 0,
                "unsafe/cross-provider recovery link was accepted or opened without user action");
        });
    }
    for (NSString *vendor in @[@"chariz", @"havoc"]) {
        NSString *source = [vendor isEqual:@"chariz"] ? @"https://repo.chariz.com/" : @"https://havoc.app/";
        NSString *provider = [vendor isEqual:@"chariz"] ? @"https://chariz.com/api/sileo/" : @"https://havoc.app/api/sileo/";
        NSString *help = [vendor isEqual:@"chariz"] ? @"https://docs.chariz.com/help/faq" : @"https://docs.havoc.app/docs/help/contact_us/";
        auto known = Discover(service, source, provider);
        Main(^{ SeedToken(known, SyntheticToken); });
        __block NSError *failure;
        Main(^{ [service userInfo:known completion:^(NSDictionary *info, NSError *error) { failure = error; }]; });
        Respond(Take(service, @"/user_info"), @{@"error": @"Fixture provider support", @"recovery_url": help});
        Main(^{ Require([failure.userInfo[CydiaAccountRecoveryURLKey] isKindOfClass:NSURL.class] &&
            [((NSURL *)failure.userInfo[CydiaAccountRecoveryURLKey]).absoluteString isEqual:help],
            "documented provider help origin was rejected"); });
    }
    auto changed = Discover(service, @"https://source.example.invalid/", @"https://replacement-vendor.example.invalid/");
    Main(^{ SeedToken(changed, SyntheticSecondToken); });
    __block NSError *oldFailure;
    Main(^{ [service packageInfo:@"fixture.package" account:account completion:^(NSDictionary *info, NSError *error) { oldFailure = error; }]; });
    Respond(Take(service, @"/info"), @{@"error": @"Fixture old provider", @"recovery_url": @"https://replacement-vendor.example.invalid/help"});
    Main(^{ Require(oldFailure != nil && oldFailure.userInfo[CydiaAccountRecoveryURLKey] == nil && service.requests.count == 0,
        "old provider error inherited newly discovered provider recovery authority"); });
}
static void PurchaseRecoveryPreservesUncertainty(void) {
    for (BOOL leaksSecret : {NO, YES}) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"protected"); SeedSecret(account); });
        auto run = BeginPurchase(service, account); auto charge = Submit(service, account);
        NSString *URL = leaksSecret ? [NSString stringWithFormat:@"https://vendor.example.invalid/help/%@", SyntheticSecret] :
            @"https://vendor.example.invalid/help";
        Respond(charge, @{@"status": @0, @"error": @"Fixture payment uncertainty", @"recovery_url": URL});
        Respond(Take(service, @"/info"), Offer(NO)); AwaitPurchase(run);
        Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateUnknown &&
            (run.result.error.userInfo[CydiaAccountRecoveryURLKey] != nil) != leaksSecret &&
            [service hasUnresolvedPurchase:@"fixture.package" account:account] && service.requests.count == 0 && browserSessions.count == 0,
            "purchase recovery leaked secret, erased uncertainty, opened browser, or repeated charge"); });
    }
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://repo.chariz.com/", @"https://chariz.com/api/sileo/");
    Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
    auto run = BeginPurchase(service, account); auto charge = Submit(service, account);
    Respond(charge, @{@"status": @0}); Respond(Take(service, @"/info"), Offer(NO)); AwaitPurchase(run);
    Main(^{ NSURL *help = run.result.error.userInfo[CydiaAccountRecoveryURLKey];
        Require(run.result.state == CydiaRepositoryPurchaseStatePending &&
            [help.absoluteString isEqual:@"https://docs.chariz.com/help/payment-pending"] &&
            [service hasUnresolvedPurchase:@"fixture.package" account:account] && service.requests.count == 0,
            "pending purchase lacked safe documented support or was resubmitted"); });
}
static void AsynchronousFinalSelectionCannotReplayCharge(void) {
    for (NSUInteger outcome : {0U, 1U, 2U}) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
        __block void (^prepared)(BOOL) = nil;
        auto run = BeginPurchase(service, account, @"$1.99", ^BOOL { return YES; }, ^(void (^completion)(BOOL)) {
            Require(NSThread.isMainThread, "final selection preparation escaped UI queue"); prepared = [completion copy];
        });
        Respond(Take(service, @"/info"), Offer(NO));
        RespondData(Take(service, @"/payment_endpoint"), [account.providerURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding], 200);
        Await(^BOOL { return prepared != nil; }, "asynchronous final preparation was not requested");
        Main(^{ Require(run.completions == 0 && service.requests.count == 0 &&
            ![service hasUnresolvedPurchase:@"fixture.package" account:account],
            "charge submitted or recorded while final selection verification was outstanding"); });
        if (outcome == 2) {
            Main(^{ [service cancelPurchaseForAccount:account]; }); AwaitPurchase(run);
            Main(^{ prepared(YES); });
        } else Main(^{ prepared(outcome == 1); prepared(YES); prepared(NO); });
        if (outcome == 1) {
            Respond(Take(service, @"/info"), Offer(NO));
            auto charge = Take(service, @"/purchase");
            Main(^{ Require(service.requests.count == 0 && [service hasUnresolvedPurchase:@"fixture.package" account:account],
                "replayed final selection callback submitted a duplicate charge"); prepared(YES); });
            Respond(charge, @{@"status": @0}); Respond(Take(service, @"/info"), Offer(YES)); AwaitPurchase(run);
            Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateOwned, "approved final selection did not complete one verified purchase"); });
        } else {
            AwaitPurchase(run);
            Main(^{ Require(run.result.state == (outcome == 2 ? CydiaRepositoryPurchaseStateCancelled : CydiaRepositoryPurchaseStateRejected) &&
                service.requests.count == 0 && ![service hasUnresolvedPurchase:@"fixture.package" account:account],
                "failed/canceled final selection was charged by a late or repeated callback"); });
        }
        Main(^{ prepared(YES); });
        Main(^{ Require(run.completions == 1 && service.requests.count == 0,
            "settled final selection replay resumed financial operation"); });
    }
}
static void FinalFreshOfferAfterAsynchronousPreparation(void) {
    for (NSDictionary *updated in @[Offer(NO, @"$2.99"), Offer(YES), @{@"available": @NO, @"purchased": @NO, @"price": @"$1.99"}]) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
        __block void (^prepared)(BOOL) = nil;
        auto run = BeginPurchase(service, account, @"$1.99", ^BOOL { return YES; }, ^(void (^completion)(BOOL)) {
            prepared = [completion copy];
        });
        Respond(Take(service, @"/info"), Offer(NO));
        RespondData(Take(service, @"/payment_endpoint"), [account.providerURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding], 200);
        Await(^BOOL { return prepared != nil; }, "final preparation did not expose asynchronous completion");
        Main(^{ prepared(YES); });
        auto finalOffer = Take(service, @"/info");
        Require([finalOffer.body[@"token"] isEqual:SyntheticToken] && finalOffer.body[@"payment_secret"] == nil,
            "price/ownership was not rechecked after asynchronous selection preparation");
        Respond(finalOffer, updated); AwaitPurchase(run);
        Main(^{ BOOL owned = [updated[@"purchased"] isEqual:@YES];
            Require(run.result.state == (owned ? CydiaRepositoryPurchaseStateOwned : CydiaRepositoryPurchaseStateRejected) &&
                (owned || run.result.error.code == ([updated[@"available"] isEqual:@YES] ? CydiaAccountErrorOfferChanged : CydiaAccountErrorUnavailable)) &&
                service.requests.count == 0 && ![service hasUnresolvedPurchase:@"fixture.package" account:account],
                "stale offer was charged after asynchronous final preparation"); });
    }
    Reset(); __block FixtureService *service;
    Main(^{ service = [FixtureService new]; });
    auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
    Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
    __block void (^prepared)(BOOL) = nil;
    auto run = BeginPurchase(service, account, @"$1.99", ^BOOL { return YES; }, ^(void (^completion)(BOOL)) { prepared = [completion copy]; });
    Respond(Take(service, @"/info"), Offer(NO));
    RespondData(Take(service, @"/payment_endpoint"), [account.providerURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding], 200);
    Await(^BOOL { return prepared != nil; }, "cancel case final preparation did not complete");
    Main(^{ prepared(YES); });
    auto finalOffer = Take(service, @"/info");
    Main(^{ [service cancelPurchaseForAccount:account]; }); AwaitPurchase(run);
    Respond(finalOffer, Offer(NO));
    Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateCancelled && run.completions == 1 &&
        service.requests.count == 0 && ![service hasUnresolvedPurchase:@"fixture.package" account:account],
        "late final offer reply resumed canceled purchase"); });
}
static void MalformedOwnershipNeverCharges(void) {
    NSArray *offers = @[@{@"available": @YES, @"price": @"$1.99"},
        @{@"available": @YES, @"purchased": @"false", @"price": @"$1.99"},
        @{@"available": @YES, @"purchased": @0, @"price": @"$1.99"},
        @{@"available": @YES, @"purchased": NSNull.null, @"price": @"$1.99"}];
    for (NSUInteger boundary : {0U, 1U, 2U}) {
        for (NSDictionary *malformed in offers) {
            Reset(); __block FixtureService *service;
            Main(^{ service = [FixtureService new]; });
            auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
            Main(^{ SeedToken(account, SyntheticToken, boundary == 1 ? @"protected" : @"hosted");
                if (boundary == 1) SeedSecret(account); });
            auto run = BeginPurchase(service, account);
            auto info = Take(service, @"/info");
            if (boundary != 0) {
                Respond(info, Offer(NO));
                if (boundary == 2) RespondData(Take(service, @"/payment_endpoint"),
                    [account.providerURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding], 200);
                info = Take(service, @"/info");
            }
            Respond(info, malformed); AwaitPurchase(run);
            Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateRejected &&
                run.result.error.code == CydiaAccountErrorInvalidResponse && service.requests.count == 0 &&
                ![service hasUnresolvedPurchase:@"fixture.package" account:account],
                "missing/non-boolean ownership authorized charge at financial preflight boundary"); });
        }
    }
}
static void FreeConversionNeverChargesOrResolvesPayment(void) {
    NSArray *freeOffers = @[@{@"available": @YES, @"purchased": @NO, @"free": @YES, @"price": @"$1.99"},
        @{@"available": @YES, @"purchased": @NO, @"price": @0}];
    for (NSUInteger boundary : {0U, 1U, 2U}) {
        for (NSDictionary *freeOffer in freeOffers) {
            Reset(); __block FixtureService *service;
            Main(^{ service = [FixtureService new]; });
            auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
            Main(^{ SeedToken(account, SyntheticToken, boundary == 1 ? @"protected" : @"hosted");
                if (boundary == 1) SeedSecret(account); });
            auto run = BeginPurchase(service, account); auto info = Take(service, @"/info");
            if (boundary != 0) {
                Respond(info, Offer(NO));
                if (boundary == 2) RespondData(Take(service, @"/payment_endpoint"),
                    [account.providerURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding], 200);
                info = Take(service, @"/info");
            }
            Respond(info, freeOffer); AwaitPurchase(run);
            Main(^{ Require(run.result.state == CydiaRepositoryPurchaseStateRejected &&
                run.result.error.code == CydiaAccountErrorOfferChanged && service.requests.count == 0 &&
                ![service hasUnresolvedPurchase:@"fixture.package" account:account],
                "newly free package still submitted a purchase at financial preflight boundary"); });
        }
    }
    for (BOOL unknown : {NO, YES}) {
        Reset(); __block FixtureService *service;
        Main(^{ service = [FixtureService new]; });
        auto account = Discover(service, @"https://source.example.invalid/", @"https://vendor.example.invalid/");
        Main(^{ SeedToken(account, SyntheticToken, @"hosted"); });
        auto run = BeginPurchase(service, account); auto charge = Submit(service, account);
        Respond(charge, @{@"status": unknown ? @2 : @0});
        NSDictionary *nowFree = @{@"available": @YES, @"purchased": @YES, @"free": @YES, @"price": @0};
        Respond(Take(service, @"/info"), nowFree); AwaitPurchase(run);
        Main(^{ Require(run.result.state == (unknown ? CydiaRepositoryPurchaseStateUnknown : CydiaRepositoryPurchaseStatePending) &&
            [service hasUnresolvedPurchase:@"fixture.package" account:account] && service.requests.count == 0,
            "free availability was mistaken for proof that an earlier charge settled"); });
        __block NSUInteger refreshed = 0;
        Main(^{ [service packageInfo:@"fixture.package" account:account completion:^(NSDictionary *info, NSError *error) {
            Require(error == nil && [info[@"free"] isEqual:@YES], "newly free package status lookup failed"); ++refreshed;
        }]; });
        Respond(Take(service, @"/info"), nowFree);
        Main(^{ Require(refreshed == 1 && [service hasUnresolvedPurchase:@"fixture.package" account:account],
            "ordinary free-package refresh erased unresolved paid purchase marker"); });
    }
}
static void Run(void) {
    DiscoveryAndEndpointScope(); ValidAuthenticationAndReplay(); InvalidAuthenticationCallbacks();
    BrowserFailureAndCancellation(); LogoutAndNewLoginRaces(); LogoutBeforeBrowserCallback();
    StoreAndServerValidationFailures(); SuccessfulHTTPInvalidationRefusesNewCredentials();
    InvalidationScope(); ExactGrantAndFailures(); MutableGrantSelectionSnapshot(); RedirectAndResponseBounds();
    UnsupportedIntegrationAndInvalidDiscovery(); AnonymousGETFallback(); ProtectedSecretAuthentication();
    PurchaseOwnershipAndOffer(); PurchaseCredentialRefusals(); PendingAndUnknownNeverRecharge();
    HostedCheckoutAndStrictCallbacks(); RejectedAndMalformedPurchases();
    OfferChangedDuringOwnerAuthentication(); PurchaseCancellationBoundaries();
    InvalidPackageIdentifiers(); ProviderChangeBeforeCharge(); ChangedArchiveSelectionRefusesCharge();
    AnotherAccountCannotResolveUncertainCharge(); MalformedProviderFlagsDoNotAuthorize();
    ReadOnlyAccessPreparation(); AccessPreparationRetainsMutableIdentity(); RecoveryURLsStayPublicAndScoped();
    PurchaseRecoveryPreservesUncertainty();
    AsynchronousFinalSelectionCannotReplayCharge();
    FinalFreshOfferAfterAsynchronousPreparation();
    MalformedOwnershipNeverCharges(); FreeConversionNeverChargesOrResolvesPayment();
    Reset();
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
