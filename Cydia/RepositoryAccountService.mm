/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RepositoryAccountService.h"
#import "Cydia/AppState.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <Security/Security.h>
#include <sys/utsname.h>

NSString *CydiaAccountLocalize(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Accounts"];
}
static NSError *AccountError(CydiaAccountError code) {
    NSString *key = code == CydiaAccountErrorUnsupported ? @"ACCOUNT_UNSUPPORTED" :
        code == CydiaAccountErrorAuthentication ? @"ACCOUNT_SIGN_IN_REQUIRED" : @"ACCOUNT_REQUEST_FAILED";
    return [NSError errorWithDomain:@"CydiaRepositoryAccount" code:code
        userInfo:@{NSLocalizedDescriptionKey: CydiaAccountLocalize(key)}];
}
static BOOL SecureURL(NSURL *URL) {
    return [URL.scheme.lowercaseString isEqual:@"https"] && URL.host.length != 0 &&
        URL.user == nil && URL.password == nil && URL.fragment == nil;
}
NSString *CydiaAccountOrigin(NSURL *URL) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    parts.path = @""; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil;
    if (parts.port.integerValue == 443) parts.port = nil;
    parts.host = parts.host.lowercaseString;
    return parts.string;
}
static NSString *String(id value) {
    return [value isKindOfClass:NSString.class] && [value length] != 0 ? value : nil;
}
static NSURL *URLValue(id value) {
    NSString *text = String(value); return text ? [NSURL URLWithString:text] : nil;
}
static NSDictionary *DeviceFields(void) {
    NSString *identifier = UniqueIdentifier();
    struct utsname info;
    if (identifier.length == 0 || uname(&info) != 0) return nil;
    return @{@"udid": identifier, @"device": [NSString stringWithUTF8String:info.machine]};
}
static NSDictionary *KeyQuery(CydiaRepositoryAccount *account) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.saurik.Cydia.repository-account.v1",
        (__bridge id)kSecAttrAccount: [NSString stringWithFormat:@"%@\n%@",
            account.sourceURL.absoluteString, account.providerURL.absoluteString]};
}
static NSDictionary *Credentials(CydiaRepositoryAccount *account) {
    NSMutableDictionary *query = [KeyQuery(account) mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) return nil;
    NSData *data = CFBridgingRelease(result);
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}
static BOOL StoreToken(CydiaRepositoryAccount *account, NSString *token) {
    NSDictionary *query = KeyQuery(account);
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"token": token} options:0 error:nil];
    NSDictionary *values = @{(__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)values);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [query mutableCopy]; [item addEntriesFromDictionary:values];
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return status == errSecSuccess;
}
static BOOL ForgetToken(CydiaRepositoryAccount *account) {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)KeyQuery(account));
    return status == errSecSuccess || status == errSecItemNotFound;
}
static NSString *AccountKey(CydiaRepositoryAccount *account) {
    return KeyQuery(account)[(__bridge id)kSecAttrAccount];
}

@interface CydiaRepositoryAccount ()
@property(nonatomic, copy, readwrite) NSURL *sourceURL, *providerURL;
@property(nonatomic, copy, readwrite) NSString *name;
@end
@implementation CydiaRepositoryAccount
- (BOOL)supportsAccountIntegration {
    for (NSURL *URL in @[self.sourceURL, self.providerURL]) {
        NSString *host = URL.host.lowercaseString;
        if ([host isEqual:@"havoc.app"] || [host hasSuffix:@".havoc.app"]) return NO;
    }
    return YES;
}
- (BOOL)signedIn { return self.supportsAccountIntegration && String(Credentials(self)[@"token"]) != nil; }
- (NSString *)description { return [NSString stringWithFormat:@"<RepositoryAccount %@>", CydiaAccountOrigin(self.sourceURL)]; }
@end
@interface CydiaRepositoryDownloadGrant ()
@property(nonatomic, copy, readwrite) NSURL *transportURL, *sourceURL;
@property(nonatomic, copy, readwrite) NSString *package, *version, *architecture;
@property(nonatomic, copy, readwrite) NSDate *obtainedAt;
@end
@implementation CydiaRepositoryDownloadGrant
- (instancetype)initPrivate { return [super init]; }
- (NSString *)description { return @"<RepositoryDownloadGrant>"; }
- (NSString *)debugDescription { return self.description; }
@end

/* Redirects are bounded to the exact HTTPS origin. JSON credentials must never
 * follow a vendor response onto a CDN or a second payment provider. */
@interface CydiaAccountRequest : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSHTTPURLResponse *response;
@property(nonatomic, copy) void (^completion)(NSData *, NSHTTPURLResponse *, NSError *);
@property(nonatomic) NSUInteger redirects;
- (void)start:(NSURLRequest *)request;
@end
@implementation CydiaAccountRequest
- (void)start:(NSURLRequest *)request {
    _URL = request.URL; _data = [NSMutableData data];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPShouldSetCookies = NO; config.HTTPCookieStorage = nil; config.URLCredentialStorage = nil;
    config.URLCache = nil; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45;
    _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    [[_session dataTaskWithRequest:request] resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion {
    BOOL allowed = ++_redirects <= 3 && SecureURL(request.URL) &&
        [CydiaAccountOrigin(request.URL) isEqual:CydiaAccountOrigin(_URL)] &&
        [task.originalRequest.HTTPMethod isEqual:@"GET"];
    completion(allowed ? request : nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    _response = (NSHTTPURLResponse *)response;
    completion(response.expectedContentLength > 1024 * 1024 ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (_data.length + data.length > 1024 * 1024) { [task cancel]; return; }
    [_data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    void (^completion)(NSData *, NSHTTPURLResponse *, NSError *) = _completion; _completion = nil;
    [session finishTasksAndInvalidate]; _session = nil;
    if (completion) completion(_data, _response, error ? AccountError(CydiaAccountErrorTransport) : nil);
}
@end

@interface CydiaRepositoryAccountService () <ASWebAuthenticationPresentationContextProviding>
@property(nonatomic, strong) ASWebAuthenticationSession *authenticationSession;
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, strong) NSUUID *sessionIdentity;
@property(nonatomic, copy) NSString *authenticationAccountKey;
@property(nonatomic, copy) void (^authenticationCompletion)(NSError *);
@property(nonatomic) BOOL receivedAuthenticationCallback;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSUUID *> *accountGenerations;
@end
@implementation CydiaRepositoryAccountService
+ (instancetype)sharedService {
    static CydiaRepositoryAccountService *service; static dispatch_once_t once;
    dispatch_once(&once, ^{ service = [[self alloc] init]; }); return service;
}
- (NSUUID *)generationForAccount:(CydiaRepositoryAccount *)account advance:(BOOL)advance {
    @synchronized (self) {
        if (!_accountGenerations) _accountGenerations = [NSMutableDictionary dictionary];
        NSString *key = AccountKey(account);
        if (advance || !_accountGenerations[key]) _accountGenerations[key] = [NSUUID UUID];
        return _accountGenerations[key];
    }
}
- (void)finishAuthentication:(NSUUID *)identity error:(NSError *)error {
    if (![_sessionIdentity isEqual:identity]) return;
    void (^completion)(NSError *) = _authenticationCompletion;
    _sessionIdentity = nil; _authenticationSession = nil; _presenter = nil;
    _authenticationAccountKey = nil; _authenticationCompletion = nil;
    _receivedAuthenticationCallback = NO;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
}
- (void)request:(NSURL *)URL body:(NSDictionary *)body completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    if (!SecureURL(URL)) { completion(nil, nil, AccountError(CydiaAccountErrorUnsupported)); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = body ? @"POST" : @"GET";
    [request setValue:@"Cydia/2 RepositoryAccounts" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json, text/plain" forHTTPHeaderField:@"Accept"];
    if (body) {
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    CydiaAccountRequest *operation = [[CydiaAccountRequest alloc] init];
    operation.completion = completion; [operation start:request];
}
- (void)JSON:(NSString *)path account:(CydiaRepositoryAccount *)account body:(NSDictionary *)body
    completion:(void (^)(NSDictionary *, NSError *))completion {
    NSUUID *generation = [self generationForAccount:account advance:NO];
    [self request:[account.providerURL URLByAppendingPathComponent:path] body:body completion:
        ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *object = [value isKindOfClass:NSDictionary.class] ? value : nil;
        BOOL current = [generation isEqual:[self generationForAccount:account advance:NO]];
        NSString *requestToken = String(body[@"token"]);
        if (requestToken && !current) { completion(nil, AccountError(CydiaAccountErrorAuthentication)); return; }
        if (current && requestToken && [requestToken isEqual:String(Credentials(account)[@"token"])] &&
            [object[@"invalidate"] respondsToSelector:@selector(boolValue)] && [object[@"invalidate"] boolValue]) {
            ForgetToken(account); [self generationForAccount:account advance:YES];
        }
        if (error) { completion(nil, error); return; }
        if (response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 418) {
            completion(nil, AccountError(CydiaAccountErrorAuthentication)); return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300 || !object ||
            String(object[@"error"]) || (object[@"success"] && [object[@"success"] isEqual:@NO])) {
            completion(nil, AccountError(CydiaAccountErrorInvalidResponse)); return;
        }
        completion(object, nil);
    }];
}
- (void)discoverSource:(NSURL *)source name:(NSString *)name completion:(void (^)(CydiaRepositoryAccount *, NSError *))completion {
    if (!SecureURL(source) || source.query) {
        completion(nil, AccountError(CydiaAccountErrorUnsupported)); return;
    }
    [self request:[source URLByAppendingPathComponent:@"payment_endpoint"] body:nil completion:
        ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSString *text = data.length <= 8192 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSURL *provider = URLValue([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        if (error) { completion(nil, error); return; }
        if (response.statusCode == 404 || response.statusCode == 410 || response.statusCode == 501) {
            completion(nil, AccountError(CydiaAccountErrorUnsupported)); return;
        }
        if (response.statusCode != 200) {
            completion(nil, AccountError(CydiaAccountErrorTransport)); return;
        }
        if (!SecureURL(provider) || provider.query) {
            completion(nil, AccountError(CydiaAccountErrorUnsupported)); return;
        }
        CydiaRepositoryAccount *account = [[CydiaRepositoryAccount alloc] init];
        account.sourceURL = source; account.providerURL = provider; account.name = name;
        if (!account.supportsAccountIntegration) { completion(account, nil); return; }
        [self JSON:@"info" account:account body:nil completion:^(NSDictionary *info, NSError *error) {
            if (!error && String(info[@"name"])) {
                NSString *name = String(info[@"name"]);
                account.name = [name substringToIndex:MIN(name.length, (NSUInteger)256)];
            }
            completion(error ? nil : account, error);
        }];
    }];
}
- (NSMutableDictionary *)bodyForAccount:(CydiaRepositoryAccount *)account requireToken:(BOOL)required {
    if (!account.supportsAccountIntegration) return nil;
    NSDictionary *device = DeviceFields(); NSString *token = String(Credentials(account)[@"token"]);
    if ((required && !token) || !device) return nil;
    NSMutableDictionary *body = [device mutableCopy]; if (token) body[@"token"] = token; return body;
}
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session API_AVAILABLE(ios(13.0)) {
    return _presenter.view.window;
}
- (void)signIn:(CydiaRepositoryAccount *)account presenter:(UIViewController *)presenter completion:(void (^)(NSError *))completion {
    if (!account.supportsAccountIntegration) { completion(AccountError(CydiaAccountErrorUnsupported)); return; }
    if (_sessionIdentity || !presenter.view.window) { completion(AccountError(CydiaAccountErrorUnavailable)); return; }
    NSDictionary *device = DeviceFields();
    if (!device) { completion(AccountError(CydiaAccountErrorUnavailable)); return; }
    NSURLComponents *URL = [NSURLComponents componentsWithURL:[account.providerURL URLByAppendingPathComponent:@"authenticate"] resolvingAgainstBaseURL:NO];
    URL.queryItems = @[[NSURLQueryItem queryItemWithName:@"udid" value:device[@"udid"]],
        [NSURLQueryItem queryItemWithName:@"model" value:device[@"device"]]];
    NSUUID *identity = [NSUUID UUID];
    NSUUID *generation = [self generationForAccount:account advance:YES];
    _sessionIdentity = identity; _presenter = presenter;
    _authenticationAccountKey = AccountKey(account); _authenticationCompletion = completion;
    _receivedAuthenticationCallback = NO;
    /* The legacy scheme is captured only by this system authentication session.
     * Cydia never registers or routes another manager's global URL scheme. */
    _authenticationSession = [[ASWebAuthenticationSession alloc] initWithURL:URL.URL callbackURLScheme:@"sileo"
        completionHandler:^(NSURL *callback, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.sessionIdentity isEqual:identity] || self.receivedAuthenticationCallback) return;
            self.receivedAuthenticationCallback = YES; self.authenticationSession = nil;
            if (error) { [self finishAuthentication:identity error:AccountError(CydiaAccountErrorAuthentication)]; return; }
            if (!callback) { [self finishAuthentication:identity error:AccountError(CydiaAccountErrorInvalidResponse)]; return; }
            NSURLComponents *parts = [NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO];
            NSMutableDictionary *fields = [NSMutableDictionary dictionary]; NSMutableSet *names = [NSMutableSet set];
            BOOL duplicate = NO;
            for (NSURLQueryItem *item in parts.queryItems) {
                if ([names containsObject:item.name]) duplicate = YES;
                [names addObject:item.name];
                if (item.value) fields[item.name] = item.value;
            }
            NSString *token = String(fields[@"token"]);
            if (![parts.scheme.lowercaseString isEqual:@"sileo"] || ![parts.host isEqual:@"authentication_success"] ||
                parts.path.length != 0 || parts.user || parts.password || parts.port || parts.fragment || duplicate ||
                token.length == 0 || token.length > 8192) {
                [self finishAuthentication:identity error:AccountError(CydiaAccountErrorInvalidResponse)]; return;
            }
            /* Keep the session identity live through server validation. A
             * sign-out or newer login invalidates this attempt before any token
             * can be stored. Purchase secrets are deliberately not retained. */
            NSMutableDictionary *body = [device mutableCopy]; body[@"token"] = token;
            [self JSON:@"user_info" account:account body:body completion:^(NSDictionary *info, NSError *failure) {
                if (![self.sessionIdentity isEqual:identity]) return;
                if (![generation isEqual:[self generationForAccount:account advance:NO]]) {
                    [self finishAuthentication:identity error:AccountError(CydiaAccountErrorAuthentication)]; return;
                }
                if (failure || ![info[@"user"] isKindOfClass:NSDictionary.class]) {
                    [self finishAuthentication:identity error:failure ?: AccountError(CydiaAccountErrorInvalidResponse)]; return;
                }
                [self finishAuthentication:identity error:StoreToken(account, token) ? nil : AccountError(CydiaAccountErrorKeychain)];
            }];
        });
    }];
    if (@available(iOS 13.0, *)) _authenticationSession.presentationContextProvider = self;
    if (![_authenticationSession start])
        [self finishAuthentication:identity error:AccountError(CydiaAccountErrorUnavailable)];
}
- (void)signOut:(CydiaRepositoryAccount *)account completion:(void (^)(NSError *))completion {
    [self generationForAccount:account advance:YES];
    if ([_authenticationAccountKey isEqual:AccountKey(account)]) {
        ASWebAuthenticationSession *session = _authenticationSession;
        [self finishAuthentication:_sessionIdentity error:AccountError(CydiaAccountErrorAuthentication)];
        [session cancel];
    }
    NSString *token = String(Credentials(account)[@"token"]);
    if (!ForgetToken(account)) { completion(AccountError(CydiaAccountErrorKeychain)); return; }
    if (!token || !account.supportsAccountIntegration) { completion(nil); return; }
    [self JSON:@"sign_out" account:account body:@{@"token": token} completion:^(NSDictionary *value, NSError *error) { completion(error); }];
}
- (void)userInfo:(CydiaRepositoryAccount *)account completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!account.supportsAccountIntegration) { completion(nil, AccountError(CydiaAccountErrorUnsupported)); return; }
    NSDictionary *body = [self bodyForAccount:account requireToken:YES];
    if (!body) { completion(nil, AccountError(CydiaAccountErrorAuthentication)); return; }
    [self JSON:@"user_info" account:account body:body completion:completion];
}
- (NSString *)packagePath:(NSString *)package action:(NSString *)action {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789+.-"];
    if (package.length == 0 || [package rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return [NSString stringWithFormat:@"package/%@/%@", package, action];
}
- (void)anonymousPackageInfo:(NSString *)package account:(CydiaRepositoryAccount *)account completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *path = [self packagePath:package action:@"info"];
    if (!path) { completion(nil, AccountError(CydiaAccountErrorInvalidResponse)); return; }
    [self JSON:path account:account body:@{} completion:completion];
}
- (void)packageInfo:(NSString *)package account:(CydiaRepositoryAccount *)account completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *path = [self packagePath:package action:@"info"];
    if (!account.supportsAccountIntegration) { completion(nil, AccountError(CydiaAccountErrorUnsupported)); return; }
    NSDictionary *body = [self bodyForAccount:account requireToken:YES];
    if (!path || !body) { completion(nil, AccountError(CydiaAccountErrorAuthentication)); return; }
    [self JSON:path account:account body:body completion:completion];
}
- (void)authorizePackage:(NSString *)package version:(NSString *)version architecture:(NSString *)architecture
    account:(CydiaRepositoryAccount *)account completion:(void (^)(CydiaRepositoryDownloadGrant *, NSError *))completion {
    if (!account.supportsAccountIntegration) { completion(nil, AccountError(CydiaAccountErrorUnsupported)); return; }
    NSString *path = [self packagePath:package action:@"authorize_download"];
    NSMutableDictionary *body = [self bodyForAccount:account requireToken:YES];
    if (!path || !body || version.length == 0 || architecture.length == 0) {
        completion(nil, AccountError(CydiaAccountErrorAuthentication)); return;
    }
    body[@"version"] = version; body[@"architecture"] = architecture; body[@"repo"] = account.sourceURL.absoluteString;
    [self JSON:path account:account body:body completion:^(NSDictionary *value, NSError *error) {
        NSURL *URL = URLValue(value[@"url"]);
        NSString *token = body[@"token"];
        BOOL leaksToken = [URL.absoluteString containsString:token] ||
            [URL.absoluteString.stringByRemovingPercentEncoding containsString:token];
        if (error || !SecureURL(URL) || leaksToken || ![String(Credentials(account)[@"token"]) isEqual:token]) {
            completion(nil, error ?: AccountError(CydiaAccountErrorInvalidResponse)); return;
        }
        CydiaRepositoryDownloadGrant *grant = [[CydiaRepositoryDownloadGrant alloc] initPrivate];
        grant.transportURL = URL; grant.sourceURL = account.sourceURL; grant.package = package;
        grant.version = version; grant.architecture = architecture; grant.obtainedAt = [NSDate date];
        completion(grant, nil);
    }];
}
@end
