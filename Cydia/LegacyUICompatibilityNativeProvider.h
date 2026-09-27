/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_LegacyUICompatibilityNativeProvider_H
#define Cydia_LegacyUICompatibilityNativeProvider_H

#import <Foundation/Foundation.h>

#include "Cydia/LegacyUICompatibilityNativeCaller.h"

@class Cydia;
@class Database;
@class Package;
@class Source;

/*
 * The provider is the application-owned end of the Foundation compatibility
 * boundary.  It deliberately exposes only typed callbacks from
 * LegacyUICompatibilityNativeCaller: model reads are explicit, package
 * mutations use CydiaDelegate, source/configuration mutations use a native
 * confirmation boundary before their typed callbacks, and routes are handed
 * back to Cydia's typed router.  No browser object or dynamic Objective-C
 * dispatch is involved.
 */
@interface CydiaLegacyUICompatibilityNativeProvider : NSObject
    <CydiaLegacyUICompatibilityNativeReading,
     CydiaLegacyUICompatibilityNativeCommanding,
     CydiaLegacyUICompatibilityNativeRouting>

@property (nonatomic, readonly, weak) Cydia *application;
@property (nonatomic, readonly, weak) Database *database;
@property (nonatomic, readonly, weak) id presenter;
@property (nonatomic, readonly, getter=isActive) BOOL active;

- (instancetype) initWithApplication:(Cydia *)application
                              database:(Database *)database
                             presenter:(id)presenter NS_DESIGNATED_INITIALIZER;
- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

/* The caller retains the provider through its typed protocol properties.  A
 * weak back-reference keeps the application-owned graph cycle-free. */
- (void) attachCaller:(CydiaLegacyUICompatibilityNativeCaller *)caller;

/* Convenience factories for app-owned package/source sessions.  The caller
 * remains the authority and retains the returned sessions. */
- (CydiaLegacyUICompatibilityNativeSession *) sessionForPackage:(Package *)package
                                                       presenter:(id)presenter;
- (CydiaLegacyUICompatibilityNativeSession *) sessionForSource:(Source *)source
                                                       presenter:(id)presenter;
- (CydiaLegacyUICompatibilityNativeSession *) sessionForApplicationWithPresenter:(id)presenter;
/* CyteObject rendering session bound to the live Cydia application and
 * presenter.  This does not widen CydiaObject inheritance. */
- (CydiaLegacyUICompatibilityNativeSession *) sessionForRenderingWithPresenter:(id)presenter;

- (void) invalidate;

@end

#endif // Cydia_LegacyUICompatibilityNativeProvider_H
