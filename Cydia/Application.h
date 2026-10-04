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

@class CydiaProgressEvent;
@class CydiaTabBarController;
@class CyteTabBarController;
@class CyteViewController;
@class CyteWindow;
@class Package;
@class Source;
@class ProgressController;
@class StashController;
@class UIProgressHUD;
@class CydiaLegacyUICompatibilityNativeCaller;
@class CydiaLegacyUICompatibilityNativeProvider;
@class CydiaLegacyUICompatibilityNativeSession;

@interface Cydia : CyteApplication <ConfirmationControllerDelegate, DatabaseDelegate, CydiaDelegate> {
    _H<CyteWindow> window_;
    _H<CydiaTabBarController> tabbar_;
    _H<CyteTabBarController> emulated_;
    _H<NSMutableArray> essential_;
    _H<NSMutableArray> broken_;

    __strong Database *database_;
    __strong CydiaLegacyUICompatibilityNativeCaller *legacyCompatibilityCaller_;
    __strong CydiaLegacyUICompatibilityNativeProvider *legacyCompatibilityProvider_;
    __strong CydiaLegacyUICompatibilityNativeSession *legacyCompatibilityApplicationSession_;
    __strong NSTimer *legacyInterfaceStyleTimer_;
    NSUInteger legacyCompatibilityApplicationDiagnosticAttempts_;
    BOOL legacyCompatibilityRuntimeEvidenceConsumed_;
    BOOL legacyCompatibilityExecutionEvidenceConsumed_;
    BOOL legacyCompatibilityMatrixEvidenceConsumed_;
    NSUInteger legacyCompatibilityExecutionEvidenceAttempts_;
    BOOL legacyCompatibilityMutationDiagnosticConsumed_;

    _H<NSURL> starturl_;
    unsigned locked_;
    _H<StashController> stash_;
    bool loaded_;
}

- (void) lockSuspend;
- (void) unlockSuspend;
- (void) _loaded;
- (void) reloadSpringBoard;
/* Retained for trusted in-process extensions built against legacy Cydia. */
- (void) system:(NSString *)command;
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
- (CyteViewController *) pageForURL:(NSURL *)url
                            context:(NSObject<CyteWebNavigationContext> *)context
                       withReferrer:(NSString *)referrer;
- (BOOL) openCydiaURL:(NSURL *)url context:(CydiaUIRouteContext *)context;
/* Source-compatible route adapters retained for existing native callers. */
- (CyteViewController *) pageForURL:(NSURL *)url forExternal:(BOOL)external withReferrer:(NSString *)referrer;
- (BOOL) openCydiaURL:(NSURL *)url forExternal:(BOOL)external;
- (void) removeStashController;
- (void) addStashController;
- (void) loadData;
- (void) cydiaLegacyInterfaceStyleTimerTick:(NSTimer *)timer;

/* App-owned, capability-bound compatibility entry points.  These factories
 * are intentionally the only production way to obtain a native legacy
 * session; the generic service initializer remains policy-only. */
- (CydiaLegacyUICompatibilityNativeCaller *) legacyUICompatibilityCaller;
- (CydiaLegacyUICompatibilityNativeProvider *) legacyUICompatibilityProvider;
- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForPackage:(Package *)package
                                                                              presenter:(id)presenter;
- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForSource:(Source *)source
                                                                            presenter:(id)presenter;
- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForApplicationWithPresenter:(id)presenter;
/* Opt-in mutation diagnostics run after the native tab bar is attached.  The
 * query is deliberately mode-allowlisted in Application+Data so normal
 * launches retain their ordinary source refresh ordering. */
- (BOOL) legacyUICompatibilityMutationDiagnosticRequested;
- (void) consumeLegacyUICompatibilityMutationDiagnosticIfRequested;
- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForRenderingWithPresenter:(id)presenter;
- (void) consumeLegacyUICompatibilityApplicationSessionIfRequested;
- (void) consumeLegacyUICompatibilityRuntimeEvidenceIfRequested;
- (void) consumeLegacyUICompatibilityMatrixEvidenceIfRequested;
- (void) consumeLegacyUICompatibilityExecutionEvidenceIfRequested;
- (void) consumeLegacyUICompatibilityMutationDiagnosticIfRequested;
- (void) invalidateLegacyUICompatibility;

@end

#endif//Cydia_Application_H
