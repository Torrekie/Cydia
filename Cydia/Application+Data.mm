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
#include "Cydia/LegacyUICompatibilityNativeProvider.h"
#include "Cydia/LegacyUICompatibilityRuntimeEvidence.h"
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

#include <objc/runtime.h>
#include <unistd.h>

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

static BOOL CydiaNativeCompatibilityDiagnosticRequested(void) {
    NSString *value([[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_DIAGNOSTIC"]);
    return value != nil && [value length] != 0 && ![value isEqualToString:@"0"];
}

/* Keep the opt-in metadata probe bounded and side-effect free.  The provider
 * already validates property-list metadata, but the diagnostic must also
 * fail open if a malformed value ever crosses the compatibility boundary. */
static const NSUInteger CydiaNativeCompatibilityDiagnosticMaximumMetadataKeys = 1024;
static const NSUInteger CydiaNativeCompatibilityDiagnosticMaximumMetadataKeyLength = 2048;

static BOOL CydiaNativeCompatibilityDiagnosticSafeMetadataKey(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] != 0 &&
        [value length] <= CydiaNativeCompatibilityDiagnosticMaximumMetadataKeyLength &&
        [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

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

    /* `_loaded` is queued after the synchronous database reload and, when a
     * refresh ran, after its completion reload.  This keeps the opt-in
     * compatibility consumer on canonical post-load model objects. */
    [self consumeLegacyUICompatibilityRuntimeEvidenceIfRequested];
    [self consumeLegacyUICompatibilityApplicationSessionIfRequested];
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

/*
 * Build the opt-in P3 compatibility receipt after the normal model reload has
 * completed.  This lane evaluates policy only: it never invokes a member,
 * asks a provider for data, dispatches a route, or presents a mutation prompt.
 * Exact package/source sessions are created only for canonical objects owned by
 * the current Database; a small immutable NSDictionary is the sole synthetic
 * target.  The output path is accepted only from the explicit environment
 * variable and the evidence writer performs the final bounded/atomic check.
 */
- (void) consumeLegacyUICompatibilityRuntimeEvidenceIfRequested {
    if (!CydiaLegacyUICompatibilityRuntimeEvidenceRequested() ||
        legacyCompatibilityRuntimeEvidenceConsumed_)
        return;
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:
            @selector(consumeLegacyUICompatibilityRuntimeEvidenceIfRequested)
            withObject:nil waitUntilDone:NO];
        return;
    }
    legacyCompatibilityRuntimeEvidenceConsumed_ = YES;

    NSString *path(CydiaLegacyUICompatibilityRuntimeEvidenceOutputPath());
    NSString *runID(CydiaLegacyUICompatibilityRuntimeEvidenceRunID());
    CydiaLegacyUICompatibilityNativeSession *applicationSession(
        [self legacyUICompatibilitySessionForApplicationWithPresenter:tabbar_]);
    CydiaLegacyUICompatibilityNativeSession *renderingSession(nil);
    if ([self respondsToSelector:
            @selector(legacyUICompatibilitySessionForRenderingWithPresenter:)])
        renderingSession =
            [self legacyUICompatibilitySessionForRenderingWithPresenter:tabbar_];

    Package *canonicalPackage(nil);
    if (database_ != nil) {
        for (id candidate in [database_ packages])
            if (object_getClass(candidate) == [Package class]) {
                canonicalPackage = (Package *)candidate;
                break;
            }
    }
    CydiaLegacyUICompatibilityNativeSession *packageSession(
        canonicalPackage == nil ? nil :
            [self legacyUICompatibilitySessionForPackage:canonicalPackage presenter:tabbar_]);

    Source *canonicalSource(nil);
    if (database_ != nil) {
        for (id candidate in [database_ sources])
            if (object_getClass(candidate) == [Source class]) {
                canonicalSource = (Source *)candidate;
                break;
            }
    }
    CydiaLegacyUICompatibilityNativeSession *sourceSession(
        canonicalSource == nil ? nil :
            [self legacyUICompatibilitySessionForSource:canonicalSource presenter:tabbar_]);

    /* The dictionary is detached before the session is made and contains no
     * model, metadata, URL, credential, or device value. */
    NSDictionary *evidenceDictionary([NSDictionary dictionaryWithObjectsAndKeys:
        @"decision-only", @"mode", @"trusted-in-process", @"caller", nil]);
    CydiaLegacyUICompatibilityNativeSession *dictionarySession(
        legacyCompatibilityCaller_ == nil ? nil :
            [legacyCompatibilityCaller_ sessionForScope:@"NSDictionary"
                target:evidenceDictionary packageIdentity:nil sourceKey:nil
                presenter:tabbar_]);

    NSDictionary *sessions([NSDictionary dictionaryWithObjectsAndKeys:
        applicationSession ?: [NSNull null], @"CydiaObject",
        renderingSession ?: [NSNull null], @"CyteObject",
        packageSession ?: [NSNull null], @"Package",
        sourceSession ?: [NSNull null], @"Source",
        dictionarySession ?: [NSNull null], @"NSDictionary", nil]);

    NSDictionary *environment([[NSProcessInfo processInfo] environment]);
    NSMutableDictionary *identity([NSMutableDictionary dictionary]);
    for (NSString *key in @[
        @"CYDIA_NATIVE_COMPATIBILITY_EXPECTED_SOURCE_COMMIT",
        @"CYDIA_NATIVE_COMPATIBILITY_EXPECTED_SOURCE_TREE_SHA256",
        @"CYDIA_NATIVE_COMPATIBILITY_EXPECTED_VERSION",
    ]) {
        NSString *value([environment objectForKey:key]);
        NSString *receiptKey(nil);
        if ([key hasSuffix:@"SOURCE_COMMIT"])
            receiptKey = @"expectedSourceCommit";
        else if ([key hasSuffix:@"SOURCE_TREE_SHA256"])
            receiptKey = @"expectedSourceTreeSHA256";
        else
            receiptKey = @"expectedVersion";
        if ([value isKindOfClass:[NSString class]])
            [identity setObject:value forKey:receiptKey];
    }
    if (Cydia_ != nil)
        [identity setObject:Cydia_ forKey:@"runtimeVersion"];
    NSDictionary *info([[NSBundle mainBundle] infoDictionary]);
    for (NSString *key in @[
        @"CFBundleShortVersionString", @"CFBundleVersion"
    ]) {
        id value([info objectForKey:key]);
        if ([value isKindOfClass:[NSString class]])
            [identity setObject:value forKey:
                [key isEqualToString:@"CFBundleVersion"] ?
                    @"bundleVersion" : @"bundleShortVersion"];
    }
    [identity setObject:@((unsigned int)getpid()) forKey:@"processID"];

    NSError *error(nil);
    if (!CydiaLegacyUICompatibilityRuntimeEvidenceWriteReceipt(path, runID,
            identity, sessions, &error))
        NSLog(@"Cydia native compatibility evidence: %@", error);
}

/*
 * This is an opt-in production consumer for the typed compatibility service.
 * A normal launch does not mint or retain a session beyond the existing
 * provider/caller graph.  A diagnostic launch uses the real post-load
 * Database objects and the attached native tab bar as its presenter, so a
 * successful result is meaningful installed-runtime evidence rather than a
 * synthetic probe fixture.  It deliberately performs no mutation and only
 * asks the router to reject a made-up source key.
 */
- (void) consumeLegacyUICompatibilityApplicationSessionIfRequested {
    if (!CydiaNativeCompatibilityDiagnosticRequested())
        return;
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:
            @selector(consumeLegacyUICompatibilityApplicationSessionIfRequested)
            withObject:nil waitUntilDone:NO];
        return;
    }
    if (legacyCompatibilityApplicationSession_ != nil)
        return;

    CydiaLegacyUICompatibilityNativeSession *applicationSession(
        [self legacyUICompatibilitySessionForApplicationWithPresenter:tabbar_]);
    if (applicationSession == nil) {
        NSLog(@"Cydia native compatibility diagnostic: application session unavailable");
        return;
    }
    legacyCompatibilityApplicationSession_ = applicationSession;

    id allSources([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getAllSources"
        arguments:@[] targetOrigin:nil]);
    id installedPackages([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getInstalledPackages"
        arguments:@[] targetOrigin:nil]);

    BOOL metadataKeysRead(NO);
    NSUInteger metadataKeyCount(0);
    NSString *metadataProbeKey(nil);
    id metadataKeys([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getMetadataKeys"
        arguments:@[] targetOrigin:nil]);
    @try {
        if ([metadataKeys isKindOfClass:[NSArray class]] &&
            [metadataKeys count] <= CydiaNativeCompatibilityDiagnosticMaximumMetadataKeys) {
            metadataKeysRead = YES;
            metadataKeyCount = [metadataKeys count];
            for (id candidate in (NSArray *)metadataKeys) {
                if (!CydiaNativeCompatibilityDiagnosticSafeMetadataKey(candidate)) {
                    metadataKeysRead = NO;
                    metadataKeyCount = 0;
                    metadataProbeKey = nil;
                    break;
                }
                if (metadataProbeKey == nil)
                    metadataProbeKey = [(NSString *)candidate copy];
            }
        }
    } @catch (NSException *exception) {
        (void)exception;
        metadataKeysRead = NO;
        metadataKeyCount = 0;
        metadataProbeKey = nil;
    }

    BOOL metadataValueRead(NO);
    BOOL metadataValueDefined(NO);
    if (metadataProbeKey != nil) {
        id metadataValue([applicationSession invokeScope:@"CydiaObject"
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getMetadataValue"
            arguments:@[metadataProbeKey] targetOrigin:nil]);
        metadataValueRead = metadataValue != nil &&
            metadataValue != [CydiaLegacyUIUndefinedValue value];
        metadataValueDefined = metadataValueRead && metadataValue != [NSNull null];
    }

    Package *canonicalPackage(nil);
    NSString *canonicalPackageIdentity(nil);
    NSString *canonicalPackageName(nil);
    for (id candidate in [database_ packages])
        if (object_getClass(candidate) == [Package class]) {
            canonicalPackage = (Package *)candidate;
            canonicalPackageIdentity = [[canonicalPackage id] copy];
            canonicalPackageName = [[canonicalPackage name] copy];
            break;
        }

    BOOL packageLookupRead(NO);
    if ([canonicalPackageIdentity isKindOfClass:[NSString class]] &&
        [canonicalPackageIdentity length] != 0) {
        id resolvedPackage([applicationSession invokeScope:@"CydiaObject"
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getPackageById"
            arguments:@[canonicalPackageIdentity] targetOrigin:nil]);
        packageLookupRead = object_getClass(resolvedPackage) == [Package class] &&
            resolvedPackage == canonicalPackage;
    }

    id sessionValue([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getSessionValue"
        arguments:@[@"native-compatibility-diagnostic"] targetOrigin:nil]);
    BOOL sessionRead([applicationSession isActive] &&
        [applicationSession lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonNone &&
        sessionValue != nil);

    NSString *substitutionInput([canonicalPackageIdentity length] != 0 ?
        [NSString stringWithFormat:@"native %@", canonicalPackageIdentity] :
        @"native-compatibility-diagnostic");
    id substitutedNames([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"substitutePackageNames"
        arguments:@[substitutionInput] targetOrigin:nil]);
    BOOL substituteRead([substitutedNames isKindOfClass:[NSString class]]);
    BOOL packageNameSubstitution(canonicalPackageName != nil &&
        [substitutedNames isEqualToString:
            [NSString stringWithFormat:@"native %@", canonicalPackageName]]);

    CydiaLegacyUICompatibilityNativeSession *packageSession(nil);
    BOOL packageRead(NO);
    if (canonicalPackage != nil) {
        packageSession = [self legacyUICompatibilitySessionForPackage:canonicalPackage
            presenter:tabbar_];
        id packageIdentity([packageSession invokeScope:@"Package"
            memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"id"
            arguments:@[] targetOrigin:nil]);
        packageRead = [packageIdentity isKindOfClass:[NSString class]] &&
            [packageIdentity length] != 0;
    }

    Source *canonicalSource(nil);
    for (id candidate in [database_ sources])
        if (object_getClass(candidate) == [Source class]) {
            canonicalSource = (Source *)candidate;
            break;
        }

    CydiaLegacyUICompatibilityNativeSession *sourceSession(nil);
    BOOL sourceRead(NO);
    if (canonicalSource != nil) {
        sourceSession = [self legacyUICompatibilitySessionForSource:canonicalSource
            presenter:tabbar_];
        id sourceKey([sourceSession invokeScope:@"Source"
            memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
            arguments:@[] targetOrigin:nil]);
        sourceRead = [sourceKey isKindOfClass:[NSString class]] &&
            [sourceKey length] != 0;
    }

    BOOL unknownSourceRouteDenied(![applicationSession handoffRouteURL:
        [NSURL URLWithString:
            @"cydia://sources/deb%3Ahttps%3A%2F%2Fnative-compatibility-diagnostic.invalid%2F%3A.%2F"]]);

    CydiaLegacyUICompatibilityNativeSession *invalidationSession(
        [self legacyUICompatibilitySessionForApplicationWithPresenter:tabbar_]);
    BOOL invalidationDenied(NO);
    if (invalidationSession != nil && [invalidationSession isActive]) {
        [invalidationSession invalidate];
        id invalidatedValue([invalidationSession invokeScope:@"CydiaObject"
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getAllSources"
            arguments:@[] targetOrigin:nil]);
        invalidationDenied = ![invalidationSession isActive] &&
            invalidatedValue == [CydiaLegacyUIUndefinedValue value] &&
            [invalidationSession lastDenialReason] ==
                CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability;
    }

    NSUInteger sourceCount([allSources isKindOfClass:[NSArray class]] ?
        [allSources count] : 0);
    NSUInteger installedPackageCount([installedPackages isKindOfClass:[NSArray class]] ?
        [installedPackages count] : 0);
    NSDictionary *result(@{
        @"applicationSession": @([applicationSession isActive]),
        @"getAllSources": @([allSources isKindOfClass:[NSArray class]]),
        @"sourceCount": @(sourceCount),
        @"getInstalledPackages": @([installedPackages isKindOfClass:[NSArray class]]),
        @"installedPackageCount": @(installedPackageCount),
        @"getMetadataKeys": @(metadataKeysRead),
        @"metadataKeyCount": @(metadataKeyCount),
        @"getMetadataValue": @(metadataValueRead),
        @"metadataValueDefined": @(metadataValueDefined),
        @"canonicalPackageTarget": @(canonicalPackage != nil),
        @"getPackageById": @(packageLookupRead),
        @"packageRead": @(packageRead),
        @"getSessionValue": @(sessionRead),
        @"sessionValueDefined": @(sessionValue != [CydiaLegacyUIUndefinedValue value]),
        @"substitutePackageNames": @(substituteRead),
        @"packageNameSubstitution": @(packageNameSubstitution),
        @"canonicalSourceTarget": @(canonicalSource != nil),
        @"sourceRead": @(sourceRead),
        @"unknownSourceRouteDenied": @(unknownSourceRouteDenied),
        @"invalidationDenied": @(invalidationDenied),
    });
    NSLog(@"Cydia native compatibility diagnostic: %@", result);
}

- (void) syncData {
    [self _saveConfig];
    [self detachNewProgressSelector:@selector(update_) toTarget:self forController:nil title:@"UPDATING_SOURCES"];
}

- (void) addSource:(NSDictionary *) source {
    if (!CydiaCanEditManagedSources())
        return;
    CydiaAddSource(source);
}

- (void) addSource:(NSString *)href withDistribution:(NSString *)distribution andSections:(NSArray *)sections {
    if (!CydiaCanEditManagedSources())
        return;
    CydiaAddSource(href, distribution, sections);
}

// XXX: this method should not return anything
- (BOOL) addTrivialSource:(NSString *)href {
    if (!CydiaCanEditManagedSources())
        return NO;
    CydiaAddSource(href, @"./");
    return YES;
}

@end
