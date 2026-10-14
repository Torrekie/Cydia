/* Cydia Refurbished native package-detail state boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageDetailViewModel_H
#define Cydia_PackageDetailViewModel_H

#import <Foundation/Foundation.h>

#include <stdint.h>

@class Package;
namespace CydiaAPT { struct RepositoryPackageAvailabilityData; }

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
    CydiaPackageDetailModifyActionKindPurge,
    CydiaPackageDetailModifyActionKindVersions,
    CydiaPackageDetailModifyActionKindAccount,
};

@interface CydiaPackageDetailSource : NSObject

@property(nonatomic, copy, readonly, nullable) NSString *key;
@property(nonatomic, copy, readonly, nullable) NSString *repositoryURLString;
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
/* Exact Debian version, including its epoch. */
@property(nonatomic, copy, readonly) NSString *fullVersion;
@property(nonatomic, copy, readonly, nullable) NSString *architecture;
@property(nonatomic, copy, readonly, nullable) NSString *architectureCaption;
@property(nonatomic, readonly) NSInteger priority;
@property(nonatomic, readonly) BOOL candidate;
@property(nonatomic, readonly) BOOL installed;

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
@property(nonatomic, copy, readonly, nullable) NSString *fullVersion;
@property(nonatomic, copy, readonly, nullable) NSString *installedVersion;
@property(nonatomic, copy, readonly, nullable) NSString *architecture;
@property(nonatomic, copy, readonly, nullable) NSString *architectureCaption;
@property(nonatomic, copy, readonly, nullable) NSString *multiArch;
@property(nonatomic, copy, readonly, nullable) NSString *rawSection;
@property(nonatomic, copy, readonly, nullable) NSString *localizedSection;
@property(nonatomic, copy, readonly, nullable) NSString *shortDescription;
@property(nonatomic, copy, readonly, nullable) NSString *longDescription;
@property(nonatomic, copy, readonly, nullable) NSString *displayDescription;
@property(nonatomic, readonly) uint64_t installedSizeBytes;
/* A repository-only record can be inspected without a selectable Package.
 * It never supplies modification, installed-state, or account authority. */
@property(nonatomic, readonly) BOOL readOnly;

@property(nonatomic, copy, readonly, nullable) NSString *modeLocalizationKey;
@property(nonatomic, copy, readonly) NSArray<NSString *> *warnings;
@property(nonatomic, readonly, getter=isInstalled) BOOL installed;
@property(nonatomic, readonly, getter=isUpgradable) BOOL upgradable;
@property(nonatomic, readonly, getter=isHeld) BOOL held;
@property(nonatomic, readonly, getter=isEssential) BOOL essential;
@property(nonatomic, readonly, getter=isProtectedPackage) BOOL protectedPackage;
@property(nonatomic, readonly, getter=isCommercial) BOOL commercial;
@property(nonatomic, readonly, getter=isConsolePackage) BOOL consolePackage;

@property(nonatomic, readonly) CydiaPackageDetailContactKind contactKind;
@property(nonatomic, copy, readonly, nullable) NSString *contactName;
@property(nonatomic, copy, readonly, nullable) NSString *contactAddress;
/* The legacy Support page renders author and maintainer independently.  Keep
 * these snapshots separate even though the package-detail action row retains
 * its historical author-first fallback semantics above. */
@property(nonatomic, copy, readonly, nullable) NSString *authorName;
@property(nonatomic, copy, readonly, nullable) NSString *authorAddress;
@property(nonatomic, copy, readonly, nullable) NSString *maintainerName;
@property(nonatomic, copy, readonly, nullable) NSString *maintainerAddress;
@property(nonatomic, copy, readonly, nullable) NSString *supportURLString;
@property(nonatomic, copy, readonly, nullable) NSString *homepageURLString;
@property(nonatomic, copy, readonly, nullable) NSString *depictionURLString;

/* Immutable, property-list-shaped data used to seed the bounded repository
 * depiction facade.  It contains only the current package/source snapshot;
 * no Package, Database, APT handle, presenter, or filesystem authority is
 * retained. */
@property(nonatomic, copy, readonly) NSDictionary *legacyDepictionSnapshot;

@property(nonatomic, strong, readonly, nullable) CydiaPackageDetailSource *source;
@property(nonatomic, copy, readonly) NSArray<CydiaPackageDetailApplication *> *applications;
@property(nonatomic, copy, readonly) NSArray<CydiaPackageDetailModifyAction *> *modifyActions;
/* Nil hides the existing navigation-bar action. One operation uses its own
 * localization key; two or more preserve the legacy MODIFY action sheet. */
@property(nonatomic, copy, readonly, nullable) NSString *primaryModifyTitleLocalizationKey;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithPackage:(Package *)package;
- (nullable instancetype)initWithPackage:(Package *)package
               registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures;
- (nullable instancetype)initWithPackage:(Package *)package
               registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures
                    versionArchitecture:(nullable NSString *)versionArchitecture;
- (nullable instancetype)initWithPackage:(Package *)package
               registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures
                    versionArchitecture:(nullable NSString *)versionArchitecture
                   repositoryConstraint:(nullable NSURL *)repositoryConstraint NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithRepositoryPackage:(const CydiaAPT::RepositoryPackageAvailabilityData &)availability
                                      identifier:(NSString *)identifier
                                       sourceURL:(NSURL *)sourceURL
                                      sourceName:(NSString *)sourceName
                        registeredArchitectures:(NSArray<NSString *> *)architectures NS_DESIGNATED_INITIALIZER;

@end

/* A delayed account action must still describe the same selection and be
 * offered by a fresh package snapshot. Acquisition also binds its source. */
BOOL CydiaPackageDetailCanPerformAction(CydiaPackageDetailViewModel * _Nullable selected,
    CydiaPackageDetailViewModel * _Nullable current, CydiaPackageDetailModifyActionKind kind);

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageDetailViewModel_H
