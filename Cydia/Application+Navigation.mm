/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 */

#include "Cydia/Application.h"
#include "Cydia/ApplicationInternal.h"
#include "Cydia/AppState.h"
#include "Cydia/Appearance.h"
#include "Cydia/ChangeControllers.h"
#include "Cydia/ExternalURLController.h"
#include "Cydia/HomeController.h"
#include "Cydia/PackageControllers.h"
#include "Cydia/PackageFeatureControllers.h"
#include "Cydia/PackageViews.h"
#include "Cydia/SectionControllers.h"
#include "Cydia/SourceControllers.h"
#include "Cydia/StashController.h"
#include "Cydia/TabBarController.h"
#include "Cydia/URLProtocol.h"
#include "Cydia/UIRouteDispatch.h"
#include "CyteKit/CyteKit.h"
#include "CyteKit/Localize.h"
#include "CyteKit/NavigationController.h"
#include "CyteKit/extern.h"
#include "Menes/Menes.h"
#include "iPhonePrivate.h"

#define ForRelease 1
#undef _trace
#define _trace(args...)

static BOOL CydiaPackageRouteMatchesController(UIViewController *controller,
                                               NSString *identity) {
    if ([controller isKindOfClass:[UINavigationController class]])
        controller = [(UINavigationController *) controller topViewController];
    if (![identity isKindOfClass:[NSString class]] ||
        ![controller respondsToSelector:@selector(navigationURL)])
        return NO;
    NSString *existingURL([[[controller navigationURL] absoluteString] copy]);
    NSString *expectedURL([NSString stringWithFormat:@"cydia://package/%@", identity]);
    return [existingURL isEqualToString:expectedURL];
}

static BOOL CydiaPackageRouteIsAlreadyVisible(CydiaTabBarController *tabbar,
                                              NSString *identity) {
    if (CydiaPackageRouteMatchesController([tabbar unselectedViewController], identity))
        return YES;
    return CydiaPackageRouteMatchesController([tabbar selectedViewController], identity);
}

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

- (CyteViewController *) _pageForRoute:(CydiaUIRouteDispatchResult *)route
                               context:(CydiaUIRouteContext *)context
                          withReferrer:(NSString *)referrer {
    CydiaUIRouteDescriptor *descriptor([route descriptor]);
    CydiaUIRouteDecision *decision([route decision]);
    NSArray *arguments([descriptor arguments]);
    CyteViewController *controller(nil);

    switch ([descriptor kind]) {
        case CydiaUIRouteKindHome:
            controller = [[HomeController alloc] initWithDatabase:database_];
            break;
        case CydiaUIRouteKindSources:
            controller = [[SourcesController alloc] initWithDatabase:database_];
            break;
        case CydiaUIRouteKindSourceAdd: {
            /* An OS deep link is allowed only because the policy requires the
             * same explicit native prompt used by Cydia's Add button. */
            if ([context caller] == CydiaUIRouteCallerExternalURL &&
                ![decision requiresConfirmation])
                return nil;
            SourcesController *sources([[SourcesController alloc] initWithDatabase:database_]);
            [sources showAddSourcePrompt];
            controller = sources;
            break;
        }
        case CydiaUIRouteKindSource: {
            Source *source([database_ sourceWithKey:[arguments objectAtIndex:0]]);
            if (source == nil)
                return nil;
            controller = [[SectionsController alloc] initWithDatabase:database_ source:source];
            break;
        }
        case CydiaUIRouteKindSections:
            controller = [[SectionsController alloc] initWithDatabase:database_ source:nil];
            break;
        case CydiaUIRouteKindSection: {
            Source *source(nil);
            NSString *section(nil);
            if ([arguments count] == 1) {
                section = [arguments objectAtIndex:0];
                if ([section isEqualToString:@"all"] || [section isEqualToString:@"*"])
                    section = nil;
            } else {
                NSString *key([arguments objectAtIndex:0]);
                if (![key isEqualToString:@"*"]) {
                    source = [database_ sourceWithKey:key];
                    if (source == nil)
                        return nil;
                }
                section = [arguments objectAtIndex:1];
                if ([section isEqualToString:@"*"])
                    section = nil;
            }
            controller = [[SectionController alloc] initWithDatabase:database_
                source:source section:section];
            break;
        }
        case CydiaUIRouteKindSearch:
            controller = [[SearchController alloc] initWithDatabase:database_
                query:[arguments count] == 0 ? nil : [arguments objectAtIndex:0]];
            break;
        case CydiaUIRouteKindChanges:
            controller = [[ChangesController alloc] initWithDatabase:database_];
            break;
        case CydiaUIRouteKindInstalled:
            controller = [[InstalledController alloc] initWithDatabase:database_];
            break;
        case CydiaUIRouteKindPackage:
            controller = [self pageForPackage:[arguments objectAtIndex:0]
                withReferrer:referrer];
            break;
        case CydiaUIRouteKindPackageSettings:
            controller = [[PackageSettingsController alloc] initWithDatabase:database_
                package:[arguments objectAtIndex:0]];
            break;
        case CydiaUIRouteKindPackageFiles:
            controller = [[FileTable alloc] initWithDatabase:database_
                forPackage:[arguments objectAtIndex:0]];
            break;
        case CydiaUIRouteKindLaunchApplication:
            [self launchApplicationWithIdentifier:[arguments objectAtIndex:0] suspended:NO];
            return nil;
        case CydiaUIRouteKindExternalOpen:
            controller = [[ExternalURLController alloc]
                initWithRouteDescriptor:descriptor];
            break;
    }

    [controller setDelegate:self];
    return controller;
}

- (CyteViewController *) pageForURL:(NSURL *)url
                            context:(NSObject<CyteWebNavigationContext> *)context
                       withReferrer:(NSString *)referrer {
    if (![context isKindOfClass:[CydiaUIRouteContext class]])
        return nil;
    CydiaUIRouteContext *routeContext((CydiaUIRouteContext *) context);

    CydiaUIRouteDispatchResult *route(CydiaUIDispatchRouteURL(url, routeContext,
        ^BOOL(NSString *sourceKey) {
            return [database_ sourceWithKey:sourceKey] != nil;
        }));
    /* Every typed caller is enforced before any controller or command is
     * created. Rejected application routes are terminal at this boundary. */
    if (![route isAllowed])
        return nil;

    /* A depiction/native caller can deliver the same package URL while the
     * transient package tab is settling. Returning no new page prevents a
     * second PackageDetailController and its initial WK load. */
    if ([[route descriptor] kind] == CydiaUIRouteKindPackage) {
        NSArray *arguments([[route descriptor] arguments]);
        NSString *identity([arguments count] == 0 ? nil : [arguments objectAtIndex:0]);
        if (CydiaPackageRouteIsAlreadyVisible(tabbar_, identity))
            return nil;
    }

    return [self _pageForRoute:route context:routeContext
        withReferrer:referrer];
}

- (CyteViewController *) pageForURL:(NSURL *)url forExternal:(BOOL)external withReferrer:(NSString *)referrer {
    CydiaUIRouteContext *context(external ? [CydiaUIRouteContext externalURLContext] :
        [CydiaUIRouteContext trustedNativeContext]);
    return [self pageForURL:url context:context withReferrer:referrer];
}

- (BOOL) openCydiaURL:(NSURL *)url context:(CydiaUIRouteContext *)context {
    if (url == nil || ![context isKindOfClass:[CydiaUIRouteContext class]])
        return NO;

    /* Resolve the typed dispatch once at the command boundary. Native command
     * routes (currently cydia://launch/...) intentionally return no
     * controller, but they are still handled successfully after policy
     * approval. Treating a nil controller as failure made a completed launch
     * look denied to legacy and OS URL callers. */
    CydiaUIRouteDispatchResult *route(CydiaUIDispatchRouteURL(url, context,
        ^BOOL(NSString *sourceKey) {
            return [database_ sourceWithKey:sourceKey] != nil;
        }));
    if (![route isAllowed])
        return NO;

    if ([[route descriptor] kind] == CydiaUIRouteKindPackage) {
        NSArray *arguments([[route descriptor] arguments]);
        NSString *identity([arguments count] == 0 ? nil : [arguments objectAtIndex:0]);
        if (CydiaPackageRouteIsAlreadyVisible(tabbar_, identity))
            return YES;
    }

    CyteViewController *page([self _pageForRoute:route context:context
        withReferrer:nil]);

    if (page != nil) {
        if ([[route descriptor] kind] == CydiaUIRouteKindExternalOpen) {
            /* An external coordinator is a temporary child of the current
             * page, not a replacement for the transient tab's root. */
            UIViewController *selected([tabbar_ selectedViewController]);
            if (![selected isKindOfClass:[UINavigationController class]])
                return NO;
            UINavigationController *navigation((UINavigationController *) selected);
            if ([[navigation topViewController] isKindOfClass:[ExternalURLController class]]) {
                ExternalURLController *pending((ExternalURLController *)
                    [navigation topViewController]);
                if ([pending hasPendingOpenRequest])
                    return [pending coalescePendingDestinationURL:
                        [[route descriptor] externalURL]];
            }
            if ([navigation topViewController] == nil ||
                [tabbar_ presentedViewController] != nil ||
                [navigation presentedViewController] != nil ||
                [[navigation topViewController] presentedViewController] != nil)
                return NO;
            [navigation pushViewController:page animated:YES];
        } else {
            [tabbar_ setUnselectedViewController:page];
        }
    }

    if (page != nil)
        return YES;

    /* A native command has completed its side effect in _pageForRoute:. Do
     * not require a view-controller result for that disposition. */
    return [[route decision] disposition] == CydiaUIRouteDispositionNativeCommand;
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
