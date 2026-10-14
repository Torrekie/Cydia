/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
NSString *CydiaAccountLocalize(NSString *key);
NSString *CydiaAccountOrigin(NSURL *URL);
extern NSString *const CydiaAccountRecoveryURLKey;
typedef NS_ENUM(NSInteger, CydiaAccountError) {
    CydiaAccountErrorUnsupported = 1, CydiaAccountErrorTransport,
    CydiaAccountErrorInvalidResponse, CydiaAccountErrorAuthentication,
    CydiaAccountErrorUnavailable, CydiaAccountErrorKeychain,
    CydiaAccountErrorClientPolicy, CydiaAccountErrorBotFilter,
    CydiaAccountErrorCancelled, CydiaAccountErrorReauthentication,
    CydiaAccountErrorOfferChanged, CydiaAccountErrorPurchasePending,
    CydiaAccountErrorPurchaseUnknown,
    CydiaAccountErrorProviderChanged,
};
typedef NS_OPTIONS(NSUInteger, CydiaRepositoryCapabilities) {
    CydiaRepositoryCapabilityLogin = 1 << 0,
    CydiaRepositoryCapabilityEntitlements = 1 << 1,
    CydiaRepositoryCapabilityDirectPurchase = 1 << 2,
    CydiaRepositoryCapabilityHostedCheckout = 1 << 3,
    CydiaRepositoryCapabilityDownload = 1 << 4,
};
typedef NS_ENUM(NSUInteger, CydiaRepositoryPurchaseState) {
    CydiaRepositoryPurchaseStateOwned,
    CydiaRepositoryPurchaseStateCancelled,
    CydiaRepositoryPurchaseStateRejected,
    CydiaRepositoryPurchaseStatePending,
    CydiaRepositoryPurchaseStateUnknown,
};
typedef NS_ENUM(NSUInteger, CydiaRepositoryAccessState) {
    CydiaRepositoryAccessStateReady, CydiaRepositoryAccessStateNotRequired,
    CydiaRepositoryAccessStateSignIn, CydiaRepositoryAccessStatePurchaseRequired,
    CydiaRepositoryAccessStateUnsupported, CydiaRepositoryAccessStateUnavailable,
    CydiaRepositoryAccessStateFailed,
};

/* Owning source/provider snapshot. Discovery does not send account or device data. */
@interface CydiaRepositoryAccount : NSObject
@property(nonatomic, copy, readonly) NSURL *sourceURL;
@property(nonatomic, copy, readonly) NSURL *providerURL;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) BOOL signedIn;
@property(nonatomic, readonly) BOOL supportsAccountIntegration;
/* Protocol operations are distinct from proven vendor acceptance. */
@property(nonatomic, readonly) CydiaRepositoryCapabilities capabilities;
@end

@interface CydiaRepositoryPurchaseResult : NSObject
@property(nonatomic, readonly) CydiaRepositoryPurchaseState state;
@property(nonatomic, copy, readonly, nullable) NSDictionary *packageInfo;
@property(nonatomic, strong, readonly, nullable) NSError *error;
- (instancetype)init NS_UNAVAILABLE;
@end
/* Read-only license preparation, never a download grant or an APT approval. */
@interface CydiaRepositoryAccessResult : NSObject
@property(nonatomic, readonly) CydiaRepositoryAccessState state;
@property(nonatomic, strong, readonly, nullable) CydiaRepositoryAccount *account;
@property(nonatomic, copy, readonly, nullable) NSDictionary *packageInfo;
@property(nonatomic, strong, readonly, nullable) NSError *error;
@property(nonatomic, copy, readonly) NSURL *sourceURL;
@property(nonatomic, copy, readonly) NSString *package, *version, *architecture;
- (instancetype)init NS_UNAVAILABLE;
@end

/* A one-operation capability, never persisted, logged, or used as display text.
 * The consumer must match every identity field and verify repository hashes and
 * layout before dpkg; obtaining a URL does not authorize a different package. */
@interface CydiaRepositoryDownloadGrant : NSObject
@property(nonatomic, copy, readonly) NSURL *transportURL;
@property(nonatomic, copy, readonly) NSURL *sourceURL;
@property(nonatomic, copy, readonly) NSString *package;
@property(nonatomic, copy, readonly) NSString *version;
@property(nonatomic, copy, readonly) NSString *architecture;
@property(nonatomic, copy, readonly) NSDate *obtainedAt;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface CydiaRepositoryAccountService : NSObject
+ (instancetype)sharedService;
/* Public source/provider metadata only; credentials are never in preferences. */
- (NSArray<NSDictionary *> *)rememberedAccounts;
- (void)removeRememberedAccount:(NSDictionary *)metadata completion:(void (^)(NSError * _Nullable))completion;
- (BOOL)hasUnresolvedPurchase:(NSString *)package account:(CydiaRepositoryAccount *)account;
- (void)discoverSource:(NSURL *)source name:(NSString *)name
           completion:(void (^)(CydiaRepositoryAccount * _Nullable, NSError * _Nullable))completion;
- (void)preflightPackage:(NSString *)package version:(NSString *)version architecture:(NSString *)architecture
                  source:(NSURL *)source name:(NSString *)name
              completion:(void (^)(CydiaRepositoryAccessResult *))completion;
/* Invoke only after the account UI explains the provider and obtains device-
 * linking consent. The auth session exclusively owns its callback. */
- (void)signIn:(CydiaRepositoryAccount *)account presenter:(UIViewController *)presenter
   completion:(void (^)(NSError * _Nullable))completion;
- (void)signOut:(CydiaRepositoryAccount *)account completion:(void (^)(NSError * _Nullable))completion;
- (void)userInfo:(CydiaRepositoryAccount *)account
     completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
- (void)anonymousPackageInfo:(NSString *)package account:(CydiaRepositoryAccount *)account
        completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
- (void)packageInfo:(NSString *)package account:(CydiaRepositoryAccount *)account
        completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
/* Call only after explicit provider/product/price confirmation. Fresh provider
 * information must match price before submission. Neither cancellation nor a
 * browser callback proves ownership; uncertain submissions are not retried. */
- (void)purchasePackage:(NSString *)package version:(NSString *)version
           architecture:(NSString *)architecture price:(NSString *)price
                account:(CydiaRepositoryAccount *)account presenter:(UIViewController *)presenter
             completion:(void (^)(CydiaRepositoryPurchaseResult *))completion;
- (void)cancelPurchaseForAccount:(CydiaRepositoryAccount *)account;
- (void)purchasePackage:(NSString *)package version:(NSString *)version
           architecture:(NSString *)architecture price:(NSString *)price
                account:(CydiaRepositoryAccount *)account presenter:(UIViewController *)presenter
     selectionIsCurrent:(nullable BOOL (^)(void))selectionIsCurrent
             completion:(void (^)(CydiaRepositoryPurchaseResult *))completion;
- (void)purchasePackage:(NSString *)package version:(NSString *)version
           architecture:(NSString *)architecture price:(NSString *)price
                account:(CydiaRepositoryAccount *)account presenter:(UIViewController *)presenter
     selectionIsCurrent:(nullable BOOL (^)(void))selectionIsCurrent
       prepareSelection:(nullable void (^)(void (^)(BOOL)))prepareSelection
             completion:(void (^)(CydiaRepositoryPurchaseResult *))completion;
- (void)authorizePackage:(NSString *)package version:(NSString *)version
           architecture:(NSString *)architecture account:(CydiaRepositoryAccount *)account
             completion:(void (^)(CydiaRepositoryDownloadGrant * _Nullable, NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
