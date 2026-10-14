/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* A package's public website is not generally a checkout URL. Only a
 * documented vendor buy page bound to that vendor's source is recognized. */
NSURL * _Nullable CydiaRepositoryPurchaseWebsite(NSURL *sourceURL, NSURL * _Nullable packageWebsite);
NSURL * _Nullable CydiaRepositoryPublicWebsite(NSURL * _Nullable URL);
/* Display only: retain the source path that distinguishes repository scopes,
 * while hiding credentials, queries and fragments. Never a checkout URL. */
NSString * _Nullable CydiaRepositorySourceDisplayURL(NSURL * _Nullable URL);
/* Provider-owned package IDs only. No local package lookup can confer an
 * entitlement from another repository with the same package name. */
NSArray<NSString *> * _Nullable CydiaRepositoryPurchasedPackageIdentifiers(NSDictionary * _Nullable info);
typedef NS_ENUM(NSUInteger, CydiaRepositoryPackageState) {
    CydiaRepositoryPackageStateUnknown,
    CydiaRepositoryPackageStateUnavailable,
    CydiaRepositoryPackageStateSignIn,
    CydiaRepositoryPackageStateBuy,
    CydiaRepositoryPackageStateDownload,
    CydiaRepositoryPackageStateOwned,
    CydiaRepositoryPackageStateNotPurchased,
    CydiaRepositoryPackageStateOwnedUnavailable,
    CydiaRepositoryPackageStateFree,
};

/* Presentation only. No transport, credentials, archive grants or mutation
 * authority are retained. The caller supplies a purchaseURL only after its
 * provenance is established as a public vendor purchase website. The legacy
 * payment protocol has no such field, and recovery_url is not a buy link. */
@interface CydiaRepositoryPackagePresentation : NSObject
@property(nonatomic, readonly) CydiaRepositoryPackageState state;
@property(nonatomic, copy, readonly, nullable) NSURL *purchaseURL;
@property(nonatomic, copy, readonly, nullable) NSString *price;
@property(nonatomic, readonly) BOOL purchased;
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly, getter=isFree) BOOL free;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithInfo:(nullable NSDictionary *)info
                    signedIn:(BOOL)signedIn
                   supported:(BOOL)supported
           downloadAvailable:(BOOL)downloadAvailable
                 purchaseURL:(nullable NSURL *)purchaseURL;
- (instancetype)initWithInfo:(nullable NSDictionary *)info
                    signedIn:(BOOL)signedIn
                   supported:(BOOL)supported
           downloadAvailable:(BOOL)downloadAvailable
           downloadSupported:(BOOL)downloadSupported
           purchaseAvailable:(BOOL)purchaseAvailable
                 purchaseURL:(nullable NSURL *)purchaseURL;
@end
NS_ASSUME_NONNULL_END
