/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RepositoryAccountService.h"
#import "Cydia/AppState.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/utsname.h>
NSString *const CydiaAccountRecoveryURLKey = @"CydiaRepositoryRecoveryURL";

NSString *CydiaAccountLocalize(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Accounts"];
}
static NSError *AccountError(CydiaAccountError code) {
    NSString *key = code == CydiaAccountErrorUnsupported ? @"ACCOUNT_UNSUPPORTED" :
        code == CydiaAccountErrorAuthentication ? @"ACCOUNT_SIGN_IN_REQUIRED" :
        code == CydiaAccountErrorClientPolicy ? @"ACCOUNT_CLIENT_POLICY" :
        code == CydiaAccountErrorBotFilter ? @"ACCOUNT_FILTERED" :
        code == CydiaAccountErrorCancelled ? @"ACCOUNT_CANCELLED" :
        code == CydiaAccountErrorReauthentication ? @"ACCOUNT_REAUTHENTICATE" :
        code == CydiaAccountErrorOfferChanged ? @"ACCOUNT_OFFER_CHANGED" :
        code == CydiaAccountErrorProviderChanged ? @"ACCOUNT_PROVIDER_CHANGED" :
        code == CydiaAccountErrorPurchasePending ? @"ACCOUNT_PURCHASE_PENDING" :
        code == CydiaAccountErrorPurchaseUnknown ? @"ACCOUNT_PURCHASE_UNKNOWN" : @"ACCOUNT_REQUEST_FAILED";
    return [NSError errorWithDomain:@"CydiaRepositoryAccount" code:code
        userInfo:@{NSLocalizedDescriptionKey: CydiaAccountLocalize(key)}];
}
static BOOL SecureURL(NSURL *URL) {
    NSString *text = URL.absoluteString, *decoded = text.stringByRemovingPercentEncoding;
    return text.length > 0 && text.length <= 8192 && decoded != nil &&
        [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound &&
        [decoded rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound &&
        ![text containsString:@"\\"] && ![decoded containsString:@"\\"] &&
        [URL.scheme.lowercaseString isEqual:@"https"] && URL.host.length != 0 &&
        (!URL.port || (URL.port.integerValue > 0 && URL.port.integerValue <= 65535)) &&
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
static BOOL JSONBooleanIs(id value, BOOL expected) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() &&
        [value boolValue] == expected;
}
static BOOL SuccessfulJSON(NSDictionary *object) {
    return object && (!object[@"error"] || object[@"error"] == NSNull.null) &&
        (!object[@"success"] || JSONBooleanIs(object[@"success"], YES));
}
static BOOL ExplicitlyFreePackage(NSDictionary *info) {
    id price = info[@"price"];
    return JSONBooleanIs(info[@"free"], YES) || ([price isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)price) != CFBooleanGetTypeID() && [price doubleValue] == 0);
}
static BOOL UnownedPaidOffer(NSDictionary *info) {
    return JSONBooleanIs(info[@"available"], YES) && JSONBooleanIs(info[@"purchased"], NO) && !ExplicitlyFreePackage(info);
}
static NSError *OfferFailure(NSDictionary *info) {
    return AccountError(!JSONBooleanIs(info[@"available"], YES) && !JSONBooleanIs(info[@"available"], NO) ? CydiaAccountErrorInvalidResponse :
        JSONBooleanIs(info[@"available"], NO) ? CydiaAccountErrorUnavailable :
        ExplicitlyFreePackage(info) ? CydiaAccountErrorOfferChanged :
        !JSONBooleanIs(info[@"purchased"], NO) ? CydiaAccountErrorInvalidResponse : CydiaAccountErrorOfferChanged);
}
static dispatch_queue_t CredentialQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.saurik.Cydia.repository-credentials", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static NSUserDefaults *AccountDefaults(void) {
#if defined(CYDIA_REPOSITORY_ACCOUNT_TESTING)
    static NSUserDefaults *defaults; static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.saurik.Cydia.repository-account-fixtures"]; });
    return defaults;
#else
    return NSUserDefaults.standardUserDefaults;
#endif
}
static BOOL HostIs(NSURL *URL, NSString *host) {
    return [URL.host.lowercaseString isEqual:host] || [URL.host.lowercaseString hasSuffix:[@"." stringByAppendingString:host]];
}
static NSDictionary *DeviceFields(void) {
#if defined(CYDIA_REPOSITORY_ACCOUNT_TESTING)
    return CydiaRepositoryAccountTestDeviceFields();
#else
    NSString *identifier = UniqueIdentifier();
    struct utsname info;
    if (identifier.length == 0 || uname(&info) != 0) return nil;
    return @{@"udid": identifier, @"device": [NSString stringWithUTF8String:info.machine]};
#endif
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
static BOOL StoreToken(CydiaRepositoryAccount *account, NSString *token, NSString *mode) {
    NSDictionary *query = KeyQuery(account);
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"token": token, @"purchase_auth": mode} options:0 error:nil];
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
static NSDictionary *SecretQuery(CydiaRepositoryAccount *account) {
    NSMutableDictionary *query = [KeyQuery(account) mutableCopy];
    query[(__bridge id)kSecAttrService] = @"com.saurik.Cydia.repository-account.v1.purchase";
    return query;
}
static BOOL ForgetCredentials(CydiaRepositoryAccount *account) {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)SecretQuery(account));
    return ForgetToken(account) && (status == errSecSuccess || status == errSecItemNotFound);
}
static BOOL StoreSecret(CydiaRepositoryAccount *account, NSString *secret) {
    SecAccessControlRef control = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, kSecAccessControlUserPresence, NULL);
    if (!control) return NO;
    NSMutableDictionary *item = [SecretQuery(account) mutableCopy];
    item[(__bridge id)kSecAttrAccessControl] = CFBridgingRelease(control);
    item[(__bridge id)kSecValueData] = [secret dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus removed = SecItemDelete((__bridge CFDictionaryRef)SecretQuery(account));
    if (removed != errSecSuccess && removed != errSecItemNotFound) return NO;
    return SecItemAdd((__bridge CFDictionaryRef)item, NULL) == errSecSuccess;
}
static NSString *AccountKey(CydiaRepositoryAccount *account) {
    return KeyQuery(account)[(__bridge id)kSecAttrAccount];
}

@interface CydiaRepositoryAccount ()
@property(nonatomic, copy, readwrite) NSURL *sourceURL, *providerURL;
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, copy) NSString *token, *purchaseCredentialMode;
@property(nonatomic, strong) NSUUID *credentialGeneration;
@property(nonatomic, weak) CydiaRepositoryAccountService *service;
@end
@interface CydiaRepositoryAccountService (CredentialGeneration)
- (NSUUID *)generationForAccount:(CydiaRepositoryAccount *)account advance:(BOOL)advance;
@end
@implementation CydiaRepositoryAccount
- (CydiaRepositoryCapabilities)capabilities {
    CydiaRepositoryCapabilities value = CydiaRepositoryCapabilityLogin | CydiaRepositoryCapabilityEntitlements;
    /* The published vendor policy excludes paid Cydia delivery. Discovery is
     * still useful for reading an account; it does not override that policy. */
    if (HostIs(self.sourceURL, @"havoc.app") || HostIs(self.providerURL, @"havoc.app")) return value;
    return value | CydiaRepositoryCapabilityDirectPurchase | CydiaRepositoryCapabilityHostedCheckout |
        CydiaRepositoryCapabilityDownload;
}
- (BOOL)supportsAccountIntegration { return (self.capabilities & CydiaRepositoryCapabilityLogin) != 0; }
- (NSString *)compatibilityNotice {
    if (!(self.capabilities & CydiaRepositoryCapabilityDownload)) return CydiaAccountLocalize(@"ACCOUNT_CLIENT_POLICY");
    if (HostIs(self.sourceURL, @"chariz.com") || HostIs(self.providerURL, @"chariz.com"))
        return CydiaAccountLocalize(@"ACCOUNT_COMPATIBILITY_UNVERIFIED");
    return nil;
}
- (BOOL)signedIn { return self.supportsAccountIntegration && _token.length != 0 &&
    [_credentialGeneration isEqual:[_service generationForAccount:self advance:NO]]; }
- (NSString *)description { return [NSString stringWithFormat:@"<RepositoryAccount %@>", CydiaAccountOrigin(self.sourceURL)]; }
@end
static NSString *CredentialBinding(CydiaRepositoryAccount *account) {
    if (!account.token.length) return nil;
    NSData *data = [[NSString stringWithFormat:@"%@\n%@", AccountKey(account), account.token] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *binding = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (unsigned char byte : digest) [binding appendFormat:@"%02x", byte];
    return binding;
}
static NSError *WithRecovery(NSError *error, id recovery, CydiaRepositoryAccount *account, NSDictionary *body) {
    NSURL *URL = URLValue(recovery);
    if (!error || !SecureURL(URL) || URL.query) return error;
    BOOL allowed = [CydiaAccountOrigin(URL) isEqual:CydiaAccountOrigin(account.providerURL)] ||
        [CydiaAccountOrigin(URL) isEqual:CydiaAccountOrigin(account.sourceURL)];
    if ((HostIs(account.providerURL, @"chariz.com") || HostIs(account.sourceURL, @"chariz.com")) &&
        [URL.host.lowercaseString isEqual:@"docs.chariz.com"] && (!URL.port || URL.port.integerValue == 443)) allowed = YES;
    if ((HostIs(account.providerURL, @"havoc.app") || HostIs(account.sourceURL, @"havoc.app")) &&
        [URL.host.lowercaseString isEqual:@"docs.havoc.app"] && (!URL.port || URL.port.integerValue == 443)) allowed = YES;
    NSString *decoded = URL.absoluteString.stringByRemovingPercentEncoding;
    for (id secret in @[body[@"token"] ?: NSNull.null, body[@"payment_secret"] ?: NSNull.null, account.token ?: NSNull.null]) {
        if (String(secret) && ([URL.absoluteString containsString:secret] || [decoded containsString:secret])) allowed = NO;
    }
    if (!allowed) return error;
    NSMutableDictionary *info = [error.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    info[CydiaAccountRecoveryURLKey] = URL;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:info];
}
@interface CydiaRepositoryPurchaseResult ()
@property(nonatomic, readwrite) CydiaRepositoryPurchaseState state;
@property(nonatomic, copy, readwrite) NSDictionary *packageInfo;
@property(nonatomic, strong, readwrite) NSError *error;
@end
@implementation CydiaRepositoryPurchaseResult
- (instancetype)initPrivate { return [super init]; }
@end
static CydiaRepositoryPurchaseResult *PurchaseResult(CydiaRepositoryPurchaseState state, NSDictionary *info, NSError *error) {
    CydiaRepositoryPurchaseResult *result = [[CydiaRepositoryPurchaseResult alloc] initPrivate];
    result.state = state; result.packageInfo = info; result.error = error; return result;
}
@interface CydiaRepositoryAccessResult ()
@property(nonatomic, readwrite) CydiaRepositoryAccessState state;
@property(nonatomic, strong, readwrite) CydiaRepositoryAccount *account;
@property(nonatomic, copy, readwrite) NSDictionary *packageInfo;
@property(nonatomic, strong, readwrite) NSError *error;
@property(nonatomic, copy, readwrite) NSURL *sourceURL;
@property(nonatomic, copy, readwrite) NSString *package, *version, *architecture;
@end
@implementation CydiaRepositoryAccessResult
- (instancetype)initPrivate { return [super init]; }
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
@property(nonatomic, copy) void (^purchaseCompletion)(CydiaRepositoryPurchaseResult *);
@property(nonatomic, strong) CydiaRepositoryAccount *purchaseAccount;
@property(nonatomic, copy) NSString *purchasePackage;
@property(nonatomic, strong) NSUUID *purchaseGeneration;
@property(nonatomic, strong) LAContext *purchaseAuthenticationContext;
@property(nonatomic, copy) BOOL (^purchaseSelectionValidator)(void);
@property(nonatomic, copy) void (^purchaseSelectionPreparation)(void (^)(BOOL));
@property(nonatomic, copy) NSURL *purchaseRecoveryURL;
@end
@implementation CydiaRepositoryAccountService
+ (instancetype)sharedService {
    static CydiaRepositoryAccountService *service; static dispatch_once_t once;
    dispatch_once(&once, ^{ service = [[self alloc] init]; }); return service;
}
- (NSArray<NSDictionary *> *)rememberedAccounts {
    id value = [AccountDefaults() arrayForKey:@"RepositoryAccounts.v1"];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (id entry in value) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSURL *source = URLValue(entry[@"source"]), *provider = URLValue(entry[@"provider"]);
        if (SecureURL(source) && !source.query && SecureURL(provider) && !provider.query && String(entry[@"name"]))
            [result addObject:@{@"source": source.absoluteString, @"provider": provider.absoluteString, @"name": entry[@"name"]}];
    }
    return result;
}
- (void)rememberAccount:(CydiaRepositoryAccount *)account {
    NSMutableArray *values = [[self rememberedAccounts] mutableCopy];
    NSDictionary *entry = @{@"source": account.sourceURL.absoluteString, @"provider": account.providerURL.absoluteString, @"name": account.name};
    [values removeObject:entry];
    NSIndexSet *old = [values indexesOfObjectsPassingTest:^BOOL(NSDictionary *value, NSUInteger index, BOOL *stop) {
        return [value[@"source"] isEqual:entry[@"source"]] && [value[@"provider"] isEqual:entry[@"provider"]];
    }];
    [values removeObjectsAtIndexes:old]; [values addObject:entry];
    [AccountDefaults() setObject:values forKey:@"RepositoryAccounts.v1"];
}
- (void)removeRememberedAccount:(NSDictionary *)metadata completion:(void (^)(NSError *))completion {
    if (![[self rememberedAccounts] containsObject:metadata]) { completion(AccountError(CydiaAccountErrorInvalidResponse)); return; }
    CydiaRepositoryAccount *account = [CydiaRepositoryAccount new];
    account.sourceURL = URLValue(metadata[@"source"]); account.providerURL = URLValue(metadata[@"provider"]); account.name = metadata[@"name"];
    [self generationForAccount:account advance:YES];
    if ([_authenticationAccountKey isEqual:AccountKey(account)]) {
        ASWebAuthenticationSession *session = _authenticationSession;
        if (_purchaseCompletion) [self finishPurchase:_sessionIdentity state:CydiaRepositoryPurchaseStateUnknown info:nil error:AccountError(CydiaAccountErrorPurchaseUnknown)];
        else [self finishAuthentication:_sessionIdentity error:AccountError(CydiaAccountErrorCancelled)];
        [session cancel];
    }
    dispatch_async(CredentialQueue(), ^{
        BOOL removed = ForgetCredentials(account);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (removed) {
                NSMutableArray *values = [[self rememberedAccounts] mutableCopy]; [values removeObject:metadata];
                [AccountDefaults() setObject:values forKey:@"RepositoryAccounts.v1"];
            }
            completion(removed ? nil : AccountError(CydiaAccountErrorKeychain));
        });
    });
}
- (NSString *)purchaseKey:(NSString *)package account:(CydiaRepositoryAccount *)account {
    return [NSString stringWithFormat:@"%@\n%@", AccountKey(account), package];
}
- (BOOL)hasUnresolvedPurchase:(NSString *)package account:(CydiaRepositoryAccount *)account {
    NSDictionary *attempts = [AccountDefaults() dictionaryForKey:@"RepositoryPurchases.v1"];
    return [attempts[[self purchaseKey:package account:account]] isKindOfClass:NSDictionary.class];
}
- (BOOL)recordPurchase:(NSString *)package account:(CydiaRepositoryAccount *)account value:(NSDictionary *)value {
    NSMutableDictionary *attempts = [[AccountDefaults() dictionaryForKey:@"RepositoryPurchases.v1"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *key = [self purchaseKey:package account:account];
    if (value) attempts[key] = value; else [attempts removeObjectForKey:key];
    [AccountDefaults() setObject:attempts forKey:@"RepositoryPurchases.v1"];
    /* Persist before a possibly chargeable request. Losing this marker across a
     * crash must not silently turn an uncertain purchase into a retry. */
    return [AccountDefaults() synchronize];
}
- (void)settlePurchase:(NSString *)package account:(CydiaRepositoryAccount *)account {
    NSDictionary *attempt = [AccountDefaults() dictionaryForKey:@"RepositoryPurchases.v1"][[self purchaseKey:package account:account]];
    NSString *binding = CredentialBinding(account);
    /* Another user's ownership cannot resolve a possibly submitted charge.
     * v1 has no guaranteed stable account identifier, so a changed credential
     * is conservatively unable to clear an earlier credential's uncertainty. */
    if (binding && [attempt[@"credential"] isEqual:binding]) [self recordPurchase:package account:account value:nil];
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
#if defined(CYDIA_REPOSITORY_ACCOUNT_TESTING)
    NSString *version = @"fixture";
#else
    NSString *version = Cydia_ ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
#endif
    [request setValue:[NSString stringWithFormat:@"Cydia/%@ RepositoryAccounts/1", version] forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"API" forHTTPHeaderField:@"Payment-Provider"];
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
        if (current && requestToken && JSONBooleanIs(object[@"invalidate"], YES)) {
            if ([requestToken isEqual:account.token]) {
                account.token = nil; account.purchaseCredentialMode = nil;
                [self generationForAccount:account advance:YES];
                dispatch_async(CredentialQueue(), ^{ ForgetCredentials(account); });
            }
            // A login-validation response can invalidate a not-yet-stored
            // callback token. Do not replace a previous login with that token.
            completion(nil, WithRecovery(AccountError(CydiaAccountErrorAuthentication), object[@"recovery_url"], account, body)); return;
        }
        if (error) { completion(nil, WithRecovery(error, object[@"recovery_url"], account, body)); return; }
        if (response.statusCode == 403 && !object) {
            completion(nil, WithRecovery(AccountError(CydiaAccountErrorBotFilter), object[@"recovery_url"], account, body)); return;
        }
        if (response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 418) {
            completion(nil, WithRecovery(AccountError(CydiaAccountErrorAuthentication), object[@"recovery_url"], account, body)); return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300 || !object ||
            !SuccessfulJSON(object)) {
            completion(nil, WithRecovery(AccountError(CydiaAccountErrorInvalidResponse), object[@"recovery_url"], account, body)); return;
        }
        completion(object, nil);
    }];
}
- (void)discoverSource:(NSURL *)source name:(NSString *)name completion:(void (^)(CydiaRepositoryAccount *, NSError *))completion {
    if (!SecureURL(source) || source.query) {
        completion(nil, AccountError(HostIs(source, @"havoc.app") ? CydiaAccountErrorClientPolicy : CydiaAccountErrorUnsupported)); return;
    }
    [self request:[source URLByAppendingPathComponent:@"payment_endpoint"] body:nil completion:
        ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSString *text = data.length <= 8192 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSURL *provider = URLValue([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        if (error) { completion(nil, error); return; }
        if (response.statusCode == 404 || response.statusCode == 410 || response.statusCode == 501) {
            completion(nil, AccountError(HostIs(source, @"havoc.app") ? CydiaAccountErrorClientPolicy :
                CydiaAccountErrorUnsupported)); return;
        }
        if (response.statusCode != 200) {
            completion(nil, AccountError(response.statusCode == 403 ? CydiaAccountErrorBotFilter : CydiaAccountErrorTransport)); return;
        }
        if (!SecureURL(provider) || provider.query) {
            completion(nil, AccountError(CydiaAccountErrorInvalidResponse)); return;
        }
        CydiaRepositoryAccount *account = [[CydiaRepositoryAccount alloc] init];
        account.sourceURL = source; account.providerURL = provider; account.name = name; account.service = self;
        NSUUID *generation = [self generationForAccount:account advance:NO];
        [self JSON:@"info" account:account body:nil completion:^(NSDictionary *info, NSError *error) {
            if (!error && String(info[@"name"])) {
                NSString *name = String(info[@"name"]);
                account.name = [name substringToIndex:MIN(name.length, (NSUInteger)256)];
            }
            if (error) { completion(nil, error); return; }
            dispatch_async(CredentialQueue(), ^{
                NSDictionary *credentials = Credentials(account);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([generation isEqual:[self generationForAccount:account advance:NO]]) {
                        account.credentialGeneration = generation;
                        account.token = String(credentials[@"token"]);
                        account.purchaseCredentialMode = String(credentials[@"purchase_auth"]) ?: @"legacy";
                        if (account.token) [self rememberAccount:account];
                    }
                    completion(account, nil);
                });
            });
        }];
    }];
}
- (NSMutableDictionary *)bodyForAccount:(CydiaRepositoryAccount *)account requireToken:(BOOL)required {
    if (!account.supportsAccountIntegration) return nil;
    if (account.token && ![account.credentialGeneration isEqual:[self generationForAccount:account advance:NO]]) return nil;
    NSDictionary *device = DeviceFields(); NSString *token = account.token;
    if ((required && !token) || !device) return nil;
    NSMutableDictionary *body = [device mutableCopy]; if (token) body[@"token"] = token; return body;
}
- (void)preflightPackage:(NSString *)package version:(NSString *)version architecture:(NSString *)architecture
    source:(NSURL *)source name:(NSString *)name completion:(void (^)(CydiaRepositoryAccessResult *))completion {
    package = [package copy]; version = [version copy]; architecture = [architecture copy]; source = [source copy]; name = [name copy];
    CydiaRepositoryAccessResult *result = [[CydiaRepositoryAccessResult alloc] initPrivate];
    result.sourceURL = source; result.package = package; result.version = version; result.architecture = architecture;
    void (^finish)(CydiaRepositoryAccessState, NSDictionary *, NSError *) = ^(CydiaRepositoryAccessState state, NSDictionary *info, NSError *error) {
        result.state = state; result.packageInfo = info; result.error = error; completion(result);
    };
    if (![self packagePath:package action:@"info"] || !version.length || !architecture.length || !source.host.length) {
        finish(CydiaRepositoryAccessStateFailed, nil, AccountError(CydiaAccountErrorInvalidResponse)); return;
    }
    [self discoverSource:source name:name completion:^(CydiaRepositoryAccount *account, NSError *error) {
        result.account = account;
        if (error) {
            CydiaRepositoryAccessState state = [error.domain isEqual:@"CydiaRepositoryAccount"] && error.code == CydiaAccountErrorUnsupported ?
                CydiaRepositoryAccessStateNotRequired : error.code == CydiaAccountErrorClientPolicy ? CydiaRepositoryAccessStateUnsupported : CydiaRepositoryAccessStateFailed;
            finish(state, nil, state == CydiaRepositoryAccessStateNotRequired ? nil : error); return;
        }
        void (^inspect)(NSDictionary *, NSError *, BOOL) = ^(NSDictionary *info, NSError *failure, BOOL authenticated) {
            if (!failure && !JSONBooleanIs(info[@"available"], YES) && !JSONBooleanIs(info[@"available"], NO)) {
                finish(CydiaRepositoryAccessStateFailed, nil, AccountError(CydiaAccountErrorInvalidResponse)); return;
            }
            if (!failure && JSONBooleanIs(info[@"available"], NO)) {
                finish(CydiaRepositoryAccessStateUnavailable, info, AccountError(CydiaAccountErrorUnavailable)); return;
            }
            id price = info[@"price"];
            BOOL freePackage = JSONBooleanIs(info[@"free"], YES) || ([price isKindOfClass:NSNumber.class] &&
                CFGetTypeID((__bridge CFTypeRef)price) != CFBooleanGetTypeID() && [price doubleValue] == 0);
            if (!failure && freePackage) { finish(CydiaRepositoryAccessStateNotRequired, info, nil); return; }
            if (failure && failure.code != CydiaAccountErrorAuthentication) { finish(CydiaRepositoryAccessStateFailed, nil, failure); return; }
            if (!(account.capabilities & CydiaRepositoryCapabilityDownload)) {
                finish(CydiaRepositoryAccessStateUnsupported, info, AccountError(CydiaAccountErrorClientPolicy)); return;
            }
            if (!authenticated) return;
            if (failure || !account.signedIn) { finish(CydiaRepositoryAccessStateSignIn, nil, failure ?: AccountError(CydiaAccountErrorAuthentication)); return; }
            if (JSONBooleanIs(info[@"purchased"], YES)) { finish(CydiaRepositoryAccessStateReady, info, nil); return; }
            if (JSONBooleanIs(info[@"purchased"], NO)) { finish(CydiaRepositoryAccessStatePurchaseRequired, info, nil); return; }
            finish(CydiaRepositoryAccessStateFailed, nil, AccountError(CydiaAccountErrorInvalidResponse));
        };
        [self anonymousPackageInfo:package account:account completion:^(NSDictionary *info, NSError *failure) {
            id price = info[@"price"];
            BOOL freePackage = JSONBooleanIs(info[@"free"], YES) || ([price isKindOfClass:NSNumber.class] &&
                CFGetTypeID((__bridge CFTypeRef)price) != CFBooleanGetTypeID() && [price doubleValue] == 0);
            if ((!failure && (!JSONBooleanIs(info[@"available"], YES) || freePackage)) ||
                (failure && failure.code != CydiaAccountErrorAuthentication) || !(account.capabilities & CydiaRepositoryCapabilityDownload)) {
                inspect(info, failure, NO); return;
            }
            if (!account.signedIn) { finish(CydiaRepositoryAccessStateSignIn, info, AccountError(CydiaAccountErrorAuthentication)); return; }
            [self packageInfo:package account:account completion:^(NSDictionary *owned, NSError *error) { inspect(owned, error, YES); }];
        }];
    }];
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
            NSString *secret = String(fields[@"payment_secret"]);
            if (![parts.scheme.lowercaseString isEqual:@"sileo"] || ![parts.host isEqual:@"authentication_success"] ||
                parts.path.length != 0 || parts.user || parts.password || parts.port || parts.fragment || duplicate ||
                token.length == 0 || token.length > 8192 || secret.length > 8192) {
                [self finishAuthentication:identity error:AccountError(CydiaAccountErrorInvalidResponse)]; return;
            }
            /* Keep the session identity live through server validation. A
             * sign-out or newer login invalidates this attempt before any token
             * can be stored. Purchase authority is stored separately, with
             * device-owner presence rather than a reusable plain credential. */
            NSMutableDictionary *body = [device mutableCopy]; body[@"token"] = token;
            [self JSON:@"user_info" account:account body:body completion:^(NSDictionary *info, NSError *failure) {
                if (![self.sessionIdentity isEqual:identity]) return;
                if (![generation isEqual:[self generationForAccount:account advance:NO]]) {
                    [self finishAuthentication:identity error:AccountError(CydiaAccountErrorAuthentication)]; return;
                }
                if (failure || ![info[@"user"] isKindOfClass:NSDictionary.class]) {
                    [self finishAuthentication:identity error:failure ?: AccountError(CydiaAccountErrorInvalidResponse)]; return;
                }
                dispatch_async(CredentialQueue(), ^{
                    if (![generation isEqual:[self generationForAccount:account advance:NO]]) return;
                    LAContext *context = [LAContext new]; NSError *authenticationError = nil;
                    BOOL canProtectSecret = [context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&authenticationError];
                    BOOL noPasscode = !canProtectSecret && [authenticationError.domain isEqual:LAErrorDomain] && authenticationError.code == LAErrorPasscodeNotSet;
                    NSString *mode = secret && canProtectSecret ? @"protected" : (noPasscode ? @"hosted" : @"missing");
                    BOOL saved = ForgetCredentials(account) && (!secret || !canProtectSecret || StoreSecret(account, secret)) &&
                        StoreToken(account, token, mode);
                    if (!saved) ForgetCredentials(account);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (![self.sessionIdentity isEqual:identity] ||
                            ![generation isEqual:[self generationForAccount:account advance:NO]]) return;
                        if (saved) {
                            account.token = token; account.purchaseCredentialMode = mode;
                            account.credentialGeneration = generation; [self rememberAccount:account];
                        }
                        [self finishAuthentication:identity error:saved ? nil : AccountError(CydiaAccountErrorKeychain)];
                    });
                });
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
        if (_purchaseCompletion) [self finishPurchase:_sessionIdentity state:CydiaRepositoryPurchaseStateUnknown info:nil error:AccountError(CydiaAccountErrorPurchaseUnknown)];
        else [self finishAuthentication:_sessionIdentity error:AccountError(CydiaAccountErrorAuthentication)];
        [session cancel];
    }
    NSString *token = account.token; account.token = nil; account.purchaseCredentialMode = nil;
    dispatch_async(CredentialQueue(), ^{
        BOOL removed = ForgetCredentials(account);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!removed) { completion(AccountError(CydiaAccountErrorKeychain)); return; }
            if (!token || !account.supportsAccountIntegration) { completion(nil); return; }
            [self JSON:@"sign_out" account:account body:@{@"token": token} completion:^(NSDictionary *value, NSError *error) { completion(error); }];
        });
    });
}
- (void)userInfo:(CydiaRepositoryAccount *)account completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!account.supportsAccountIntegration) { completion(nil, AccountError(CydiaAccountErrorUnsupported)); return; }
    NSDictionary *body = [self bodyForAccount:account requireToken:YES];
    if (!body) { completion(nil, AccountError(CydiaAccountErrorAuthentication)); return; }
    [self JSON:@"user_info" account:account body:body completion:completion];
}
- (NSString *)packagePath:(NSString *)package action:(NSString *)action {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789+.-"];
    NSCharacterSet *initial = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789"];
    if (package.length < 2 || package.length > 256 || ![initial characterIsMember:[package characterAtIndex:0]] ||
        [package rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return [NSString stringWithFormat:@"package/%@/%@", package, action];
}
- (void)anonymousPackageInfo:(NSString *)package account:(CydiaRepositoryAccount *)account completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *path = [self packagePath:package action:@"info"];
    if (!path) { completion(nil, AccountError(CydiaAccountErrorInvalidResponse)); return; }
    [self request:[account.providerURL URLByAppendingPathComponent:path] body:nil completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (!error && (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501)) {
            [self JSON:path account:account body:@{} completion:completion]; return;
        }
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *info = [value isKindOfClass:NSDictionary.class] ? value : nil;
        if (error || response.statusCode < 200 || response.statusCode >= 300 || !SuccessfulJSON(info)) {
            completion(nil, WithRecovery(error ?: AccountError(response.statusCode == 403 && !info ? CydiaAccountErrorBotFilter : CydiaAccountErrorInvalidResponse), info[@"recovery_url"], account, nil)); return;
        }
        completion(info, nil);
    }];
}
- (void)packageInfo:(NSString *)package account:(CydiaRepositoryAccount *)account completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *path = [self packagePath:package action:@"info"];
    if (!account.supportsAccountIntegration) { completion(nil, AccountError(CydiaAccountErrorUnsupported)); return; }
    NSDictionary *body = [self bodyForAccount:account requireToken:YES];
    if (!path || !body) { completion(nil, AccountError(CydiaAccountErrorAuthentication)); return; }
    [self JSON:path account:account body:body completion:^(NSDictionary *info, NSError *error) {
        if (!error && JSONBooleanIs(info[@"purchased"], YES) && !ExplicitlyFreePackage(info)) [self settlePurchase:package account:account];
        completion(info, error);
    }];
}
- (void)authorizePackage:(NSString *)package version:(NSString *)version architecture:(NSString *)architecture
    account:(CydiaRepositoryAccount *)account completion:(void (^)(CydiaRepositoryDownloadGrant *, NSError *))completion {
    package = [package copy]; version = [version copy]; architecture = [architecture copy];
    if (!(account.capabilities & CydiaRepositoryCapabilityDownload)) { completion(nil, AccountError(CydiaAccountErrorClientPolicy)); return; }
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
        if (error || !SecureURL(URL) || leaksToken || ![account.token isEqual:token]) {
            completion(nil, error ?: AccountError(CydiaAccountErrorInvalidResponse)); return;
        }
        CydiaRepositoryDownloadGrant *grant = [[CydiaRepositoryDownloadGrant alloc] initPrivate];
        grant.transportURL = URL; grant.sourceURL = account.sourceURL; grant.package = package;
        grant.version = version; grant.architecture = architecture; grant.obtainedAt = [NSDate date];
        completion(grant, nil);
    }];
}
- (BOOL)purchaseIsCurrent:(NSUUID *)identity {
    if (![_sessionIdentity isEqual:identity] || !_purchaseCompletion) return NO;
    if (![_purchaseGeneration isEqual:[self generationForAccount:_purchaseAccount advance:NO]]) {
        BOOL submitted = [self hasUnresolvedPurchase:_purchasePackage account:_purchaseAccount];
        [self finishPurchase:identity state:submitted ? CydiaRepositoryPurchaseStateUnknown : CydiaRepositoryPurchaseStateRejected
            info:nil error:AccountError(submitted ? CydiaAccountErrorPurchaseUnknown : CydiaAccountErrorAuthentication)];
        return NO;
    }
    return YES;
}
- (void)finishPurchase:(NSUUID *)identity state:(CydiaRepositoryPurchaseState)state info:(NSDictionary *)info error:(NSError *)error {
    if (![_sessionIdentity isEqual:identity] || !_purchaseCompletion) return;
    void (^completion)(CydiaRepositoryPurchaseResult *) = _purchaseCompletion;
    if (error && _purchaseRecoveryURL) error = WithRecovery(error, _purchaseRecoveryURL.absoluteString, _purchaseAccount, nil);
    if (error && !error.userInfo[CydiaAccountRecoveryURLKey] &&
        (state == CydiaRepositoryPurchaseStatePending || state == CydiaRepositoryPurchaseStateUnknown)) {
        NSString *help = HostIs(_purchaseAccount.providerURL, @"chariz.com") ? @"https://docs.chariz.com/help/payment-pending" :
            HostIs(_purchaseAccount.providerURL, @"havoc.app") ? @"https://docs.havoc.app/docs/help/contact_us/" : nil;
        error = WithRecovery(error, help, _purchaseAccount, nil);
    }
    _purchaseCompletion = nil; _purchaseAccount = nil; _purchasePackage = nil; _purchaseGeneration = nil;
    _purchaseSelectionValidator = nil;
    _purchaseSelectionPreparation = nil;
    _purchaseRecoveryURL = nil;
    [_purchaseAuthenticationContext invalidate]; _purchaseAuthenticationContext = nil;
    _sessionIdentity = nil; _authenticationSession = nil; _presenter = nil; _authenticationAccountKey = nil;
    _receivedAuthenticationCallback = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(PurchaseResult(state, info, error)); });
}
- (void)cancelPurchaseForAccount:(CydiaRepositoryAccount *)account {
    if (!_purchaseCompletion || ![AccountKey(account) isEqual:_authenticationAccountKey]) return;
    BOOL submitted = [self hasUnresolvedPurchase:_purchasePackage account:_purchaseAccount];
    ASWebAuthenticationSession *session = _authenticationSession;
    [self finishPurchase:_sessionIdentity state:submitted ? CydiaRepositoryPurchaseStateUnknown : CydiaRepositoryPurchaseStateCancelled
        info:nil error:AccountError(submitted ? CydiaAccountErrorPurchaseUnknown : CydiaAccountErrorCancelled)];
    [session cancel];
}
- (void)verifyPurchase:(NSUUID *)identity fallback:(CydiaRepositoryPurchaseState)fallback {
    if (![self purchaseIsCurrent:identity]) return;
    CydiaRepositoryAccount *account = _purchaseAccount; NSString *package = _purchasePackage;
    [self packageInfo:package account:account completion:^(NSDictionary *info, NSError *error) {
        if (![self purchaseIsCurrent:identity]) return;
        if (!error && JSONBooleanIs(info[@"purchased"], YES) && !ExplicitlyFreePackage(info)) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateOwned info:info error:nil]; return;
        }
        CydiaRepositoryPurchaseState state = error ? CydiaRepositoryPurchaseStateUnknown : fallback;
        [self finishPurchase:identity state:state info:info error:AccountError(state == CydiaRepositoryPurchaseStateUnknown ? CydiaAccountErrorPurchaseUnknown : CydiaAccountErrorPurchasePending)];
    }];
}
- (void)checkout:(NSURL *)URL identity:(NSUUID *)identity {
    if (![self purchaseIsCurrent:identity]) return;
    _receivedAuthenticationCallback = NO;
    _authenticationSession = [[ASWebAuthenticationSession alloc] initWithURL:URL callbackURLScheme:@"sileo"
        completionHandler:^(NSURL *callback, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self purchaseIsCurrent:identity] || self.receivedAuthenticationCallback) return;
            self.receivedAuthenticationCallback = YES; self.authenticationSession = nil;
            NSURLComponents *parts = callback ? [NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO] : nil;
            BOOL valid = [parts.scheme.lowercaseString isEqual:@"sileo"] && [parts.host isEqual:@"payment_completed"] &&
                parts.path.length == 0 && !parts.user && !parts.password && !parts.port && !parts.query && !parts.fragment;
            /* A checkout cancellation does not establish whether the provider
             * processed a payment. Always ask for fresh ownership, never retry. */
            [self verifyPurchase:identity fallback:(valid || error) ? CydiaRepositoryPurchaseStatePending : CydiaRepositoryPurchaseStateUnknown];
        });
    }];
    if (@available(iOS 13.0, *)) _authenticationSession.presentationContextProvider = self;
    if (![_authenticationSession start]) [self verifyPurchase:identity fallback:CydiaRepositoryPurchaseStatePending];
}
- (BOOL)validatePurchaseSelection:(NSUUID *)identity {
    if (![self purchaseIsCurrent:identity]) return NO;
    if (_purchaseSelectionValidator && !_purchaseSelectionValidator()) {
        [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:nil error:AccountError(CydiaAccountErrorUnavailable)];
        return NO;
    }
    return YES;
}
- (void)sendConfirmedPurchase:(NSUUID *)identity secret:(NSString *)secret version:(NSString *)version architecture:(NSString *)architecture price:(NSString *)price {
    if (![self validatePurchaseSelection:identity]) return;
    CydiaRepositoryAccount *account = _purchaseAccount; NSString *package = _purchasePackage;
    NSMutableDictionary *body = [self bodyForAccount:account requireToken:YES];
    if (!body) { [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:nil error:AccountError(CydiaAccountErrorAuthentication)]; return; }
    if ([self hasUnresolvedPurchase:package account:account]) {
        [self finishPurchase:identity state:CydiaRepositoryPurchaseStatePending info:nil error:AccountError(CydiaAccountErrorPurchasePending)]; return;
    }
    body[@"payment_secret"] = secret ?: (id)NSNull.null;
    if (![self recordPurchase:package account:account value:@{@"version": version, @"architecture": architecture,
        @"price": price, @"submitted": [NSDate date], @"credential": CredentialBinding(account)}]) {
        [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:nil error:AccountError(CydiaAccountErrorKeychain)]; return;
    }
    NSString *path = [self packagePath:package action:@"purchase"];
    [self request:[account.providerURL URLByAppendingPathComponent:path] body:body completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (![self purchaseIsCurrent:identity]) return;
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *info = [object isKindOfClass:NSDictionary.class] ? object : nil;
        self.purchaseRecoveryURL = WithRecovery(AccountError(CydiaAccountErrorPurchaseUnknown), info[@"recovery_url"], account, body).userInfo[CydiaAccountRecoveryURLKey];
        id status = info[@"status"];
        BOOL valid = !error && response.statusCode >= 200 && response.statusCode < 300 &&
            [status isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)status) != CFBooleanGetTypeID() &&
            [status doubleValue] == [status integerValue] && [status integerValue] >= -1 && [status integerValue] <= 1 &&
            ([status integerValue] == -1 || SuccessfulJSON(info));
        if (!valid) {
            [self verifyPurchase:identity fallback:CydiaRepositoryPurchaseStateUnknown]; return;
        }
        if ([status integerValue] == -1) {
            [self recordPurchase:package account:account value:nil];
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:nil
                error:WithRecovery(AccountError(CydiaAccountErrorInvalidResponse), info[@"recovery_url"], account, body)]; return;
        }
        if ([status integerValue] == 0) { [self verifyPurchase:identity fallback:CydiaRepositoryPurchaseStatePending]; return; }
        NSURL *URL = URLValue(info[@"url"]);
        NSString *decoded = URL.absoluteString.stringByRemovingPercentEncoding;
        BOOL leak = [URL.absoluteString containsString:body[@"token"]] || [decoded containsString:body[@"token"]] ||
            (secret && ([URL.absoluteString containsString:secret] || [decoded containsString:secret]));
        if (!SecureURL(URL) || leak || !(account.capabilities & CydiaRepositoryCapabilityHostedCheckout)) {
            [self verifyPurchase:identity fallback:CydiaRepositoryPurchaseStateUnknown]; return;
        }
        [self checkout:URL identity:identity];
    }];
}
- (void)postConfirmedPurchase:(NSUUID *)identity secret:(NSString *)secret version:(NSString *)version architecture:(NSString *)architecture price:(NSString *)price {
    if (![self validatePurchaseSelection:identity]) return;
    /* Source discovery and background transaction proof may both take time.
     * Read the offer once more at the final boundary, not before those waits. */
    [self packageInfo:_purchasePackage account:_purchaseAccount completion:^(NSDictionary *info, NSError *error) {
        if (![self validatePurchaseSelection:identity]) return;
        if (!error && JSONBooleanIs(info[@"purchased"], YES) && !ExplicitlyFreePackage(info)) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateOwned info:info error:nil]; return;
        }
        if (error || !UnownedPaidOffer(info) || ![String(info[@"price"]) isEqual:price]) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:info
                error:error ?: OfferFailure(info)]; return;
        }
        [self sendConfirmedPurchase:identity secret:secret version:version architecture:architecture price:price];
    }];
}
- (void)submitConfirmedPurchase:(NSUUID *)identity secret:(NSString *)secret version:(NSString *)version architecture:(NSString *)architecture price:(NSString *)price {
    if (![self validatePurchaseSelection:identity]) return;
    CydiaRepositoryAccount *account = _purchaseAccount;
    /* A source may move to another provider while authentication is open.
     * Compare fresh public discovery without ever forwarding old credentials. */
    [self request:[account.sourceURL URLByAppendingPathComponent:@"payment_endpoint"] body:nil completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        if (![self validatePurchaseSelection:identity]) return;
        NSString *text = data.length <= 8192 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSURL *provider = URLValue([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        if (error || response.statusCode != 200 || !SecureURL(provider) || provider.query) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:nil
                error:error ?: AccountError(response.statusCode == 403 ? CydiaAccountErrorBotFilter : CydiaAccountErrorProviderChanged)]; return;
        }
        if (![provider isEqual:account.providerURL]) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:nil error:AccountError(CydiaAccountErrorProviderChanged)]; return;
        }
        if (!self.purchaseSelectionPreparation) {
            [self postConfirmedPurchase:identity secret:secret version:version architecture:architecture price:price]; return;
        }
        __block BOOL completed = NO;
        self.purchaseSelectionPreparation(^(BOOL valid) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completed || ![self validatePurchaseSelection:identity]) return;
                completed = YES;
                if (!valid) {
                    [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:nil error:AccountError(CydiaAccountErrorUnavailable)]; return;
                }
                [self postConfirmedPurchase:identity secret:secret version:version architecture:architecture price:price];
            });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (completed || ![self purchaseIsCurrent:identity]) return;
            completed = YES;
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:nil error:AccountError(CydiaAccountErrorUnavailable)];
        });
    }];
}
- (void)submitPurchase:(NSUUID *)identity secret:(NSString *)secret version:(NSString *)version architecture:(NSString *)architecture price:(NSString *)price {
    if (![self purchaseIsCurrent:identity]) return;
    if (!secret) { [self submitConfirmedPurchase:identity secret:nil version:version architecture:architecture price:price]; return; }
    /* Device-owner authentication may take time. Re-read the offer after that
     * wait and before posting any charge, still bound to the confirmed price. */
    [self packageInfo:_purchasePackage account:_purchaseAccount completion:^(NSDictionary *info, NSError *error) {
        if (![self purchaseIsCurrent:identity]) return;
        if (!error && JSONBooleanIs(info[@"purchased"], YES) && !ExplicitlyFreePackage(info)) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateOwned info:info error:nil]; return;
        }
        if (error || !UnownedPaidOffer(info) || ![String(info[@"price"]) isEqual:price]) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:info
                error:error ?: OfferFailure(info)]; return;
        }
        [self submitConfirmedPurchase:identity secret:secret version:version architecture:architecture price:price];
    }];
}
- (void)purchasePackage:(NSString *)package version:(NSString *)version architecture:(NSString *)architecture price:(NSString *)price
    account:(CydiaRepositoryAccount *)account presenter:(UIViewController *)presenter completion:(void (^)(CydiaRepositoryPurchaseResult *))completion {
    [self purchasePackage:package version:version architecture:architecture price:price account:account presenter:presenter
        selectionIsCurrent:nil completion:completion];
}
- (void)purchasePackage:(NSString *)package version:(NSString *)version architecture:(NSString *)architecture price:(NSString *)price
    account:(CydiaRepositoryAccount *)account presenter:(UIViewController *)presenter selectionIsCurrent:(BOOL (^)(void))selectionIsCurrent
    completion:(void (^)(CydiaRepositoryPurchaseResult *))completion {
    [self purchasePackage:package version:version architecture:architecture price:price account:account presenter:presenter
        selectionIsCurrent:selectionIsCurrent prepareSelection:nil completion:completion];
}
- (void)purchasePackage:(NSString *)package version:(NSString *)version architecture:(NSString *)architecture price:(NSString *)price
    account:(CydiaRepositoryAccount *)account presenter:(UIViewController *)presenter selectionIsCurrent:(BOOL (^)(void))selectionIsCurrent
    prepareSelection:(void (^)(void (^)(BOOL)))prepareSelection completion:(void (^)(CydiaRepositoryPurchaseResult *))completion {
    package = [package copy]; version = [version copy]; architecture = [architecture copy]; price = [price copy];
    if (!(account.capabilities & CydiaRepositoryCapabilityDirectPurchase)) {
        completion(PurchaseResult(CydiaRepositoryPurchaseStateRejected, nil, AccountError(CydiaAccountErrorClientPolicy))); return;
    }
    if (_sessionIdentity || !presenter.view.window || ![self packagePath:package action:@"purchase"] ||
        version.length == 0 || architecture.length == 0 || price.length == 0 || price.length > 256) {
        completion(PurchaseResult(CydiaRepositoryPurchaseStateRejected, nil, AccountError(CydiaAccountErrorUnavailable))); return;
    }
    NSUUID *identity = [NSUUID UUID];
    _sessionIdentity = identity; _presenter = presenter; _authenticationAccountKey = AccountKey(account);
    _purchaseAccount = account; _purchasePackage = package; _purchaseCompletion = completion;
    _purchaseGeneration = [self generationForAccount:account advance:NO];
    _purchaseSelectionValidator = [selectionIsCurrent copy];
    _purchaseSelectionPreparation = [prepareSelection copy];
    if (![self validatePurchaseSelection:identity]) return;
    [self packageInfo:package account:account completion:^(NSDictionary *info, NSError *error) {
        if (![self purchaseIsCurrent:identity]) return;
        if (!error && JSONBooleanIs(info[@"purchased"], YES) && !ExplicitlyFreePackage(info)) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateOwned info:info error:nil]; return;
        }
        if (error || !UnownedPaidOffer(info)) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:info error:error ?: OfferFailure(info)]; return;
        }
        if ([self hasUnresolvedPurchase:package account:account]) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStatePending info:info error:AccountError(CydiaAccountErrorPurchasePending)]; return;
        }
        if (![String(info[@"price"]) isEqual:price]) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:info error:AccountError(CydiaAccountErrorOfferChanged)]; return;
        }
        NSString *mode = account.purchaseCredentialMode;
        if ([mode isEqual:@"hosted"]) {
            [self submitPurchase:identity secret:nil version:version architecture:architecture price:price]; return;
        }
        if (![mode isEqual:@"protected"]) {
            [self finishPurchase:identity state:CydiaRepositoryPurchaseStateRejected info:info error:AccountError(CydiaAccountErrorReauthentication)]; return;
        }
        LAContext *context = [LAContext new]; self.purchaseAuthenticationContext = context;
        dispatch_async(CredentialQueue(), ^{
            NSMutableDictionary *query = [SecretQuery(account) mutableCopy];
            query[(__bridge id)kSecReturnData] = @YES; query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
            query[(__bridge id)kSecUseOperationPrompt] = CydiaAccountLocalize(@"ACCOUNT_AUTHORIZE_PURCHASE");
            query[(__bridge id)kSecUseAuthenticationContext] = context;
            CFTypeRef value = NULL;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &value);
            NSData *data = value ? CFBridgingRelease(value) : nil;
            NSString *secret = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self purchaseIsCurrent:identity]) return;
                if (status != errSecSuccess || secret.length == 0 || secret.length > 8192) {
                    CydiaAccountError code = status == errSecUserCanceled || status == errSecAuthFailed ? CydiaAccountErrorCancelled : CydiaAccountErrorReauthentication;
                    [self finishPurchase:identity state:code == CydiaAccountErrorCancelled ? CydiaRepositoryPurchaseStateCancelled : CydiaRepositoryPurchaseStateRejected info:info error:AccountError(code)]; return;
                }
                [self submitPurchase:identity secret:secret version:version architecture:architecture price:price];
            });
        });
    }];
}
@end
