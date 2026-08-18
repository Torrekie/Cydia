/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/Application.h"
#include "Cydia/ApplicationInternal.h"
#include "Cydia/AppState.h"
#include "Cydia/Appearance.h"
#include "Cydia/Database.h"
#include "Cydia/DpkgRunner.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/StashController.h"
#include "Cydia/TabBarController.h"
#include "Sources.h"
#include "CyteKit/CyteKit.h"
#include "CyteKit/extern.h"
#include "Menes/Menes.h"
#include "iPhonePrivate.h"

#include <dlfcn.h>
#include <notify.h>
#include <sys/wait.h>
#include <objc/runtime.h>

@interface FBSSystemService
+ (id) sharedService;
- (void) sendActions:(NSSet *)actions withResult:(id)result;
@end

typedef enum {
    None = 0,
    RestartRenderServer = (1 << 0),
    SnapshotTransition = (1 << 1),
    FadeToBlackTransition = (1 << 2),
} SBSRelaunchActionStyle;

@interface SBSRelaunchAction
+ (id) actionWithReason:(id)reason options:(int64_t)options targetURL:(NSURL *)url;
@end

#define ForRelease 1
#define SavedState_ Cache("SavedState.plist")

#undef _trace
#define _trace(args...)

@implementation Cydia (Lifecycle)
- (void) lockSuspend {
    if (locked_++ == 0) {
        CydiaSetMenuButtonIntercepted(true);

        [self setIdleTimerDisabled:YES];
    }
}

- (void) unlockSuspend {
    if (--locked_ == 0) {
        [self setIdleTimerDisabled:NO];

        CydiaSetMenuButtonIntercepted(false);
    }
}

- (void) reloadSpringBoard {
    if (kCFCoreFoundationVersionNumber >= 1443) { // XXX: iOS 11.x
        Class $SBSRelaunchAction = objc_getClass("SBSRelaunchAction");
        Class $FBSSystemService = objc_getClass("FBSSystemService");
        pid_t sb_pid = launch_get_job_pid("com.apple.SpringBoard");
        if ($SBSRelaunchAction && $FBSSystemService) {
            id action = [$SBSRelaunchAction actionWithReason:@"respring" options:RestartRenderServer targetURL:nil];
            id sharedService = [$FBSSystemService sharedService];
            [sharedService sendActions:[NSSet setWithObject:action] withResult:nil];
            for (int i=0; i<100; i++) {
                if (kill(sb_pid, 0)) {
                    break;
                }
                usleep(1000);
            }
            if (kill(sb_pid, 0)) sleep(5);
        }
    }
    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    CydiaRuntime::Dpkg::Runner privileged(paths.CydoPath());
    if (kCFCoreFoundationVersionNumber >= 700) // XXX: iOS 6.x
        (void) privileged.Run({"/bin/launchctl", "stop", "com.apple.backboardd"});
    else
        (void) privileged.Run({"/bin/launchctl", "stop", "com.apple.SpringBoard"});
    sleep(15);
    (void) privileged.Run({"/usr/bin/killall", "backboardd", "SpringBoard"});
}

- (void) applicationWillSuspend {
    [database_ clean];
    [super applicationWillSuspend];
}

- (BOOL) isSafeToSuspend {
    if (locked_ != 0) {
#if !ForRelease
        NSLog(@"isSafeToSuspend: locked_ != 0");
#endif
        return false;
    }

    if ([tabbar_ modalViewController] != nil)
        return false;

    // Use external process status API internally.
    // This is probably a really bad idea.
    // XXX: what is the point of this? does this solve anything at all?
    uint64_t status = 0;
    int notify_token;
    if (notify_register_check("com.saurik.Cydia.status", &notify_token) == NOTIFY_STATUS_OK) {
        notify_get_state(notify_token, &status);
        notify_cancel(notify_token);
    }

    if (status != 0) {
#if !ForRelease
        NSLog(@"isSafeToSuspend: status != 0");
#endif
        return false;
    }

#if !ForRelease
    NSLog(@"isSafeToSuspend: -> true");
#endif
    return true;
}

- (void) suspendReturningToLastApp:(BOOL)returning {
    if ([self isSafeToSuspend])
        [super suspendReturningToLastApp:returning];
}

- (void) suspend {
    if ([self isSafeToSuspend])
        [super suspend];
}

- (void) applicationSuspend {
    if ([self isSafeToSuspend])
        [super applicationSuspend];
}

- (void) applicationSuspend:(GSEventRef)event {
    if ([self isSafeToSuspend])
        [super applicationSuspend:event];
}

- (void) _animateSuspension:(BOOL)arg0 duration:(double)arg1 startTime:(double)arg2 scale:(float)arg3 {
    if ([self isSafeToSuspend])
        [super _animateSuspension:arg0 duration:arg1 startTime:arg2 scale:arg3];
}

- (void) _setSuspended:(BOOL)value {
    if ([self isSafeToSuspend])
        [super _setSuspended:value];
}

- (UIProgressHUD *) addProgressHUD {
    UIProgressHUD *hud([[UIProgressHUD alloc] init]);
    [hud setAutoresizingMask:CydiaAutoresizingFlexibleBoth];

    [window_ setUserInteractionEnabled:NO];

    UIViewController *target(tabbar_);
    if (UIViewController *modal = [target modalViewController])
        target = modal;

    [hud showInView:[target view]];

    [self lockSuspend];
    return hud;
}

- (void) removeProgressHUD:(UIProgressHUD *)hud {
    [self unlockSuspend];
    [hud hide];
    [hud removeFromSuperview];
    [window_ setUserInteractionEnabled:YES];
}

- (void) applicationWillResignActive:(UIApplication *)application {
    // Stop refreshing if you get a phone call or lock the device.
    if ([tabbar_ updating])
        [tabbar_ cancelUpdate];

    if ([[self superclass] instancesRespondToSelector:@selector(applicationWillResignActive:)])
        [super applicationWillResignActive:application];
}

- (void) saveState {
    [[NSDictionary dictionaryWithObjectsAndKeys:
        @"InterfaceState", [tabbar_ navigationURLCollection],
        @"LastClosed", [NSDate date],
        @"InterfaceIndex", [NSNumber numberWithInt:[tabbar_ selectedIndex]],
    nil] writeToFile:SavedState_ atomically:YES];

    [self _saveConfig];
}

- (void) applicationWillTerminate:(UIApplication *)application {
    [self saveState];
}

- (void) applicationDidEnterBackground:(UIApplication *)application {
    if (kCFCoreFoundationVersionNumber < 1000 && [self isSafeToSuspend])
        return [self terminateWithSuccess];
    Backgrounded_ = [NSDate date];
    [self saveState];
}

- (void) applicationWillEnterForeground:(UIApplication *)application {
    if (Backgrounded_ == nil)
        return;

    NSTimeInterval interval([Backgrounded_ timeIntervalSinceNow]);

    if (interval <= -(30*60)) {
        [tabbar_ setSelectedIndex:0];
        [[[tabbar_ viewControllers] objectAtIndex:0] popToRootViewControllerAnimated:NO];
    }

    if (interval <= -(15*60)) {
        if (CyteIsReachable("cydia.saurik.com")) {
            [tabbar_ beginUpdate];
            [appcache_ reloadURLWithCache:YES];
        }
    }

    if ([database_ delocked])
        [self reloadData];
}

- (void) addStashController {
    [self lockSuspend];
    stash_ = [[StashController alloc] init];
    [window_ addSubview:[stash_ view]];
}

- (void) removeStashController {
    [[stash_ view] removeFromSuperview];
    stash_ = nil;
    [self unlockSuspend];
}

- (void) stash {
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque];
    UpdateExternalStatus(1);
    [self yieldToSelector:@selector(runStashHelper)];
    UpdateExternalStatus(0);

    [self removeStashController];
    [self reloadSpringBoard];
}

- (void) runStashHelper {
    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    CydiaRuntime::Dpkg::Runner privileged(paths.CydoPath());
    (void) privileged.Run({paths.CydiaHelperPath("free.sh")});
}

@end
