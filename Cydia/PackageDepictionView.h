/* Cydia Refurbished adaptive package depiction island.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageDepictionView_H
#define Cydia_PackageDepictionView_H

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CydiaPackageDepictionViewState) {
    CydiaPackageDepictionViewStateIdle,
    CydiaPackageDepictionViewStateLoading,
    CydiaPackageDepictionViewStateLoaded,
    CydiaPackageDepictionViewStateFailed,
    CydiaPackageDepictionViewStatePathologicalContent,
};

@class PackageDepictionView;

@protocol PackageDepictionViewDelegate <NSObject>

- (void)packageDepictionViewDidChangePresentation:(PackageDepictionView *)view;
- (void)packageDepictionView:(PackageDepictionView *)view
       didRequestURLHandoff:(NSURL *)URL;

@end


/* The sole public-WebKit production surface. It renders repository HTML only;
 * all Cydia-owned package chrome remains in PackageDetailController. */
@interface PackageDepictionView : UIView

@property(nonatomic, strong, readonly) NSURL *initialURL;
@property(nonatomic, readonly) CydiaPackageDepictionViewState state;
@property(nonatomic, readonly) CGFloat contentHeight;
@property(nonatomic, strong, readonly, nullable) NSError *loadError;
@property(nonatomic, readonly, getter=hasStartedLoading) BOOL startedLoading;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (nullable instancetype)initWithURLString:(NSString *)URLString
                                  delegate:(nullable id<PackageDepictionViewDelegate>)delegate
    NS_DESIGNATED_INITIALIZER;

- (void)startLoading;
- (void)retryLoading;

#if TARGET_OS_SIMULATOR
/* Fixed installed-evidence query for the two deterministic resource images.
 * This is absent from device builds and does not accept caller-supplied JS. */
- (void)cydiaProbeResourceImageStateWithCompletion:
    (void (^)(id _Nullable result, NSError * _Nullable error))completion;
#endif

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageDepictionView_H
