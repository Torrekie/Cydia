/* Cydia Refurbished external URL coordinator.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_ExternalURLController_H
#define Cydia_ExternalURLController_H

#include "Cydia/UIRouteContext.h"
#include "CyteKit/ViewController.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CydiaExternalURLControllerState) {
    CydiaExternalURLControllerStateReady,
    CydiaExternalURLControllerStateOpening,
    CydiaExternalURLControllerStatePresented,
    CydiaExternalURLControllerStateComplete,
    CydiaExternalURLControllerStateFailed,
};

/* Native coordinator for the external URL boundary. HTTP(S) content is owned
 * by SFSafariViewController; mail and App Store URLs are handed to the system.
 * This controller itself never renders web content. */
@interface ExternalURLController : CyteViewController

@property(nonatomic, readonly) CydiaExternalURLControllerState state;
@property(nonatomic, copy, readonly) NSURL *destinationURL;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithRouteDescriptor:(CydiaUIRouteDescriptor *)descriptor;

- (void)retryButtonClicked;
- (void)close;

@end


NS_ASSUME_NONNULL_END

#endif // Cydia_ExternalURLController_H
