/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>

namespace CydiaAPT { struct RepositoryPackageAvailabilityData; }

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSUInteger, CydiaRepositoryLibraryItemState) {
    CydiaRepositoryLibraryItemStateUnknown,
    CydiaRepositoryLibraryItemStateAvailable,
    CydiaRepositoryLibraryItemStateUnsupportedArchitecture,
    CydiaRepositoryLibraryItemStateNoDownloadableVersion,
    CydiaRepositoryLibraryItemStateNotSelected,
};

/* A value-only snapshot of one provider-owned identifier. Availability must
 * describe the account's exact repository. Selected-package values are used
 * only when selectedFromSource is true; another source's copy cannot supply
 * a name, architecture, version, or route for this item. No Package, Database,
 * account, APT iterator, or acquisition authority is retained. */
@interface CydiaRepositoryLibraryItem : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly, nullable) NSString *routeIdentity;
@property(nonatomic, copy, readonly, nullable) NSString *version;
@property(nonatomic, copy, readonly, nullable) NSString *architectureCaption;
@property(nonatomic, copy, readonly) NSString *statusLocalizationKey;
@property(nonatomic, readonly) CydiaRepositoryLibraryItemState state;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithIdentifier:(NSString *)identifier
                     availability:(const CydiaAPT::RepositoryPackageAvailabilityData &)availability
                     selectedName:(nullable NSString *)selectedName
            selectedRouteIdentity:(nullable NSString *)selectedRouteIdentity
                  selectedVersion:(nullable NSString *)selectedVersion
             selectedArchitecture:(nullable NSString *)selectedArchitecture
               selectedFromSource:(BOOL)selectedFromSource
                 versionAvailable:(BOOL)versionAvailable
            architectureSupported:(BOOL)architectureSupported
          registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures;
@end
NS_ASSUME_NONNULL_END
