/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_Appearance_H
#define Cydia_Appearance_H

#include "CyteKit/UCPlatform.h"
#include "Cydia/UIColor+Cydia.h"
#include "Menes/ObjectHandle.h"

#include <UIKit/UIKit.h>

// Shared UIKit layout value used by controllers outside MobileCydia.mm.
static const NSUInteger CydiaAutoresizingFlexibleBoth = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

extern _H<UIFont> Font12_;
extern _H<UIFont> Font12Bold_;
extern _H<UIFont> Font14_;
extern _H<UIFont> Font18_;
extern _H<UIFont> Font18Bold_;
extern _H<UIFont> Font22Bold_;

/* iOS 13+ compatibility for legacy rootful launch environments that do not
 * propagate the Settings style into an Automatic root window.  Exact Light
 * and Dark modes are reconciled at startup and activation only when inherited
 * traits disagree; unknown modes and explicit caller/probe overrides remain
 * under UIKit or caller ownership. */
FOUNDATION_EXPORT void CydiaApplyLegacyInterfaceStyleCompatibility(UIWindow *window);

/* A helper-owned root override must not pin the inherited trait while UIKit
 * is handing the app to Settings, Control Center, or another foreground
 * surface.  Releasing only our own override lets the next activation read
 * the settled system preference without touching caller-owned styles. */
FOUNDATION_EXPORT void CydiaReleaseLegacyInterfaceStyleCompatibility(UIWindow *window);

/* Recheck the system preference only when a helper-owned override may have
 * become stale.  This is used by the short-lived foreground refresh lane on
 * rootful iOS 13+ where UIKit may not propagate the Control Center change to
 * an already-running legacy window. */
FOUNDATION_EXPORT void CydiaRefreshLegacyInterfaceStyleCompatibility(UIWindow *window);

#endif//Cydia_Appearance_H
