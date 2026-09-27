/* Cydia Refurbished native package-detail state boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageDetailViewModel_H
#define Cydia_PackageDetailViewModel_H

#import <Foundation/Foundation.h>

#include <stdint.h>

@class Package;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CydiaPackageDetailContactKind) {
    CydiaPackageDetailContactKindAuthor,
    CydiaPackageDetailContactKindMaintainer,
    CydiaPackageDetailContactKindPackageSupport,
};

typedef NS_ENUM(NSUInteger, CydiaPackageDetailModifyActionKind) {
    CydiaPackageDetailModifyActionKindClear,
    CydiaPackageDetailModifyActionKindUpgrade,
    CydiaPackageDetailModifyActionKindInstall,
    CydiaPackageDetailModifyActionKindReinstall,
    CydiaPackageDetailModifyActionKindRemove,
    CydiaPackageDetailModifyActionKindDowngrade,
};

@interface CydiaPackageDetailSource : NSObject

@property(nonatomic, copy, readonly, nullable) NSString *key;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly, nullable) NSString *sourceDescription;
@property(nonatomic, copy, readonly, nullable) NSString *host;
@property(nonatomic, copy, readonly, nullable) NSString *iconURLString;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface CydiaPackageDetailApplication : NSObject

@property(nonatomic, copy, readonly) NSString *bundleIdentifier;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly, nullable) NSString *iconURLString;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface CydiaPackageDetailVersionChoice : NSObject

@property(nonatomic, copy, readonly) NSString *identity;
@property(nonatomic, copy, readonly) NSString *version;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface CydiaPackageDetailModifyAction : NSObject

@property(nonatomic, readonly) CydiaPackageDetailModifyActionKind kind;
@property(nonatomic, copy, readonly) NSString *titleLocalizationKey;
@property(nonatomic, copy, readonly) NSArray<CydiaPackageDetailVersionChoice *> *versions;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end


/* This is a synchronous, owning snapshot of the existing Package model.  It
 * deliberately retains no Package, Database, Source, MIMEAddress, APT handle,
 * or web object, so UIKit can render and test package information offline. */
@interface CydiaPackageDetailViewModel : NSObject

@property(nonatomic, copy, readonly) NSString *identity;
@property(nonatomic, copy, readonly, nullable) NSString *baseIdentity;
@property(nonatomic, copy, readonly, nullable) NSString *aptIdentity;
@property(nonatomic, copy, readonly, nullable) NSString *dpkgIdentity;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly, nullable) NSString *latestVersion;
@property(nonatomic, copy, readonly, nullable) NSString *installedVersion;
@property(nonatomic, copy, readonly, nullable) NSString *architecture;
@property(nonatomic, copy, readonly, nullable) NSString *multiArch;
@property(nonatomic, copy, readonly, nullable) NSString *rawSection;
@property(nonatomic, copy, readonly, nullable) NSString *localizedSection;
@property(nonatomic, copy, readonly, nullable) NSString *shortDescription;
@property(nonatomic, copy, readonly, nullable) NSString *longDescription;
@property(nonatomic, copy, readonly, nullable) NSString *displayDescription;
@property(nonatomic, readonly) uint64_t installedSizeBytes;

@property(nonatomic, copy, readonly, nullable) NSString *modeLocalizationKey;
@property(nonatomic, copy, readonly) NSArray<NSString *> *warnings;
@property(nonatomic, readonly, getter=isInstalled) BOOL installed;
@property(nonatomic, readonly, getter=isUpgradable) BOOL upgradable;
@property(nonatomic, readonly, getter=isHeld) BOOL held;
@property(nonatomic, readonly, getter=isEssential) BOOL essential;
@property(nonatomic, readonly, getter=isCommercial) BOOL commercial;
@property(nonatomic, readonly, getter=isConsolePackage) BOOL consolePackage;

@property(nonatomic, readonly) CydiaPackageDetailContactKind contactKind;
@property(nonatomic, copy, readonly, nullable) NSString *contactName;
@property(nonatomic, copy, readonly, nullable) NSString *contactAddress;
@property(nonatomic, copy, readonly, nullable) NSString *supportURLString;
@property(nonatomic, copy, readonly, nullable) NSString *homepageURLString;
@property(nonatomic, copy, readonly, nullable) NSString *depictionURLString;

@property(nonatomic, strong, readonly, nullable) CydiaPackageDetailSource *source;
@property(nonatomic, copy, readonly) NSArray<CydiaPackageDetailApplication *> *applications;
@property(nonatomic, copy, readonly) NSArray<CydiaPackageDetailModifyAction *> *modifyActions;
/* Nil hides the existing navigation-bar action. One operation uses its own
 * localization key; two or more preserve the legacy MODIFY action sheet. */
@property(nonatomic, copy, readonly, nullable) NSString *primaryModifyTitleLocalizationKey;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithPackage:(Package *)package NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageDetailViewModel_H
