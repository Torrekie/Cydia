/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/Appearance.h"
#include "Cydia/PackageDatabasePaths.hpp"

#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>

#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
static __weak UIWindow *CydiaManagedLegacyAppearanceWindow;
static UIUserInterfaceStyle CydiaManagedLegacyAppearanceStyle =
    UIUserInterfaceStyleUnspecified;
#endif

static UIUserInterfaceStyle CydiaLegacyInterfaceStyleMode(void) {
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        NSArray *libraries(NSSearchPathForDirectoriesInDomains(
            NSLibraryDirectory, NSUserDomainMask, YES));
        if ([libraries count] == 0)
            return UIUserInterfaceStyleUnspecified;

        NSString *path([[libraries objectAtIndex:0] stringByAppendingPathComponent:
            @"Preferences/com.apple.uikitservices.userInterfaceStyleMode.plist"]);
        NSDictionary *preferences([NSDictionary dictionaryWithContentsOfFile:path]);
        id rawMode([preferences objectForKey:@"UserInterfaceStyleMode"]);
        if (![rawMode isKindOfClass:[NSNumber class]])
            return UIUserInterfaceStyleUnspecified;
        CFTypeRef rawType((__bridge CFTypeRef) rawMode);
        if (CFGetTypeID(rawType) != CFNumberGetTypeID() ||
            CFNumberIsFloatType((CFNumberRef) rawType))
            return UIUserInterfaceStyleUnspecified;

        switch ([(NSNumber *) rawMode integerValue]) {
            case 1:
                return UIUserInterfaceStyleLight;
            case 2:
                return UIUserInterfaceStyleDark;
            default:
                return UIUserInterfaceStyleUnspecified;
        }
    }
#endif
    return UIUserInterfaceStyleUnspecified;
}

/* UIKit publishes the live system style through the screen before the
 * persisted UIKit-services plist necessarily catches up.  Keep this read
 * separate from the rootful compatibility fallback so a short cfprefsd lag
 * cannot make an old helper-owned override win another refresh cycle. */
static UIUserInterfaceStyle CydiaLiveSystemInterfaceStyle(void) {
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        UITraitCollection *traits([UIScreen mainScreen].traitCollection);
        UIUserInterfaceStyle style(traits.userInterfaceStyle);
        if (style == UIUserInterfaceStyleLight ||
            style == UIUserInterfaceStyleDark)
            return style;
    }
#endif
    return UIUserInterfaceStyleUnspecified;
}

static void CydiaClearManagedLegacyAppearance(void) {
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    CydiaManagedLegacyAppearanceWindow = nil;
    CydiaManagedLegacyAppearanceStyle = UIUserInterfaceStyleUnspecified;
#endif
}

void CydiaReleaseLegacyInterfaceStyleCompatibility(UIWindow *window) {
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (window == nil)
        return;
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle current(window.overrideUserInterfaceStyle);
        BOOL managed(window == CydiaManagedLegacyAppearanceWindow &&
            current == CydiaManagedLegacyAppearanceStyle &&
            current != UIUserInterfaceStyleUnspecified);
        if (managed) {
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
            CydiaClearManagedLegacyAppearance();
        }
    }
#else
    (void) window;
#endif
}

void CydiaRefreshLegacyInterfaceStyleCompatibility(UIWindow *window) {
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (window == nil)
        return;
    if (@available(iOS 13.0, *)) {
        BOOL managed(window == CydiaManagedLegacyAppearanceWindow &&
            window.overrideUserInterfaceStyle == CydiaManagedLegacyAppearanceStyle &&
            CydiaManagedLegacyAppearanceStyle != UIUserInterfaceStyleUnspecified);
        if (managed) {
            UIUserInterfaceStyle live(CydiaLiveSystemInterfaceStyle());
            if ((live == UIUserInterfaceStyleLight ||
                 live == UIUserInterfaceStyleDark) &&
                live != CydiaManagedLegacyAppearanceStyle) {
                /* The system has already published the opposite style.  Do
                 * not let a lagging plist re-pin the previous override. */
                CydiaReleaseLegacyInterfaceStyleCompatibility(window);
                return;
            }
            if (CydiaLegacyInterfaceStyleMode() == CydiaManagedLegacyAppearanceStyle)
                return;
        }
    }
    CydiaApplyLegacyInterfaceStyleCompatibility(window);
#else
    (void) window;
#endif
}

void CydiaApplyLegacyInterfaceStyleCompatibility(UIWindow *window) {
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (window == nil)
        return;
    if (@available(iOS 13.0, *)) {
        /* Rootless UIKit already propagates Settings changes correctly.  Its
         * on-disk preference can briefly lag the inherited trait, so this
         * legacy fallback must never arbitrate that layout. */
        if (CydiaRuntime::PackageDatabasePaths::Current().layout() !=
            CydiaRuntime::PackageDatabaseLayout::Rootful)
            return;

        UIUserInterfaceStyle current(window.overrideUserInterfaceStyle);
        BOOL sameWindow(window == CydiaManagedLegacyAppearanceWindow);
        BOOL managed(sameWindow &&
            current == CydiaManagedLegacyAppearanceStyle &&
            current != UIUserInterfaceStyleUnspecified);

        /* Never overwrite a caller or probe that changed an explicit style,
         * including a caller that released a style previously managed here. */
        if (sameWindow && !managed) {
            CydiaClearManagedLegacyAppearance();
            return;
        }
        if (!managed && current != UIUserInterfaceStyleUnspecified)
            return;

        /* Release a compatibility override before checking again so a
         * normally behaving UIKit window can resume native live propagation.
         * The next main-queue turn observes the unpinned inherited trait. */
        if (managed) {
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
            CydiaClearManagedLegacyAppearance();
            dispatch_async(dispatch_get_main_queue(), ^{
                CydiaApplyLegacyInterfaceStyleCompatibility(window);
            });
            return;
        }

        UIUserInterfaceStyle desired(CydiaLegacyInterfaceStyleMode());
        UIUserInterfaceStyle live(CydiaLiveSystemInterfaceStyle());
        if ((live == UIUserInterfaceStyleLight ||
             live == UIUserInterfaceStyleDark) && live != desired)
            return;
        UIUserInterfaceStyle inherited(window.traitCollection.userInterfaceStyle);
        if (desired == UIUserInterfaceStyleLight ||
            desired == UIUserInterfaceStyleDark) {
            if (inherited == desired)
                return;
            window.overrideUserInterfaceStyle = desired;
            CydiaManagedLegacyAppearanceWindow = window;
            CydiaManagedLegacyAppearanceStyle = desired;
        }
    }
#else
    (void) window;
#endif
}
