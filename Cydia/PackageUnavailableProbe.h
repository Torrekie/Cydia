/* Native unavailable-package simulator fixture.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageUnavailableProbe_H
#define Cydia_PackageUnavailableProbe_H

#include <TargetConditionals.h>
#if TARGET_OS_SIMULATOR
#import <UIKit/UIKit.h>

@class PackageUnavailableController;

/* Owns the fake database for the production controller's weak reference.
 * Uses only in-memory package snapshots; never changes runtime architecture. */
@interface CydiaPackageUnavailableProbe : NSObject
@property(nonatomic, strong, readonly) PackageUnavailableController *controller;
@property(nonatomic, copy, readonly) NSDictionary *results;
@end

#endif
#endif
