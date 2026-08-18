/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
 */
/* }}} */

#include "CyteKit/UCPlatform.h"
#include "Cydia/Appearance.h"
#include "Cydia/TabBarController.h"

#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/DatabaseStatus.h"
#include "Menes/ObjectHandle.h"
#include "Substrate.hpp"
#include "iPhonePrivate.h"

@interface CydiaTabBarController () <UITabBarControllerDelegate, FetchDelegate>
@end

@implementation CydiaTabBarController {
    __weak Database *database_;

    _H<UIActivityIndicatorView> indicator_;

    bool updating_;
    // This is intentionally weak under ARC; the former _transient field was strong.
    __weak NSObject<CydiaDelegate> *updatedelegate_;
}

- (id) initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) {
        database_ = database;
        [self setDelegate:self];

        indicator_ = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteTiny];
        [indicator_ setOrigin:CGPointMake(kCFCoreFoundationVersionNumber >= 800 ? 2 : 4, 2)];

        [[self view] setAutoresizingMask:CydiaAutoresizingFlexibleBoth];
    } return self;
}

- (void) beginUpdate {
    if (updating_)
        return;

    UIViewController *controller([[self viewControllers] objectAtIndex:1]);
    UITabBarItem *item([controller tabBarItem]);

    [item setBadgeValue:@""];
    UIView *badge(MSHookIvar<UIView *>([item view], "_badge"));

    [indicator_ startAnimating];
    [badge addSubview:indicator_];

    [updatedelegate_ retainNetworkActivityIndicator];
    updating_ = true;

    [NSThread
        detachNewThreadSelector:@selector(performUpdate)
        toTarget:self
        withObject:nil
    ];
}

- (void) performUpdate {
    @autoreleasepool {

    SourceStatus status(self, database_);
    [database_ updateWithStatus:status];

    [self
        performSelectorOnMainThread:@selector(completeUpdate)
        withObject:nil
        waitUntilDone:NO
    ];
    }
}

- (void) stopUpdateWithSelector:(SEL)selector {
    updating_ = false;
    [updatedelegate_ releaseNetworkActivityIndicator];

    UIViewController *controller([[self viewControllers] objectAtIndex:1]);
    [[controller tabBarItem] setBadgeValue:nil];

    [indicator_ removeFromSuperview];
    [indicator_ stopAnimating];

    [updatedelegate_ performSelector:selector withObject:nil afterDelay:0];
}

- (void) completeUpdate {
    if (!updating_)
        return;
    [self stopUpdateWithSelector:@selector(reloadData)];
}

- (void) cancelUpdate {
    [self stopUpdateWithSelector:@selector(updateDataAndLoad)];
}

- (void) cancelPressed {
    [self cancelUpdate];
}

- (BOOL) updating {
    return updating_;
}

- (bool) isSourceCancelled {
    return !updating_;
}

- (void) startSourceFetch:(NSString *)uri {
}

- (void) stopSourceFetch:(NSString *)uri {
}

- (void) setUpdateDelegate:(id)delegate {
    updatedelegate_ = delegate;
}

@end
