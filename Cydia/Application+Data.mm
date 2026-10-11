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
#include "Cydia/NativeMutationDiagnostic.h"
#include "Cydia/Package.h"
#include "Cydia/PackageFeatureControllers.h"
#include "Cydia/ProgressController.h"
#include "Cydia/ProgressEvent.h"
#include "Cydia/SourceControllers.h"
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
#include <dispatch/dispatch.h>
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

NSDictionary *CydiaNativeCompatibilityLifetimeDiagnostic(
    Cydia *application, id presenter, Database *database, NSString *metadataKey);

static BOOL CydiaNativeCompatibilityDiagnosticRequested(void) {
    NSString *value([[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_DIAGNOSTIC"]);
    return value != nil && [value length] != 0 && ![value isEqualToString:@"0"];
}

/* Separate opt-in lane for installed execution evidence.  The decision
 * receipt must remain side-effect free; this lane invokes only canonical,
 * synchronous package reads and bound immutable snapshots. */
static NSString *CydiaNativeCompatibilityExecutionEvidencePath(void) {
    NSString *path([[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_EXECUTION_PATH"]);
    if (![path isKindOfClass:[NSString class]] || [path length] == 0 ||
        [path length] > 1024 || ![path hasPrefix:@"/"] ||
        [path rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound ||
        [[path stringByStandardizingPath] isEqualToString:path] == NO)
        return nil;
    NSString *parent([path stringByDeletingLastPathComponent]);
    BOOL directory(NO);
    if (![[NSFileManager defaultManager] fileExistsAtPath:parent isDirectory:&directory] ||
        !directory || [[NSFileManager defaultManager] fileExistsAtPath:path])
        return nil;
    return path;
}

static NSString *CydiaNativeCompatibilityExecutionPackage(void) {
    const char *raw(getenv("CYDIA_NATIVE_COMPATIBILITY_EXECUTION_PACKAGE"));
    if (raw == NULL || raw[0] == '\0')
        return nil;
    NSString *package([NSString stringWithUTF8String:raw]);
    if (package == nil || [package length] > 1024)
        return nil;
    for (NSUInteger index(0); index != [package length]; ++index)
        if ([[NSCharacterSet controlCharacterSet] characterIsMember:[package characterAtIndex:index]])
            return nil;
    return package;
}

/* Optional, run-owned startup diagnostic.  Unlike the execution receipt this
 * path is intentionally overwrite-safe: each bounded attempt records the
 * latest package/session state without mutating Cydia's model or provider. */
static NSString *CydiaNativeCompatibilityExecutionDiagnosticPath(void) {
    NSString *path([[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_EXECUTION_DIAGNOSTIC_PATH"]);
    if (![path isKindOfClass:[NSString class]] || [path length] == 0 ||
        [path length] > 1024 || ![path hasPrefix:@"/"] ||
        [path rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound ||
        [[path stringByStandardizingPath] isEqualToString:path] == NO)
        return nil;
    NSString *parent([path stringByDeletingLastPathComponent]);
    BOOL directory(NO);
    if (![[NSFileManager defaultManager] fileExistsAtPath:parent isDirectory:&directory] || !directory)
        return nil;
    NSString *receipt(CydiaNativeCompatibilityExecutionEvidencePath());
    if (receipt != nil && [receipt isEqualToString:path]) return nil;
    return path;
}

static void CydiaNativeCompatibilityWriteExecutionDiagnostic(
    NSUInteger attempts, NSString *requestedPackage, BOOL packageFound,
    BOOL sessionActive, NSString *reason) {
    NSString *path(CydiaNativeCompatibilityExecutionDiagnosticPath());
    if (path == nil) return;
    NSDictionary *entry(@{
        @"attempt": @(attempts),
        @"requestedPackage": requestedPackage ?: [NSNull null],
        @"packageFound": @(packageFound),
        @"sessionActive": @(sessionActive),
        @"reason": reason ?: @"none",
    });
    [entry writeToFile:path atomically:YES];
}

/* The application/session diagnostic is opt-in and must not depend on a
 * syslog consumer keeping an untruncated live window open.  Keep its receipt
 * on the same run-owned path as the execution diagnostic, while refusing to
 * overwrite a separately requested execution receipt. */
static void CydiaNativeCompatibilityWriteApplicationDiagnostic(
    NSUInteger attempts, NSDictionary *result) {
    NSString *path(CydiaNativeCompatibilityExecutionDiagnosticPath());
    if (path == nil || ![result isKindOfClass:[NSDictionary class]])
        return;
    NSMutableDictionary *entry([result mutableCopy]);
    [entry setObject:@(attempts) forKey:@"diagnosticAttempt"];
    NSDictionary *environment([[NSProcessInfo processInfo] environment]);
    for (NSString *key in @[
        @"CYDIA_NATIVE_COMPATIBILITY_EXPECTED_SOURCE_COMMIT",
        @"CYDIA_NATIVE_COMPATIBILITY_EXPECTED_SOURCE_TREE_SHA256",
        @"CYDIA_NATIVE_COMPATIBILITY_EXPECTED_VERSION"]) {
        id value([environment objectForKey:key]);
        [entry setObject:value ?: [NSNull null] forKey:key];
    }
    [entry writeToFile:path atomically:YES];
}

static NSArray *CydiaNativeCompatibilityExecutionArguments(
    CydiaLegacyUICompatibilitySignature *signature) {
    if (signature == nil || [signature dispatchMode] != CydiaLegacyUIDispatchModeSynchronous ||
        [[signature argumentKinds] count] != 0)
        return nil;
    return @[];
}

static NSString *CydiaNativeCompatibilityExecutionShape(id value) {
    if (value == nil || value == [CydiaLegacyUIUndefinedValue value]) return @"undefined";
    if (value == [NSNull null]) return @"null";
    if ([value isKindOfClass:[NSString class]]) return @"string";
    if ([value isKindOfClass:[NSNumber class]]) return @"number";
    if ([value isKindOfClass:[NSArray class]]) return @"array";
    if ([value isKindOfClass:[NSDictionary class]]) return @"dictionary";
    if ([value isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]]) return @"snapshot";
    return NSStringFromClass([value class]) ?: @"object";
}

static NSDictionary *CydiaNativeCompatibilityExecutionRow(
    CydiaLegacyBridgeMember *member, id value, BOOL invoked, NSString *reason) {
    return @{
        @"identity": [NSString stringWithFormat:@"%@|%@|%@", [member scope],
            CydiaLegacyBridgeMemberKindName([member kind]), [member name]],
        @"scope": [member scope] ?: @"none",
        @"kind": CydiaLegacyBridgeMemberKindName([member kind]),
        @"name": [member name] ?: @"",
        @"family": CydiaLegacyBridgeOperationFamilyName([member family]),
        @"invoked": @(invoked),
        @"dispatchStatus": invoked ? @"dispatched_synchronous" : @"not_dispatched_execution_boundary",
        @"resultShape": invoked ? CydiaNativeCompatibilityExecutionShape(value) : @"not_observed",
        @"reason": reason ?: @"none",
    };
}

static void CydiaNativeCompatibilityWriteExecutionEvidenceIfRequested(
    CydiaLegacyUICompatibilityNativeSession *packageSession, Package *package) {
    NSString *path(CydiaNativeCompatibilityExecutionEvidencePath());
    if (path == nil || packageSession == nil || ![packageSession isActive] || package == nil)
        return;
    NSArray *signatures(CydiaLegacyUICompatibilitySignatures());
    NSMutableDictionary *rows([NSMutableDictionary dictionary]);
    NSMutableDictionary *values([NSMutableDictionary dictionary]);
    for (CydiaLegacyUICompatibilitySignature *signature in signatures) {
        CydiaLegacyBridgeMember *member([signature member]);
        if (member == nil || ![[member scope] isEqualToString:@"Package"])
            continue;
        NSString *identity([NSString stringWithFormat:@"%@|%@|%@", [member scope],
            CydiaLegacyBridgeMemberKindName([member kind]), [member name]]);
        NSArray *arguments(CydiaNativeCompatibilityExecutionArguments(signature));
        if (arguments == nil) {
            [rows setObject:CydiaNativeCompatibilityExecutionRow(member, nil, NO,
                @"nonzero-arguments-or-non-synchronous") forKey:identity];
            continue;
        }
        id value([packageSession invokeScope:[member scope] memberKind:[member kind]
            memberName:[member name] arguments:arguments targetOrigin:nil]);
        BOOL invoked(value != [CydiaLegacyUIUndefinedValue value]);
        if (invoked) [values setObject:value ?: [NSNull null] forKey:identity];
        [rows setObject:CydiaNativeCompatibilityExecutionRow(member, value, invoked,
            invoked ? @"none" : @"undefined-result") forKey:identity];
    }

    NSMutableArray *snapshotTargets([NSMutableArray arrayWithCapacity:3]);
    for (NSString *key in @[@"Package|attribute|relations",
        @"Package|attribute|author", @"Package|attribute|maintainer"]) {
        id target([values objectForKey:key]);
        if (target != nil)
            [snapshotTargets addObject:target];
    }
    for (id target in snapshotTargets) {
        if ([target isKindOfClass:[NSArray class]]) {
            for (id relation in (NSArray *)target) {
                NSArray *nested(@[[relation isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]] ? relation : [NSNull null]]);
                (void)nested;
                if (![relation isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]]) continue;
                id relationClauses([packageSession invokeSnapshot:relation
                    memberName:@"clauses" arguments:@[]]);
                for (CydiaLegacyBridgeMember *member in [CydiaLegacyBridgeMembers() filteredArrayUsingPredicate:
                    [NSPredicate predicateWithBlock:^BOOL(CydiaLegacyBridgeMember *candidate, NSDictionary *_) {
                        return [[candidate scope] isEqualToString:@"CydiaRelation"] &&
                            [candidate kind] == CydiaLegacyBridgeMemberKindAttribute;
                    }]]) {
                    id value([packageSession invokeSnapshot:relation memberName:[member name] arguments:@[]]);
                    NSString *identity([NSString stringWithFormat:@"%@|%@|%@", [member scope],
                        CydiaLegacyBridgeMemberKindName([member kind]), [member name]]);
                    [rows setObject:CydiaNativeCompatibilityExecutionRow(member, value,
                        value != [CydiaLegacyUIUndefinedValue value], @"bound-snapshot") forKey:identity];
                }
                if ([relationClauses isKindOfClass:[NSArray class]]) {
                    for (id clause in (NSArray *)relationClauses) {
                        if (![clause isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]]) continue;
                        id clauseVersion([packageSession invokeSnapshot:clause
                            memberName:@"version" arguments:@[]]);
                        for (CydiaLegacyBridgeMember *member in CydiaLegacyBridgeMembers()) {
                            if (![[member scope] isEqualToString:@"CydiaClause"] ||
                                [member kind] != CydiaLegacyBridgeMemberKindAttribute) continue;
                            id value([packageSession invokeSnapshot:clause memberName:[member name] arguments:@[]]);
                            NSString *identity([NSString stringWithFormat:@"%@|%@|%@", [member scope],
                                CydiaLegacyBridgeMemberKindName([member kind]), [member name]]);
                            [rows setObject:CydiaNativeCompatibilityExecutionRow(member, value,
                                value != [CydiaLegacyUIUndefinedValue value], @"bound-snapshot") forKey:identity];
                        }
                        if ([clauseVersion isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]]) {
                            for (CydiaLegacyBridgeMember *member in CydiaLegacyBridgeMembers()) {
                                if (![[member scope] isEqualToString:@"CydiaOperation"] ||
                                    [member kind] != CydiaLegacyBridgeMemberKindAttribute) continue;
                                id value([packageSession invokeSnapshot:clauseVersion
                                    memberName:[member name] arguments:@[]]);
                                NSString *identity([NSString stringWithFormat:@"%@|%@|%@", [member scope],
                                    CydiaLegacyBridgeMemberKindName([member kind]), [member name]]);
                                [rows setObject:CydiaNativeCompatibilityExecutionRow(member, value,
                                    value != [CydiaLegacyUIUndefinedValue value], @"bound-snapshot") forKey:identity];
                            }
                        }
                    }
                }
            }
        } else if ([target isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]]) {
            for (CydiaLegacyBridgeMember *member in CydiaLegacyBridgeMembers()) {
                if (![[member scope] isEqualToString:@"MIMEAddress"] ||
                    [member kind] != CydiaLegacyBridgeMemberKindAttribute) continue;
                id value([packageSession invokeSnapshot:target memberName:[member name] arguments:@[]]);
                NSString *identity([NSString stringWithFormat:@"%@|%@|%@", [member scope],
                    CydiaLegacyBridgeMemberKindName([member kind]), [member name]]);
                [rows setObject:CydiaNativeCompatibilityExecutionRow(member, value,
                    value != [CydiaLegacyUIUndefinedValue value], @"bound-snapshot") forKey:identity];
            }
        }
    }
    NSDictionary *receipt(@{ @"schema": @1, @"mode": @"canonical-package-execution",
        @"packageIdentity": [[package id] description] ?: @"", @"rows": rows,
        @"rowCount": @([rows count]), @"note": @"Only synchronous canonical package and bound immutable snapshot reads are invoked." });
    NSData *data([NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:nil]);
    if (data != nil) [data writeToFile:path options:NSDataWritingAtomic error:nil];
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

/* This probe is never enabled by the ordinary read-only diagnostic.  Keep the
 * mode allowlist literal so a launch environment cannot turn the app into a
 * general-purpose metadata writer.  Each metadata mode or operation issues
 * one fixed request; the native provider still owns validation, confirmation,
 * and commit gating.
 */
static NSString *CydiaNativeCompatibilityMutationDiagnosticMode(void) {
    NSString *mode([[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_MUTATION_DIAGNOSTIC"]);
    if ([mode isEqualToString:@"cancel"] ||
        [mode isEqualToString:@"set"] ||
        [mode isEqualToString:@"remove"])
        return mode;
    return nil;
}

/* Explicit runtime operation lane. The shared parser accepts only fixed
 * names, with inert targets/arguments selected below. Normal launches and
 * the metadata cancel/set/remove diagnostic remain unchanged. */
static NSString *CydiaNativeCompatibilityMutationDiagnosticOperation(void) {
    return CydiaNativeCompatibilityMutationDiagnosticOperationForValue(
        [[[NSProcessInfo processInfo] environment]
            objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_MUTATION_OPERATION"]);
}

static NSString *CydiaNativeCompatibilityMutationDiagnosticSourceKey(void) {
    /* Section mutations need a component-based suite.  APT rejects a flat
     * ./ source once addSection appends a component to it.  Keep this key
     * paired with addSource below; addTrivialSource remains a separate flat
     * source so both public forms are exercised without malformed input. */
    return [NSString stringWithFormat:@"deb:%@:%@",
        CydiaNativeCompatibilityMutationDiagnosticSourceURL(),
        CydiaNativeCompatibilityMutationDiagnosticDistribution()];
}

/* The revocation probe is an explicit, exact-value test switch.  It is not a
 * compatibility API and cannot select a target or operation; it only makes
 * the fixed installed-runtime operation lane invalidate its app session
 * after presenting the native confirmation. */
static BOOL CydiaNativeCompatibilityMutationDiagnosticRevokeBeforeConfirm(void) {
    return [[[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_MUTATION_REVOKE_BEFORE_CONFIRM"]
        isEqualToString:@"1"];
}

static NSString *CydiaNativeCompatibilityMutationDiagnosticRevokeBoundary(void) {
    NSString *boundary([[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_MUTATION_REVOKE_BOUNDARY"]);
    for (NSString *allowed in @[@"session", @"target", @"presenter"])
        if ([boundary isEqualToString:allowed])
            return boundary;
    return nil;
}

static void CydiaNativeCompatibilityMutationDiagnosticRevokeAuthority(
    CydiaLegacyUICompatibilityNativeSession *session,
    CydiaLegacyUICompatibilityNativeProvider *provider, NSString *operation) {
    NSString *boundary(CydiaNativeCompatibilityMutationDiagnosticRevokeBoundary());
    if (CydiaNativeCompatibilityMutationDiagnosticRevokeBeforeConfirm() ||
        [boundary isEqualToString:@"session"]) {
        NSLog(@"Cydia native compatibility mutation diagnostic: revoking session after presentation operation=%@", operation);
        [session invalidate];
    } else if ([boundary isEqualToString:@"target"] ||
               [boundary isEqualToString:@"presenter"]) {
        NSLog(@"Cydia native compatibility mutation diagnostic: revoking %@ authority after presentation operation=%@", boundary, operation);
        [provider revokeAuthorityForDiagnosticBoundary:boundary];
    }
}

static NSString *CydiaNativeCompatibilityMutationDiagnosticKey(void) {
    return CydiaNativeCompatibilityMutationDiagnosticMetadataKey();
}

@implementation Cydia (Data)
- (void) beginUpdate {
    [tabbar_ beginUpdate];
}

- (void) cancelUpdate {
    [tabbar_ cancelUpdate];
}

- (bool) requestUpdate {
    // APT reports the state of the repositories actually being refreshed.
    [self beginUpdate];
    return true;
}

- (BOOL) updating {
    return [tabbar_ updating];
}

- (void) _loaded {
    if ([broken_ count] != 0) {
        [self showPackageRecovery:broken_];
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
    [self consumeLegacyUICompatibilityMatrixEvidenceIfRequested];
    [self consumeLegacyUICompatibilityExecutionEvidenceIfRequested];
    [self consumeLegacyUICompatibilityApplicationSessionIfRequested];
    [self consumeLegacyUICompatibilityMutationDiagnosticIfRequested];
}

- (void) consumeLegacyUICompatibilityExecutionEvidenceIfRequested {
    if (CydiaNativeCompatibilityExecutionEvidencePath() == nil ||
        legacyCompatibilityExecutionEvidenceConsumed_)
        return;
    /* A refresh can keep the provider/session unavailable for tens of
     * seconds while Cydia finishes its post-launch database work.  Keep this
     * retry bounded, but long enough to cover that startup window. */
    if (++legacyCompatibilityExecutionEvidenceAttempts_ > 30)
        return;
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:
            @selector(consumeLegacyUICompatibilityExecutionEvidenceIfRequested)
            withObject:nil waitUntilDone:NO];
        return;
    }
    Package *canonicalPackage(nil);
    Package *fallbackPackage(nil);
    NSString *requestedPackage(CydiaNativeCompatibilityExecutionPackage());
    if (requestedPackage != nil) {
        for (id candidate in [database_ packages])
            if (object_getClass(candidate) == [Package class] &&
                [[candidate id] isEqualToString:requestedPackage]) {
                canonicalPackage = (Package *)candidate;
                break;
            }
    }
    for (id candidate in [database_ packages])
        if (canonicalPackage == nil && object_getClass(candidate) == [Package class]) {
            if (requestedPackage != nil && ![[candidate id] isEqualToString:requestedPackage])
                continue;
            if (fallbackPackage == nil)
                fallbackPackage = (Package *)candidate;
            [(Package *)candidate parse];
            NSArray *relations([(Package *)candidate relations]);
            BOOL hasClause(NO);
            if ([relations isKindOfClass:[NSArray class]])
                for (id relation in relations)
                    if ([relation isKindOfClass:NSClassFromString(@"CydiaRelation")] &&
                        [[relation clauses] isKindOfClass:[NSArray class]] &&
                        [[relation clauses] count] != 0) {
                        hasClause = YES;
                        break;
                    }
            if (requestedPackage != nil || hasClause) {
                canonicalPackage = (Package *)candidate;
                break;
            }
        }
    if (canonicalPackage == nil)
        canonicalPackage = fallbackPackage;
    if (canonicalPackage == nil) {
        CydiaNativeCompatibilityWriteExecutionDiagnostic(
            legacyCompatibilityExecutionEvidenceAttempts_, requestedPackage,
            NO, NO, @"package-not-found");
        [self performSelector:@selector(consumeLegacyUICompatibilityExecutionEvidenceIfRequested)
            withObject:nil afterDelay:2.0];
        return;
    }
    CydiaLegacyUICompatibilityNativeSession *session(
        [self legacyUICompatibilitySessionForPackage:canonicalPackage presenter:tabbar_]);
    if (session == nil || ![session isActive]) {
        CydiaNativeCompatibilityWriteExecutionDiagnostic(
            legacyCompatibilityExecutionEvidenceAttempts_, requestedPackage,
            YES, NO, @"session-inactive");
        /* Provider activation can lag the first post-load callback.  Retry
         * within the bounded startup window instead of silently losing the
         * opt-in receipt while the canonical presenter/session settles. */
        [self performSelector:@selector(consumeLegacyUICompatibilityExecutionEvidenceIfRequested)
            withObject:nil afterDelay:1.0];
        return;
    }
    CydiaNativeCompatibilityWriteExecutionDiagnostic(
        legacyCompatibilityExecutionEvidenceAttempts_, requestedPackage,
        YES, YES, @"session-active-dispatching");
    legacyCompatibilityExecutionEvidenceConsumed_ = YES;
    CydiaNativeCompatibilityWriteExecutionEvidenceIfRequested(session, canonicalPackage);
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
    if (recently || loaded_ || ManualRefresh) {
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

    NSUInteger diagnosticAttempt(++legacyCompatibilityApplicationDiagnosticAttempts_);
    if (diagnosticAttempt > 30) {
        NSDictionary *result(@{
            @"applicationSession": @NO,
            @"reason": @"application-session-unavailable-exhausted",
        });
        CydiaNativeCompatibilityWriteApplicationDiagnostic(
            diagnosticAttempt, result);
        NSLog(@"Cydia native compatibility diagnostic: %@", result);
        return;
    }

    /* Activation can precede the asynchronous database load.  Do not retain
     * an app session or emit a partial receipt while canonical model objects
     * are still absent; retry within the same bounded startup budget. */
    if ([[database_ packages] count] == 0 || [[database_ sources] count] == 0) {
        [self performSelector:@selector(
            consumeLegacyUICompatibilityApplicationSessionIfRequested)
            withObject:nil afterDelay:1.0];
        return;
    }

    CydiaLegacyUICompatibilityNativeSession *applicationSession(
        [self legacyUICompatibilitySessionForApplicationWithPresenter:tabbar_]);
    if (applicationSession == nil) {
        NSDictionary *result(@{
            @"applicationSession": @NO,
            @"reason": @"application-session-unavailable",
        });
        CydiaNativeCompatibilityWriteApplicationDiagnostic(
            diagnosticAttempt, result);
        NSLog(@"Cydia native compatibility diagnostic: %@", result);
        [self performSelector:@selector(
            consumeLegacyUICompatibilityApplicationSessionIfRequested)
            withObject:nil afterDelay:1.0];
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
    if (CydiaNativeCompatibilityB17FixtureRequested())
        metadataProbeKey = [CydiaNativeCompatibilityMutationDiagnosticMetadataKey() copy];

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
    canonicalPackage = CydiaNativeCompatibilityMutationDiagnosticPackage(database_);
    if (canonicalPackage == nil)
        for (id candidate in [database_ packages])
            if (object_getClass(candidate) == [Package class]) {
                canonicalPackage = (Package *)candidate;
                break;
            }
    canonicalPackageIdentity = [[canonicalPackage id] copy];
    canonicalPackageName = [[canonicalPackage name] copy];

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

    BOOL packageRead(NO);
    if (canonicalPackage != nil) {
        CydiaLegacyUICompatibilityNativeSession *packageSession(
            [self legacyUICompatibilitySessionForPackage:canonicalPackage
            presenter:tabbar_]);
        id packageIdentity([packageSession invokeScope:@"Package"
            memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"id"
            arguments:@[] targetOrigin:nil]);
        packageRead = [packageIdentity isKindOfClass:[NSString class]] &&
            [packageIdentity length] != 0;

    }

    Source *canonicalSource(nil);
    if (CydiaNativeCompatibilityB17FixtureRequested())
        canonicalSource = [database_ sourceWithKey:CydiaNativeCompatibilityMutationDiagnosticSourceKey()];
    if (canonicalSource == nil)
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

    BOOL sourceInvalidationDenied(NO);
    if (sourceSession != nil && [sourceSession isActive]) {
        [sourceSession invalidate];
        id invalidatedSourceValue([sourceSession invokeScope:@"Source"
            memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
            arguments:@[] targetOrigin:nil]);
        sourceInvalidationDenied = ![sourceSession isActive] &&
            invalidatedSourceValue == [CydiaLegacyUIUndefinedValue value] &&
            [sourceSession lastDenialReason] ==
                CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability;
    }

    NSString *unknownSourceRoute(CydiaNativeCompatibilityB17FixtureRequested() ?
        @"cydia://sources/deb%3Ahttps%3A%2F%2Fnative-compatibility.invalid%2F%3A.%2F" :
        @"cydia://sources/deb%3Ahttps%3A%2F%2Fnative-compatibility-diagnostic.invalid%2F%3A.%2F");
    BOOL unknownSourceRouteDenied(![applicationSession handoffRouteURL:
        [NSURL URLWithString:unknownSourceRoute]]);

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
    NSMutableDictionary *result([@{
        @"reason": @"session-active-dispatching",
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
        @"sourceSessionInvalidationDenied": @(sourceInvalidationDenied),
        @"unknownSourceRouteDenied": @(unknownSourceRouteDenied),
        @"invalidationDenied": @(invalidationDenied),
    } mutableCopy]);
    SourcesController *sourceController([[SourcesController alloc]
        initWithDatabase:database_]);
    NSDictionary *sourceControllerResult(
        [sourceController cydiaNativeCompatibilitySourceSessionDiagnosticWithDelegate:self]);
    if ([sourceControllerResult isKindOfClass:[NSDictionary class]])
        [result addEntriesFromDictionary:sourceControllerResult];
    [result addEntriesFromDictionary:CydiaNativeCompatibilityLifetimeDiagnostic(
        self, tabbar_, database_, metadataProbeKey)];
    CydiaNativeCompatibilityWriteApplicationDiagnostic(
        diagnosticAttempt, result);
    NSLog(@"Cydia native compatibility diagnostic: %@", result);
}

- (void) syncData {
    /* Source changes are explicit. Saving appearance or other app preferences
     * must never rewrite the bootstrap's repository files. */
    if (!CydiaWriteSources()) {
        [self addProgressEventOnMainThread:[CydiaProgressEvent
            eventWithMessage:UCLocalize("ERROR") ofType:@"Error"]
            forTask:UCLocalize("UPDATING_SOURCES")];
        return;
    }
    [self _saveConfig];
    [self detachNewProgressSelector:@selector(update_) toTarget:self forController:nil title:@"UPDATING_SOURCES"];
}

- (BOOL) legacyUICompatibilityMutationDiagnosticRequested {
    return CydiaNativeCompatibilityMutationDiagnosticMode() != nil ||
        CydiaNativeCompatibilityMutationDiagnosticOperation() != nil;
}

/* Separate fixed-input runtime probe. Source/metadata writes require their
 * native alert; package requests enter the existing transaction confirmation.
 * One request per launch, with no accepted request retained across lifetimes. */
- (void) consumeLegacyUICompatibilityMutationDiagnosticIfRequested {
    NSString *mode(CydiaNativeCompatibilityMutationDiagnosticMode());
    NSString *operation(CydiaNativeCompatibilityMutationDiagnosticOperation());
    if (mode == nil && operation == nil || legacyCompatibilityMutationDiagnosticConsumed_)
        return;
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:
            @selector(consumeLegacyUICompatibilityMutationDiagnosticIfRequested)
            withObject:nil waitUntilDone:NO];
        return;
    }
    CydiaLegacyUICompatibilityNativeSession *session(
        [self legacyUICompatibilitySessionForApplicationWithPresenter:tabbar_]);
    if (session == nil || ![session isActive]) {
        NSLog(@"Cydia native compatibility mutation diagnostic: session unavailable mode=%@", mode);
        return;
    }
    /* Do not consume the one-shot gate until the canonical app session is
     * actually available.  Early post-load callbacks can precede provider
     * attachment; a later _loaded callback must be able to retry once. */
    legacyCompatibilityMutationDiagnosticConsumed_ = YES;

    if (operation != nil) {
        NSString *scope(@"CydiaObject");
        id target(self);
        NSArray *arguments(@[]);
        NSString *member(operation);
        BOOL packageMutation([operation hasPrefix:@"Package."] ||
            [operation isEqualToString:@"CydiaObject.installPackages"]);
        Package *canonicalPackage(packageMutation ?
            CydiaNativeCompatibilityMutationDiagnosticPackage(database_) : nil);
        if (packageMutation && canonicalPackage == nil) {
            CydiaNativeCompatibilityWriteApplicationDiagnostic(1, @{
                @"mode": @"fixed-package-mutation-boundary", @"operation": operation,
                @"processID": @((unsigned int)getpid()), @"boundaryAttempted": @NO,
                @"reason": @"fixed-fixture-not-found",
            });
            return;
        }
        if ([operation hasPrefix:@"Package."]) {
            session = [self legacyUICompatibilitySessionForPackage:canonicalPackage
                presenter:tabbar_];
            if (session == nil || ![session isActive])
                return;
            scope = @"Package";
            target = canonicalPackage;
            member = [operation substringFromIndex:[@"Package." length]];
        } else if ([operation hasPrefix:@"Source."]) {
            Source *canonicalSource(nil);
            if (database_ != nil)
                for (id candidate in [database_ sources])
                    if (object_getClass(candidate) == [Source class] &&
                        CydiaCanEditManagedSources() &&
                        CydiaManagedSourceKeyIsOwned([(Source *)candidate key]) &&
                        [[(Source *)candidate key]
                            isEqualToString:CydiaNativeCompatibilityMutationDiagnosticSourceKey()]) {
                        canonicalSource = (Source *)candidate;
                        break;
                    }
            if (canonicalSource == nil) {
                NSLog(@"Cydia native compatibility mutation diagnostic: source target unavailable operation=%@", operation);
                return;
            }
            session = [self legacyUICompatibilitySessionForSource:canonicalSource presenter:tabbar_];
            if (session == nil || ![session isActive]) {
                NSLog(@"Cydia native compatibility mutation diagnostic: source session unavailable operation=%@", operation);
                return;
            }
            scope = @"Source";
            target = canonicalSource;
            member = [operation substringFromIndex:[@"Source." length]];
            if ([member isEqualToString:@"addSection"] ||
                [member isEqualToString:@"removeSection"])
                arguments = @[CydiaNativeCompatibilityMutationDiagnosticSection()];
        } else {
            member = [operation substringFromIndex:[@"CydiaObject." length]];
            if ([member isEqualToString:@"addTrivialSource"])
                arguments = @[CydiaNativeCompatibilityMutationDiagnosticSourceURL()];
            else if ([member isEqualToString:@"addSource"])
                arguments = @[
                    CydiaNativeCompatibilityMutationDiagnosticSourceURL(),
                    CydiaNativeCompatibilityMutationDiagnosticDistribution(), @[@"main"]
                ];
            else if ([member isEqualToString:@"installPackages"])
                arguments = @[@[canonicalPackage]];
        }
        if (packageMutation && !CydiaNativeCompatibilityMutationDiagnosticPreparePackage(
                operation, canonicalPackage))
            return;
        NSString *packageModeBefore(packageMutation ? [canonicalPackage mode] : nil);
        NSUInteger entriesBefore([session executorEntryCount]);
        NSUInteger rejectionsBefore([session denialCount]);
        id result([session invokeScope:scope
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:member
            arguments:arguments targetOrigin:nil]);
        if (packageMutation)
            CydiaNativeCompatibilityWriteApplicationDiagnostic(1,
                CydiaNativeCompatibilityPackageMutationObservation(operation, session,
                    canonicalPackage, packageModeBefore, entriesBefore, rejectionsBefore, result));
        CydiaNativeCompatibilityMutationDiagnosticRevokeAuthority(
            session, legacyCompatibilityProvider_, operation);
        NSLog(@"Cydia native compatibility mutation diagnostic: operation=%@ scope=%@ member=%@ result=%@ denial=%lu",
            operation, scope, member, result,
            (unsigned long)[session lastDenialReason]);
        return;
    }

    NSString *key(CydiaNativeCompatibilityMutationDiagnosticKey());
    id existing([session invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getMetadataValue"
        arguments:@[key] targetOrigin:nil]);
    BOOL defined(existing != nil && existing != [NSNull null] &&
        existing != [CydiaLegacyUIUndefinedValue value]);
    if ([mode isEqualToString:@"set"] && defined) {
        NSLog(@"Cydia native compatibility mutation diagnostic: key already defined mode=%@ key=%@", mode, key);
        return;
    }
    if ([mode isEqualToString:@"remove"] && !defined) {
        NSLog(@"Cydia native compatibility mutation diagnostic: key absent mode=%@ key=%@", mode, key);
        return;
    }

    id value([mode isEqualToString:@"remove"] ? [NSNull null] :
        CydiaNativeCompatibilityMutationDiagnosticValue());
    id result([session invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"setMetadataValue"
        arguments:@[key, value] targetOrigin:nil]);
    BOOL requestAccepted([session lastDenialReason] ==
        CydiaLegacyUICompatibilityNativeDenialReasonNone);
    CydiaNativeCompatibilityMutationDiagnosticRevokeAuthority(
        session, legacyCompatibilityProvider_, @"CydiaObject.setMetadataValue");
    NSLog(@"Cydia native compatibility mutation diagnostic: mode=%@ key=%@ definedBefore=%d requestAccepted=%d result=%@ denial=%lu",
        mode, key, defined, requestAccepted, result,
        (unsigned long)[session lastDenialReason]);
}

- (void) addSource:(NSDictionary *) source {
    NSString *draft(CydiaSourceDraftForLegacySource(source));
    if (draft == nil || !CydiaCanEditSources()) return;
    SourcesController *controller([[SourcesController alloc] initWithDatabase:database_]);
    [controller setDelegate:self];
    [tabbar_ setUnselectedViewController:controller];
    // The native destination choice must be presented after the controller
    // has joined its navigation hierarchy.
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller showAddSourceDefinitionPrompt:draft];
    });
}

- (void) addSource:(NSString *)href withDistribution:(NSString *)distribution andSections:(NSArray *)sections {
    [self addSource:@{@"Type":@"deb", @"URI":href ?: @"",
        @"Distribution":distribution ?: @"", @"Sections":sections ?: @[]}];
}

// Acceptance opens a reviewed native draft; it does not write an APT file.
- (BOOL) addTrivialSource:(NSString *)href {
    NSDictionary *source(@{@"Type":@"deb", @"URI":href ?: @"", @"Distribution":@"./", @"Sections":@[]});
    if (!CydiaCanEditSources() || CydiaSourceDraftForLegacySource(source) == nil) return NO;
    [self addSource:source];
    return YES;
}

@end
