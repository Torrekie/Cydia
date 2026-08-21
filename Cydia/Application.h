/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 */

#ifndef Cydia_Application_H
#define Cydia_Application_H

#include "CyteKit/UCPlatform.h"
#include "CyteKit/Application.h"
#include "Cydia/ConfirmationController.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/UIRouteContext.h"
#include "Menes/ObjectHandle.h"

@class AppCacheController;
@class CydiaProgressEvent;
@class CydiaTabBarController;
@class CyteTabBarController;
@class CyteViewController;
@class CyteWindow;
@class Package;
@class ProgressController;
@class StashController;
@class UIProgressHUD;

@interface Cydia : CyteApplication <ConfirmationControllerDelegate, DatabaseDelegate, CydiaDelegate> {
    _H<CyteWindow> window_;
    _H<CydiaTabBarController> tabbar_;
    _H<CyteTabBarController> emulated_;
    _H<AppCacheController> appcache_;

    _H<NSMutableArray> essential_;
    _H<NSMutableArray> broken_;

    __strong Database *database_;

    _H<NSURL> starturl_;
    unsigned locked_;
    _H<StashController> stash_;
    bool loaded_;
}

- (void) lockSuspend;
- (void) unlockSuspend;
- (void) _loaded;
- (void) reloadSpringBoard;
- (void) _saveConfig;
- (void) _updateData;
- (void) _refreshIfPossible;
- (void) refreshIfPossible;
- (void) updateDataAndLoad;
- (void) update_;
- (void) disemulate;
- (void) presentModalViewController:(UIViewController *)controller force:(BOOL)force;
- (ProgressController *) invokeNewProgress:(NSInvocation *)invocation forController:(UINavigationController *)navigation withTitle:(NSString *)title;
- (void) detachNewProgressSelector:(SEL)selector toTarget:(id)target forController:(UINavigationController *)navigation title:(NSString *)title;
- (void) reloadData;
- (void) cancelAndClear:(bool)clear;
- (CyteViewController *) pageForURL:(NSURL *)url context:(CydiaUIRouteContext *)context withReferrer:(NSString *)referrer;
- (BOOL) openCydiaURL:(NSURL *)url context:(CydiaUIRouteContext *)context;
/* Transitional adapters retained for the private WebView stack until P3. */
- (CyteViewController *) pageForURL:(NSURL *)url forExternal:(BOOL)external withReferrer:(NSString *)referrer;
- (BOOL) openCydiaURL:(NSURL *)url forExternal:(BOOL)external;
- (void) removeStashController;
- (void) addStashController;
- (void) loadData;

@end

#endif//Cydia_Application_H
