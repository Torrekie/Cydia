/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/Application.h"
#include "Cydia/ApplicationInternal.h"
#include "Cydia/AppState.h"
#include "Cydia/Appearance.h"
#include "Cydia/ControllerState.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/PackageFeatureControllers.h"
#include "Cydia/ProgressController.h"
#include "Cydia/Source.h"
#include "Cydia/TabBarController.h"
#include "CyteKit/CyteKit.h"
#include "CyteKit/Localize.h"
#include "CyteKit/extern.h"
#include "Menes/Menes.h"
#include "Sources.h"
#include "Substrate.hpp"
#include "iPhonePrivate.h"

#define ForRelease 1
#define ManualRefresh 0
#define CacheState_ Cache("CacheState.plist")

#undef _trace
#define _trace(args...)
#undef _profile
#define _profile(name) {
#undef _end
#define _end }
#define PrintTimes() do {} while (false)

@implementation Cydia (Data)
- (void) beginUpdate {
    [tabbar_ beginUpdate];
}

- (void) cancelUpdate {
    [tabbar_ cancelUpdate];
}

- (bool) requestUpdate {
    if (CyteIsReachable("cydia.saurik.com")) {
        [self beginUpdate];
        return true;
    } else {
        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:[NSString stringWithFormat:Colon_, Error_, UCLocalize("REFRESH")]
            message:@"Host Unreachable" // XXX: Localize
            delegate:self
            cancelButtonTitle:UCLocalize("OK")
            otherButtonTitles:nil
        ];

        [alert setContext:@"norefresh"];
        [alert show];

        return false;
    }
}

- (BOOL) updating {
    return [tabbar_ updating];
}

- (void) _loaded {
    if ([broken_ count] != 0) {
        int count = [broken_ count];

        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:(count == 1 ? UCLocalize("HALFINSTALLED_PACKAGE") : [NSString stringWithFormat:UCLocalize("HALFINSTALLED_PACKAGES"), count])
            message:UCLocalize("HALFINSTALLED_PACKAGE_EX")
            delegate:self
            cancelButtonTitle:[NSString stringWithFormat:UCLocalize("PARENTHETICAL"), UCLocalize("FORCIBLY_CLEAR"), UCLocalize("UNSAFE")]
            otherButtonTitles:
                UCLocalize("TEMPORARY_IGNORE"),
            nil
        ];

        [alert setContext:@"fixhalf"];
        [alert setNumberOfRows:2];
        [alert show];
    } else if (!Ignored_ && [essential_ count] != 0) {
        int count = [essential_ count];

        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:(count == 1 ? UCLocalize("ESSENTIAL_UPGRADE") : [NSString stringWithFormat:UCLocalize("ESSENTIAL_UPGRADES"), count])
            message:UCLocalize("ESSENTIAL_UPGRADE_EX")
            delegate:self
            cancelButtonTitle:UCLocalize("TEMPORARY_IGNORE")
            otherButtonTitles:
                UCLocalize("UPGRADE_ESSENTIAL"),
                UCLocalize("COMPLETE_UPGRADE"),
            nil
        ];

        [alert setContext:@"upgrade"];
        [alert show];
    }
}

- (void) returnToCydia {
    [self _loaded];
}

- (void) _saveConfig {
    SaveConfig(database_);
}

// Navigation controller for the queuing badge.
- (UINavigationController *) queueNavigationController {
    NSArray *controllers = [tabbar_ viewControllers];
    return [controllers objectAtIndex:3];
}

- (void) _updateData {
    [self _saveConfig];
    [window_ unloadData];

    UINavigationController *navigation = [self queueNavigationController];

    id queuedelegate = nil;
    if ([[navigation viewControllers] count] > 0)
        queuedelegate = [[navigation viewControllers] objectAtIndex:0];

    [(InstalledController *) queuedelegate queueStatusDidChange];
    [[navigation tabBarItem] setBadgeValue:(Queuing_ ? UCLocalize("Q_D") : nil)];
}

- (void) _refreshIfPossible {
    @autoreleasepool {

    NSDate *update([[NSDictionary dictionaryWithContentsOfFile:CacheState_] objectForKey:@"LastUpdate"]);

    bool recently = false;
    if (update != nil) {
        NSTimeInterval interval([update timeIntervalSinceNow]);
        if (interval > -(15*60))
            recently = true;
    }

    // Don't automatic refresh if:
    //  - We already refreshed recently.
    //  - We already auto-refreshed this launch.
    //  - Auto-refresh is disabled.
    //  - Cydia's server is not reachable
    if (recently || loaded_ || ManualRefresh || !CyteIsReachable("cydia.saurik.com")) {
        // If we are cancelling, we need to make sure it knows it's already loaded.
        loaded_ = true;

        [self performSelectorOnMainThread:@selector(_loaded) withObject:nil waitUntilDone:NO];
    } else {
        // We are going to load, so remember that.
        loaded_ = true;

        [tabbar_ performSelectorOnMainThread:@selector(beginUpdate) withObject:nil waitUntilDone:NO];
    }
    }
}

- (void) refreshIfPossible {
    [NSThread detachNewThreadSelector:@selector(_refreshIfPossible) toTarget:self withObject:nil];
}

- (void) reloadDataWithInvocation:(NSInvocation *)invocation {
_profile(reloadDataWithInvocation)
@synchronized (self) {
    UIProgressHUD *hud(loaded_ ? [self addProgressHUD] : nil);
    if (hud != nil)
        [hud setText:UCLocalize("RELOADING_DATA")];

    [database_ yieldToSelector:@selector(reloadDataWithInvocation:) withObject:invocation];

    size_t changes(0);

    [essential_ removeAllObjects];
    [broken_ removeAllObjects];

    _profile(reloadDataWithInvocation$Essential)
    NSArray *packages([database_ packages]);
    for (Package *package in packages) {
        if ([package half])
            [broken_ addObject:package];
        if ([package upgradableAndEssential:YES] && ![package ignored]) {
            if ([package essential] && [package installed] != nil)
                [essential_ addObject:package];
            ++changes;
        }
    }
    _end

    UITabBarItem *changesItem = [[[tabbar_ viewControllers] objectAtIndex:2] tabBarItem];
    if (changes != 0) {
        _trace();
        NSString *badge([[NSNumber numberWithInt:changes] stringValue]);
        [changesItem setBadgeValue:badge];
        [changesItem setAnimatedBadge:([essential_ count] > 0)];
        [self setApplicationIconBadgeNumber:changes];
    } else {
        _trace();
        [changesItem setBadgeValue:nil];
        [changesItem setAnimatedBadge:NO];
        [self setApplicationIconBadgeNumber:0];
    }

    Queuing_ = false;
    [self _updateData];

    if (hud != nil)
        [self removeProgressHUD:hud];
}
_end

    PrintTimes();
}

- (void) updateData {
    [self _updateData];
}

- (void) updateDataAndLoad {
    [self _updateData];
    if ([database_ progressDelegate] == nil)
        [self _loaded];
}

- (void) update_ {
    [database_ update];
    [self performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:YES];
}

- (void) reloadData {
    [self reloadDataWithInvocation:nil];
    if ([database_ progressDelegate] == nil)
        [self _loaded];
}

- (void) syncData {
    [self _saveConfig];
    [self detachNewProgressSelector:@selector(update_) toTarget:self forController:nil title:@"UPDATING_SOURCES"];
}

- (void) addSource:(NSDictionary *) source {
    CydiaAddSource(source);
}

- (void) addSource:(NSString *)href withDistribution:(NSString *)distribution andSections:(NSArray *)sections {
    CydiaAddSource(href, distribution, sections);
}

// XXX: this method should not return anything
- (BOOL) addTrivialSource:(NSString *)href {
    CydiaAddSource(href, @"./");
    return YES;
}

@end
