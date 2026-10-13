/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* A package's public website is not generally a checkout URL. Only a
 * documented vendor buy page bound to that vendor's source is recognized. */
NSURL * _Nullable CydiaRepositoryPurchaseWebsite(NSURL *sourceURL, NSURL * _Nullable packageWebsite);
NSURL * _Nullable CydiaRepositoryPublicWebsite(NSURL * _Nullable URL);
typedef NS_ENUM(NSUInteger, CydiaRepositoryPackageState) {
    CydiaRepositoryPackageStateUnknown,
    CydiaRepositoryPackageStateUnavailable,
    CydiaRepositoryPackageStateSignIn,
    CydiaRepositoryPackageStateBuy,
    CydiaRepositoryPackageStateDownload,
    CydiaRepositoryPackageStateOwned,
    CydiaRepositoryPackageStateNotPurchased,
};

/* Presentation only. No transport, credentials, archive grants or mutation
 * authority are retained. The caller supplies a purchaseURL only after its
 * provenance is established as a public vendor purchase website. The legacy
 * payment protocol has no such field, and recovery_url is not a buy link. */
@interface CydiaRepositoryPackagePresentation : NSObject
@property(nonatomic, readonly) CydiaRepositoryPackageState state;
@property(nonatomic, copy, readonly, nullable) NSURL *purchaseURL;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithInfo:(nullable NSDictionary *)info
                    signedIn:(BOOL)signedIn
                   supported:(BOOL)supported
           downloadAvailable:(BOOL)downloadAvailable
                 purchaseURL:(nullable NSURL *)purchaseURL;
@end
NS_ASSUME_NONNULL_END
