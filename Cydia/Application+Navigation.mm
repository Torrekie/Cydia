/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 */

#include "Cydia/Application.h"
#include "Cydia/ApplicationInternal.h"
#include "Cydia/AppState.h"
#include "Cydia/Appearance.h"
#include "Cydia/CydiaWebViewController.h"
#include "Cydia/ChangeControllers.h"
#include "Cydia/HomeController.h"
#include "Cydia/PackageControllers.h"
#include "Cydia/PackageFeatureControllers.h"
#include "Cydia/PackageViews.h"
#include "Cydia/SectionControllers.h"
#include "Cydia/SourceControllers.h"
#include "Cydia/StashController.h"
#include "Cydia/TabBarController.h"
#include "Cydia/URLProtocol.h"
#include "CyteKit/CyteKit.h"
#include "CyteKit/Localize.h"
#include "CyteKit/NavigationController.h"
#include "CyteKit/extern.h"
#include "Menes/Menes.h"
#include "iPhonePrivate.h"

#define ForRelease 1
#undef _trace
#define _trace(args...)

@implementation Cydia (Navigation)
- (void) disemulate {
    if (emulated_ == nil)
        return;

    [window_ setRootViewController:tabbar_];
    emulated_ = nil;

    [window_ setUserInteractionEnabled:YES];
}

- (void) presentModalViewController:(UIViewController *)controller force:(BOOL)force {
    UINavigationController *navigation([[UINavigationController alloc] initWithRootViewController:controller]);

    UIViewController *parent;
    if (emulated_ == nil)
        parent = tabbar_;
    else if (!force)
        parent = emulated_;
    else {
        [self disemulate];
        parent = tabbar_;
    }

    if (IsWildcat_)
        [navigation setModalPresentationStyle:UIModalPresentationFormSheet];
    [parent presentModalViewController:navigation animated:YES];
}

- (CyteViewController *) pageForPackage:(NSString *)name withReferrer:(NSString *)referrer {
    return [[CYPackageController alloc] initWithDatabase:database_ forPackage:name withReferrer:referrer];
}

- (CyteViewController *) _legacyPageForURL:(NSURL *)url forExternal:(BOOL)external withReferrer:(NSString *)referrer {
    NSString *scheme([[url scheme] lowercaseString]);
    if ([[url absoluteString] length] <= [scheme length] + 3)
        return nil;
    NSString *path([[url absoluteString] substringFromIndex:[scheme length] + 3]);
    NSArray *components([path componentsSeparatedByString:@"/"]);

    if ([scheme isEqualToString:@"apptapp"] && [components count] > 0 && [[components objectAtIndex:0] isEqualToString:@"package"]) {
        CyteViewController *controller([self pageForPackage:[components objectAtIndex:1] withReferrer:referrer]);
        if (controller != nil)
            [controller setDelegate:self];
        return controller;
    }

    if ([components count] < 1 || ![scheme isEqualToString:@"cydia"])
        return nil;

    NSString *base([components objectAtIndex:0]);

    CyteViewController *controller = nil;

    if ([base isEqualToString:@"url"]) {
        // This kind of URL can contain slashes in the argument, so we can't parse them below.
        NSString *destination = [[url absoluteString] substringFromIndex:([scheme length] + [@"://" length] + [base length] + [@"/" length])];
        controller = [[CydiaWebViewController alloc] initWithURL:[NSURL URLWithString:destination]];
    } else if (!external && [components count] == 1) {
        if ([base isEqualToString:@"sources"])
            controller = [[SourcesController alloc] initWithDatabase:database_];

        if ([base isEqualToString:@"home"])
            controller = [[HomeController alloc] init];

        if ([base isEqualToString:@"sections"])
            controller = [[SectionsController alloc] initWithDatabase:database_ source:nil];

        if ([base isEqualToString:@"search"])
            controller = [[SearchController alloc] initWithDatabase:database_ query:nil];

        if ([base isEqualToString:@"changes"])
            controller = [[ChangesController alloc] initWithDatabase:database_];

        if ([base isEqualToString:@"installed"])
            controller = [[InstalledController alloc] initWithDatabase:database_];
    } else if ([components count] == 2) {
        NSString *argument = [[components objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        if ([base isEqualToString:@"package"])
            controller = [self pageForPackage:argument withReferrer:referrer];

        if (!external && [base isEqualToString:@"search"])
            controller = [[SearchController alloc] initWithDatabase:database_ query:argument];

        if (!external && [base isEqualToString:@"sections"]) {
            if ([argument isEqualToString:@"all"] || [argument isEqualToString:@"*"])
                argument = nil;
            controller = [[SectionController alloc] initWithDatabase:database_ source:nil section:argument];
        }

        if ([base isEqualToString:@"sources"]) {
            if ([argument isEqualToString:@"add"]) {
                controller = [[SourcesController alloc] initWithDatabase:database_];
                [(SourcesController *)controller showAddSourcePrompt];
            } else {
                Source *source([database_ sourceWithKey:argument]);
                controller = [[SectionsController alloc] initWithDatabase:database_ source:source];
            }
        }

        if (!external && [base isEqualToString:@"launch"]) {
            [self launchApplicationWithIdentifier:argument suspended:NO];
            return nil;
        }
    } else if (!external && [components count] == 3) {
        NSString *arg1 = [[components objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *arg2 = [[components objectAtIndex:2] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        if ([base isEqualToString:@"package"]) {
            if ([arg2 isEqualToString:@"settings"])
                controller = [[PackageSettingsController alloc] initWithDatabase:database_ package:arg1];
            else if ([arg2 isEqualToString:@"files"])
                controller = [[FileTable alloc] initWithDatabase:database_ forPackage:arg1];
        }

        if ([base isEqualToString:@"sections"]) {
            Source *source([arg1 isEqualToString:@"*"] ? nil : [database_ sourceWithKey:arg1]);
            NSString *section([arg2 isEqualToString:@"*"] ? nil : arg2);
            controller = [[SectionController alloc] initWithDatabase:database_ source:source section:section];
        }
    }

    [controller setDelegate:self];
    return controller;
}

- (CyteViewController *) pageForURL:(NSURL *)url context:(CydiaUIRouteContext *)context withReferrer:(NSString *)referrer {
    if (context == nil)
        return nil;

    /* P0.1 evaluates the future policy in shadow mode. P0.4 switches routing
       only after saved-stack, popup, and installed runtime evidence exists. */
    CydiaUIRouteDescriptor *descriptor(CydiaUIParseRouteURL(url, NULL));
    CydiaUIRouteDecision *decision(CydiaUIEvaluateRoute(descriptor, context));
    (void) decision;

    BOOL external([context caller] == CydiaUIRouteCallerExternalURL);
    return [self _legacyPageForURL:url forExternal:external withReferrer:referrer];
}

- (CyteViewController *) pageForURL:(NSURL *)url forExternal:(BOOL)external withReferrer:(NSString *)referrer {
    return [self _legacyPageForURL:url forExternal:external withReferrer:referrer];
}

- (BOOL) openCydiaURL:(NSURL *)url context:(CydiaUIRouteContext *)context {
    CyteViewController *page([self pageForURL:url context:context withReferrer:nil]);

    if (page != nil)
        [tabbar_ setUnselectedViewController:page];

    return page != nil;
}

- (BOOL) openCydiaURL:(NSURL *)url forExternal:(BOOL)external {
    CydiaUIRouteContext *context(external ? [CydiaUIRouteContext externalURLContext] :
        [CydiaUIRouteContext trustedNativeContext]);
    return [self openCydiaURL:url context:context];
}

- (void) applicationOpenURL:(NSURL *)url {
    [super applicationOpenURL:url];

    if (!loaded_)
        starturl_ = url;
    else
        [self openCydiaURL:url context:[CydiaUIRouteContext externalURLContext]];
}

@end
