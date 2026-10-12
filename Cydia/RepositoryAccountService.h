/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
NSString *CydiaAccountLocalize(NSString *key);
NSString *CydiaAccountOrigin(NSURL *URL);
typedef NS_ENUM(NSInteger, CydiaAccountError) {
    CydiaAccountErrorUnsupported = 1, CydiaAccountErrorTransport,
    CydiaAccountErrorInvalidResponse, CydiaAccountErrorAuthentication,
    CydiaAccountErrorUnavailable, CydiaAccountErrorKeychain,
};

/* Owning source/provider snapshot. Discovery does not send account or device data. */
@interface CydiaRepositoryAccount : NSObject
@property(nonatomic, copy, readonly) NSURL *sourceURL;
@property(nonatomic, copy, readonly) NSURL *providerURL;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) BOOL signedIn;
@property(nonatomic, readonly) BOOL supportsAccountIntegration;
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
- (void)discoverSource:(NSURL *)source name:(NSString *)name
           completion:(void (^)(CydiaRepositoryAccount * _Nullable, NSError * _Nullable))completion;
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
- (void)authorizePackage:(NSString *)package version:(NSString *)version
           architecture:(NSString *)architecture account:(CydiaRepositoryAccount *)account
             completion:(void (^)(CydiaRepositoryDownloadGrant * _Nullable, NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
