/* Cydia Refurbished native package-detail shell.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageDetailController_H
#define Cydia_PackageDetailController_H

#include "CyteKit/ViewController.h"

#import "Cydia/PackageDetailViewModel.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CydiaPackageDetailNavigationKind) {
    CydiaPackageDetailNavigationKindSettings,
    CydiaPackageDetailNavigationKindContact,
    CydiaPackageDetailNavigationKindConsole,
    CydiaPackageDetailNavigationKindApplication,
    CydiaPackageDetailNavigationKindHomepage,
    CydiaPackageDetailNavigationKindFiles,
    CydiaPackageDetailNavigationKindDepictionLink,
};

@class PackageDetailController;

@protocol PackageDetailControllerDelegate <NSObject>

- (void)packageDetailController:(PackageDetailController *)controller
         didSelectModifyAction:(CydiaPackageDetailModifyAction *)action
                  versionChoice:(nullable CydiaPackageDetailVersionChoice *)versionChoice;
- (void)packageDetailController:(PackageDetailController *)controller
        didSelectNavigationKind:(CydiaPackageDetailNavigationKind)kind
                      URLString:(nullable NSString *)URLString
                     identifier:(nullable NSString *)identifier;

@end


/* Native package chrome shared by the retained CYPackageController API and the
 * deterministic simulator probe. */
@interface PackageDetailController : CyteViewController

@property(nonatomic, strong, readonly) CydiaPackageDetailViewModel *viewModel;
@property(nonatomic, strong, readonly) UIImage *headerIcon;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithViewModel:(CydiaPackageDetailViewModel *)viewModel
                       headerIcon:(nullable UIImage *)headerIcon
                         delegate:(nullable id<PackageDetailControllerDelegate>)delegate;
/* Subclass reload seam: replaces the owning snapshot without reaching back
 * into Package from the renderer. */
- (void)updateWithViewModel:(CydiaPackageDetailViewModel *)viewModel
                 headerIcon:(nullable UIImage *)headerIcon;
/* Replaces only the visible topper artwork.  Remote optional metadata must
 * not rebuild package sections, depiction state, or scroll position. */
- (void)updateHeaderIcon:(nullable UIImage *)headerIcon;
- (void)modifyButtonClicked;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageDetailController_H
