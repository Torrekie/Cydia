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
#include "Cydia/FAQController.h"
#include "Cydia/UpgradingGuideController.h"
#include "Cydia/ApplicationExtensionsController.h"
#include "Cydia/MoreSourcesController.h"
#include "Cydia/CopyingFilesGuideController.h"
#include "Cydia/HomeGuideController.h"
#include "Cydia/HomePlaceholderController.h"
#include "Cydia/HomeStorageController.h"
#include "Cydia/HomeController.h"
#include "Cydia/SettingsController.h"
#include "Cydia/CapabilityController.h"
#include "Cydia/AdvancedSettingsController.h"
#include "Cydia/KeyringImportController.h"
#include "Cydia/PackageControllers.h"
#include "Cydia/PackageUnavailableController.h"
#include "Cydia/PackageFeatureControllers.h"
#include "Cydia/PackageSupportController.h"
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

#import <objc/runtime.h>

#define ForRelease 1
#undef _trace
#define _trace(args...)

static BOOL CydiaPackageRouteMatchesController(UIViewController *controller,
                                               NSString *identity) {
    if ([controller isKindOfClass:[UINavigationController class]])
        controller = [(UINavigationController *) controller topViewController];
    if ([controller isKindOfClass:[PackageUnavailableController class]])
        return NO;
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

static char CydiaPendingExternalURLKey;

static UIViewController *CydiaExternalPresentationHost(UIViewController *controller) {
    /* Follow the visible hierarchy, including native Support's form-sheet
     * navigation and the guide detail column, rather than the covered tab. */
    while (controller != nil) {
        UIViewController *next(controller.presentedViewController);
        if (next == nil && [controller isKindOfClass:[UITabBarController class]])
            next = [(UITabBarController *)controller selectedViewController];
        if (next == nil && [controller isKindOfClass:[UINavigationController class]])
            next = [(UINavigationController *)controller visibleViewController];
        if (next == nil && [controller isKindOfClass:[UISplitViewController class]])
            next = [[(UISplitViewController *)controller viewControllers] lastObject];
        if (next == nil || next == controller)
            return controller;
        controller = next;
    }
    return nil;
}

@implementation Cydia (Navigation)
- (BOOL)_openExternalRoute:(CydiaUIRouteDispatchResult *)route {
    CydiaUIRouteDescriptor *descriptor([route descriptor]);
    if (![route isAllowed] || [descriptor kind] != CydiaUIRouteKindExternalOpen)
        return NO;
    ExternalURLController *pending(objc_getAssociatedObject(self,
        &CydiaPendingExternalURLKey));
    if ([pending hasPendingOpenRequest])
        return [pending coalescePendingDestinationURL:[descriptor externalURL]];

    UIViewController *presenter(CydiaExternalPresentationHost([window_ rootViewController]));
    /* An unrelated alert/presentation is not a new destination host. */
    if (presenter == nil || [presenter isKindOfClass:[UIAlertController class]] ||
        presenter.isBeingPresented || presenter.isBeingDismissed ||
        presenter.presentedViewController != nil)
        return NO;
    ExternalURLController *coordinator([[ExternalURLController alloc]
        initWithRouteDescriptor:descriptor]);
    if (coordinator == nil)
        return NO;
    [coordinator setDelegate:self];
    __weak Cydia *weakApplication(self);
    __weak ExternalURLController *weakCoordinator(coordinator);
    objc_setAssociatedObject(self, &CydiaPendingExternalURLKey, coordinator,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL opened([coordinator openFromViewController:presenter completion:^{
        Cydia *application(weakApplication);
        if (application != nil && objc_getAssociatedObject(application,
                &CydiaPendingExternalURLKey) == weakCoordinator)
            objc_setAssociatedObject(application, &CydiaPendingExternalURLKey, nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }]);
    if (!opened)
        objc_setAssociatedObject(self, &CydiaPendingExternalURLKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return opened;
}

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
    CyteViewController *page([[CYPackageController alloc] initWithDatabase:database_
        forPackage:name withReferrer:referrer]);
    return page ?: [[PackageUnavailableController alloc] initWithDatabase:database_
        forPackage:name withReferrer:referrer];
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
        case CydiaUIRouteKindFAQ:
            controller = [arguments count] == 1 ?
                [[FAQController alloc] init] :
                [[FAQController alloc] initWithQuestionIdentifier:[arguments objectAtIndex:1]];
            if (controller == nil)
                return nil;
            break;
        case CydiaUIRouteKindUpgradingGuide:
            controller = [arguments count] == 1 ?
                [[UpgradingGuideController alloc] init] :
                [[UpgradingGuideController alloc] initWithPageIdentifier:[arguments objectAtIndex:1]];
            if (controller == nil)
                return nil;
            break;
        case CydiaUIRouteKindApplicationExtensions:
            controller = [arguments count] == 1 ?
                [[ApplicationExtensionsController alloc] init] :
                [[ApplicationExtensionsController alloc] initWithBundleIdentifier:[arguments objectAtIndex:1]];
            if (controller == nil)
                return nil;
            break;
        case CydiaUIRouteKindMoreSources:
            controller = [[MoreSourcesController alloc] initWithProvider:
                [[CydiaMoreSourcesProvider alloc] initWithDatabase:database_]];
            break;
        case CydiaUIRouteKindCopyingFiles:
            controller = [[CopyingFilesGuideController alloc] init];
            break;
        case CydiaUIRouteKindHomeGuide:
            if ([[arguments objectAtIndex:0] isEqualToString:@"settings"])
                controller = [arguments count] != 2 ?
                    [[CydiaSettingsController alloc] initWithDatabase:database_] :
                    [[arguments objectAtIndex:1] isEqualToString:@"capabilities"] ?
                        [[CydiaCapabilityController alloc] initWithDatabase:database_] :
                    [[arguments objectAtIndex:1] isEqualToString:@"key-import"] ?
                        [[CydiaKeyringImportController alloc] initWithDatabase:database_] :
                        [[CydiaAdvancedSettingsController alloc] initWithDatabase:database_];
            else if ([[arguments objectAtIndex:0] isEqualToString:@"storage"])
                controller = [[HomeStorageController alloc] init];
            else if ([[@[@"featured", @"themes", @"account"] copy]
                      containsObject:[arguments objectAtIndex:0]])
                controller = [[HomePlaceholderController alloc]
                    initWithPageIdentifier:[arguments objectAtIndex:0]];
            else
                controller = [[HomeGuideController alloc]
                    initWithPageIdentifier:[arguments objectAtIndex:0]];
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
        case CydiaUIRouteKindPackageSupport:
            controller = [[PackageSupportController alloc] initWithDatabase:database_
                package:[arguments objectAtIndex:0]];
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

    if ([[route descriptor] kind] == CydiaUIRouteKindExternalOpen) {
        [self _openExternalRoute:route];
        return nil;
    }

    /* Depiction/native callers can hand the same package URL to pageForURL:
     * while the transient package tab is settling.  Returning no new page is
     * the route-level no-op used by the caller, and prevents a second native
     * PackageDetailController (and therefore a second initial WK load). */
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

    if ([[route descriptor] kind] == CydiaUIRouteKindExternalOpen)
        return [self _openExternalRoute:route];

    /* A package URL can be delivered twice while an external/openURL caller
     * and the transient-tab handoff settle on the main queue.  Recreating the
     * same package controller starts a second WK depiction load before the
     * first one settles, producing duplicate initial server requests.  Keep
     * one transient controller per package identity; explicit retry remains
     * owned by PackageDepictionView and still issues exactly one reload. */
    if ([[route descriptor] kind] == CydiaUIRouteKindPackage) {
        NSArray *arguments([[route descriptor] arguments]);
        NSString *identity([arguments count] == 0 ? nil : [arguments objectAtIndex:0]);
        if (CydiaPackageRouteIsAlreadyVisible(tabbar_, identity))
            return YES;
    }

    CyteViewController *page([self _pageForRoute:route context:context
        withReferrer:nil]);

    if (page != nil)
        [tabbar_ setUnselectedViewController:page];

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
    else if ([url isFileURL])
        [self openKeyringFileURL:url];
    else
        [self openCydiaURL:url context:[CydiaUIRouteContext externalURLContext]];
}

- (BOOL) openKeyringFileURL:(NSURL *)url {
    if (![url isFileURL]) return NO;
    NSString *extension([[url pathExtension] lowercaseString]);
    if (![@[@"asc", @"gpg", @"pgp", @"key"] containsObject:extension]) return NO;
    CydiaKeyringImportController *controller([[CydiaKeyringImportController alloc]
        initWithDatabase:database_ importURL:url]);
    [controller setDelegate:self];
    [tabbar_ setUnselectedViewController:controller];
    return YES;
}

@end
