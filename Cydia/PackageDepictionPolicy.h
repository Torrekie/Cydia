/* Cydia Refurbished package depiction navigation boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageDepictionPolicy_H
#define Cydia_PackageDepictionPolicy_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CydiaPackageDepictionNavigationIntent) {
    CydiaPackageDepictionNavigationIntentAutomatic,
    CydiaPackageDepictionNavigationIntentUserActivated,
};

typedef NS_ENUM(NSUInteger, CydiaPackageDepictionNavigationDisposition) {
    CydiaPackageDepictionNavigationDispositionReject,
    CydiaPackageDepictionNavigationDispositionLoadInIsland,
    CydiaPackageDepictionNavigationDispositionHandOff,
};

/* Foundation-only policy for the sole repository-supplied HTML region. The
 * initial document stays on its validated origin. User-activated links leave
 * the island and re-enter the existing typed route/system-URL policy. */
@interface CydiaPackageDepictionPolicy : NSObject

@property(nonatomic, copy, readonly) NSURL *initialURL;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithURLString:(NSString *)URLString
    NS_DESIGNATED_INITIALIZER;

- (CydiaPackageDepictionNavigationDisposition)decisionForURL:(nullable NSURL *)URL
                                                   mainFrame:(BOOL)mainFrame
                                              initialRequest:(BOOL)initialRequest
                                                      intent:(CydiaPackageDepictionNavigationIntent)intent;

/* Response validation is separate so a server redirect cannot bypass the
 * action decision. Child frames remain ordinary unprivileged web content; the
 * app-owned main document may never change repository origin in place. */
- (BOOL)allowsResponseURL:(nullable NSURL *)URL mainFrame:(BOOL)mainFrame;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageDepictionPolicy_H
