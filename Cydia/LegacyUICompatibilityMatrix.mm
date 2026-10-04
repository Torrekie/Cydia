/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/Application.h"
#include "Cydia/Database.h"
#include "Cydia/LegacyUICompatibilityNativeProvider.h"
#include "Cydia/LegacyUICompatibilityRuntimeEvidence.h"
#include "Cydia/Package.h"
#include "Cydia/Source.h"
#include <objc/runtime.h>

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

/* The complete matrix is a separate, explicitly opt-in installed boundary
 * probe.  It must never be confused with the decision-only receipt or the
 * smaller Package execution lane.  Read-only members are invoked on
 * the canonical target sessions; denied members are sent through the same
 * native boundary and must return the typed unavailable value with zero
 * executor entries. Retired scopes have no production target; exercise their
 * rejection at the real application session's compatibility service without
 * creating a retired target or granting a new scope. Allowed mutations remain
 * undispatched and require their separate Cancel/Confirm runtime receipts. */
static NSString *CydiaNativeCompatibilityMatrixPath(void) {
    NSString *path([[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_MATRIX_PATH"]);
    if (![path isKindOfClass:[NSString class]] || [path length] == 0 ||
        [path length] > 1024 || ![path hasPrefix:@"/"] ||
        [path rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound ||
        ![[path stringByStandardizingPath] isEqualToString:path])
        return nil;
    NSString *parent([path stringByDeletingLastPathComponent]);
    BOOL directory(NO);
    if (![[NSFileManager defaultManager] fileExistsAtPath:parent isDirectory:&directory] ||
        !directory || [[NSFileManager defaultManager] fileExistsAtPath:path])
        return nil;
    return path;
}

static NSArray *CydiaNativeCompatibilityMatrixArguments(
    CydiaLegacyUICompatibilitySignature *signature) {
    if (signature == nil)
        return @[];
    NSMutableArray *arguments([NSMutableArray arrayWithCapacity:
        [[signature argumentKinds] count]]);
    for (NSNumber *number in [signature argumentKinds]) {
        CydiaLegacyUIArgumentKind kind((CydiaLegacyUIArgumentKind)
            [number unsignedIntegerValue]);
        id argument([NSNull null]);
        switch (kind) {
            case CydiaLegacyUIArgumentKindString:
                argument = @"native-compatibility-matrix"; break;
            case CydiaLegacyUIArgumentKindOptionalString:
                argument = [NSNull null]; break;
            case CydiaLegacyUIArgumentKindNumber:
                argument = @0; break;
            case CydiaLegacyUIArgumentKindOptionalNumber:
                argument = [NSNull null]; break;
            case CydiaLegacyUIArgumentKindBooleanLike:
                argument = @NO; break;
            case CydiaLegacyUIArgumentKindOptionalBooleanLike:
                argument = [NSNull null]; break;
            case CydiaLegacyUIArgumentKindSequence:
                argument = @[]; break;
            case CydiaLegacyUIArgumentKindOpaque:
                argument = @"native-compatibility-matrix"; break;
            case CydiaLegacyUIArgumentKindOptionalAny:
                argument = [NSNull null]; break;
            case CydiaLegacyUIArgumentKindURLString:
                argument = @"https://native-compatibility-diagnostic.invalid/"; break;
            case CydiaLegacyUIArgumentKindMetadataKey:
                argument = @"native.compatibility.matrix"; break;
            case CydiaLegacyUIArgumentKindOptionalPropertyList:
                argument = [NSNull null]; break;
        }
        [arguments addObject:argument];
    }
    return [arguments copy];
}

static BOOL CydiaNativeCompatibilityMatrixExpectedAllowed(
    CydiaLegacyBridgeMember *member) {
    if (member == nil)
        return NO;
    CydiaLegacyBridgeOperationFamily family([member family]);
    if (family == CydiaLegacyBridgeOperationFamilySensitive ||
        family == CydiaLegacyBridgeOperationFamilyChrome ||
        family == CydiaLegacyBridgeOperationFamilyClipboard ||
        family == CydiaLegacyBridgeOperationFamilyRetired)
        return NO;
    if (family == CydiaLegacyBridgeOperationFamilySession &&
        ![[member name] isEqualToString:@"getSessionValue"])
        return NO;
    CydiaLegacyBridgeAccessRequirement requirement([member trustedLegacyRequirement]);
    return requirement != CydiaLegacyBridgeAccessRequirementDenied &&
        requirement != CydiaLegacyBridgeAccessRequirementRetired;
}

static NSString *CydiaNativeCompatibilityMatrixDenialName(
    CydiaLegacyUICompatibilityNativeDenialReason reason) {
    switch (reason) {
        case CydiaLegacyUICompatibilityNativeDenialReasonNone: return @"none";
        case CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability: return @"invalid-capability";
        case CydiaLegacyUICompatibilityNativeDenialReasonInvalidContext: return @"invalid-context";
        case CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget: return @"invalid-target";
        case CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember: return @"unsupported-member";
        case CydiaLegacyUICompatibilityNativeDenialReasonMissingProvider: return @"missing-provider";
        case CydiaLegacyUICompatibilityNativeDenialReasonMissingPresenter: return @"missing-presenter";
        case CydiaLegacyUICompatibilityNativeDenialReasonAlreadyRequested: return @"already-requested";
        case CydiaLegacyUICompatibilityNativeDenialReasonRouteRejected: return @"route-rejected";
        case CydiaLegacyUICompatibilityNativeDenialReasonRouterUnavailable: return @"router-unavailable";
    }
    return @"unknown";
}

@implementation Cydia (MatrixEvidence)
- (void) consumeLegacyUICompatibilityMatrixEvidenceIfRequested {
    NSString *path(CydiaNativeCompatibilityMatrixPath());
    if (path == nil || legacyCompatibilityMatrixEvidenceConsumed_)
        return;
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:
            @selector(consumeLegacyUICompatibilityMatrixEvidenceIfRequested)
            withObject:nil waitUntilDone:NO];
        return;
    }
    if (database_ == nil || [[database_ packages] count] == 0 ||
        [[database_ sources] count] == 0)
        return;

    Package *canonicalPackage(nil);
    for (id candidate in [database_ packages])
        if (object_getClass(candidate) == [Package class]) {
            canonicalPackage = (Package *)candidate;
            break;
        }
    Source *canonicalSource(nil);
    for (id candidate in [database_ sources])
        if (object_getClass(candidate) == [Source class]) {
            canonicalSource = (Source *)candidate;
            break;
        }
    if (canonicalPackage == nil || canonicalSource == nil)
        return;

    CydiaLegacyUICompatibilityNativeSession *applicationSession(
        [self legacyUICompatibilitySessionForApplicationWithPresenter:tabbar_]);
    CydiaLegacyUICompatibilityNativeSession *renderingSession(
        [self respondsToSelector:
            @selector(legacyUICompatibilitySessionForRenderingWithPresenter:)] ?
        [self legacyUICompatibilitySessionForRenderingWithPresenter:tabbar_] : nil);
    CydiaLegacyUICompatibilityNativeSession *packageSession(
        [self legacyUICompatibilitySessionForPackage:canonicalPackage presenter:tabbar_]);
    CydiaLegacyUICompatibilityNativeSession *sourceSession(
        [self legacyUICompatibilitySessionForSource:canonicalSource presenter:tabbar_]);
    NSDictionary *evidenceDictionary(@{ @"mode": @"installed-matrix",
        @"caller": @"trusted-in-process" });
    CydiaLegacyUICompatibilityNativeSession *dictionarySession(
        legacyCompatibilityCaller_ == nil ? nil :
        [legacyCompatibilityCaller_ sessionForScope:@"NSDictionary"
            target:evidenceDictionary packageIdentity:nil sourceKey:nil presenter:tabbar_]);

    NSMutableDictionary *sessions([NSMutableDictionary dictionary]);
    if (applicationSession != nil) [sessions setObject:applicationSession forKey:@"CydiaObject"];
    if (renderingSession != nil) [sessions setObject:renderingSession forKey:@"CyteObject"];
    if (packageSession != nil) [sessions setObject:packageSession forKey:@"Package"];
    if (sourceSession != nil) [sessions setObject:sourceSession forKey:@"Source"];
    if (dictionarySession != nil) [sessions setObject:dictionarySession forKey:@"NSDictionary"];

    /* Obtain one canonical immutable snapshot chain from the real Package.
     * No snapshot is constructed from environment data or by calling a
     * selector; the provider remains the sole snapshot factory. */
    NSMutableDictionary *snapshots([NSMutableDictionary dictionary]);
    id relations([packageSession invokeScope:@"Package"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"relations"
        arguments:@[] targetOrigin:nil]);
    if ([relations isKindOfClass:[NSArray class]]) {
        for (id relation in (NSArray *)relations)
            if ([relation isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]]) {
                [snapshots setObject:relation forKey:@"CydiaRelation"];
                id clauses([packageSession invokeSnapshot:relation memberName:@"clauses" arguments:@[]]);
                if ([clauses isKindOfClass:[NSArray class]])
                    for (id clause in (NSArray *)clauses)
                        if ([clause isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]]) {
                            [snapshots setObject:clause forKey:@"CydiaClause"];
                            id operation([packageSession invokeSnapshot:clause memberName:@"version" arguments:@[]]);
                            if ([operation isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]])
                                [snapshots setObject:operation forKey:@"CydiaOperation"];
                            break;
                        }
                break;
            }
    }
    for (NSString *memberName in @[@"author", @"maintainer"]) {
        id address([packageSession invokeScope:@"Package"
            memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:memberName
            arguments:@[] targetOrigin:nil]);
        if ([address isKindOfClass:[CydiaLegacyUICompatibilityNativeSnapshot class]]) {
            [snapshots setObject:address forKey:@"MIMEAddress"];
            break;
        }
    }

    NSMutableArray *rows([NSMutableArray arrayWithCapacity:152]);
    NSUInteger expectedAllow(0), expectedDeny(0), invokedCount(0), verifiedCount(0);
    for (CydiaLegacyBridgeMember *member in CydiaLegacyBridgeMembers()) {
        NSString *scope([member scope]);
        NSString *kind(CydiaLegacyBridgeMemberKindName([member kind]));
        NSString *name([member name]);
        BOOL expected(CydiaNativeCompatibilityMatrixExpectedAllowed(member));
        if (expected) ++expectedAllow; else ++expectedDeny;
        CydiaLegacyUICompatibilitySignature *signature(
            CydiaLegacyUICompatibilitySignatureForMember(scope, [member kind], name));
        NSArray *arguments(CydiaNativeCompatibilityMatrixArguments(signature));
        CydiaLegacyUICompatibilityNativeSession *session([sessions objectForKey:scope]);
        CydiaLegacyUICompatibilityNativeSnapshot *snapshot([snapshots objectForKey:scope]);
        BOOL targetAvailable((session != nil && [session isActive]) ||
            (snapshot != nil && [snapshot isValid] && packageSession != nil &&
             [packageSession isActive]));
        CydiaLegacyUICompatibilityNativeSession *observedSession(
            snapshot != nil ? packageSession : session);
        BOOL excludedScope(!targetAvailable && !expected &&
            ([@[@"CydiaProgressData", @"CydiaProgressEvent", @"Window"] containsObject:scope]) &&
            [applicationSession isActive]);
        if (excludedScope)
            observedSession = applicationSession;
        NSUInteger entriesBefore([observedSession executorEntryCount]);
        NSUInteger denialsBefore([observedSession denialCount]);
        id value([CydiaLegacyUIUndefinedValue value]);
        BOOL invoked(NO);
        NSString *dispatchStatus(@"not_dispatched_target_unavailable");
        NSString *reason(@"none");
        CydiaLegacyUICompatibilityDecision *decision(nil);

        if (targetAvailable) {
            if (snapshot != nil) {
                decision = [packageSession decisionForSnapshot:snapshot memberName:name arguments:arguments];
                if (expected && [signature dispatchMode] == CydiaLegacyUIDispatchModeSynchronous) {
                    value = [packageSession invokeSnapshot:snapshot memberName:name arguments:arguments];
                    invoked = YES;
                } else {
                    reason = expected ? @"snapshot-boundary" : @"policy-denied";
                }
            } else if (session != nil) {
                decision = [session decisionForScope:scope memberKind:[member kind]
                    memberName:name arguments:arguments targetOrigin:nil];
                if (expected && [member family] != CydiaLegacyBridgeOperationFamilyMutation &&
                    [signature dispatchMode] == CydiaLegacyUIDispatchModeSynchronous) {
                    value = [session invokeScope:scope memberKind:[member kind]
                        memberName:name arguments:arguments targetOrigin:nil];
                    invoked = YES;
                } else if (expected && [member family] == CydiaLegacyBridgeOperationFamilyMutation) {
                    reason = @"mutation-boundary";
                } else if (expected) {
                    reason = @"dispatch-mode-boundary";
                } else {
                    value = [session invokeScope:scope memberKind:[member kind]
                        memberName:name arguments:arguments targetOrigin:nil];
                    invoked = YES;
                    reason = @"policy-denied";
                }
            }
        } else if (excludedScope) {
            decision = [[applicationSession service] decisionForScope:scope
                memberKind:[member kind] memberName:name arguments:arguments targetOrigin:nil];
            /* Even an unexpected allow remains confined by this executor's
             * application target binding; it is recorded as a failure below. */
            value = [[applicationSession service] invokeScope:scope
                memberKind:[member kind] memberName:name arguments:arguments targetOrigin:nil];
            invoked = YES;
            reason = @"excluded-scope-policy-denied";
        } else {
            reason = @"target-unavailable";
        }
        NSUInteger executorEntries([observedSession executorEntryCount] - entriesBefore);
        NSUInteger nativeRejections([observedSession denialCount] - denialsBefore);
        BOOL typedUnavailable(decision != nil &&
            (value == [decision unavailableValue] || [value isEqual:[decision unavailableValue]]));
        BOOL verified(invoked && decision != nil &&
            (expected ? ([decision isAllowed] && executorEntries == 1 && nativeRejections == 0) :
                (![decision isAllowed] && executorEntries == 0 && typedUnavailable)));
        if (invoked) {
            ++invokedCount;
            dispatchStatus = !verified ? @"dispatched_unverified" :
                (expected ? @"dispatched_read" : @"dispatched_denied_unavailable");
        } else if (targetAvailable) {
            dispatchStatus = [reason isEqualToString:@"mutation-boundary"] ?
                @"not_dispatched_mutation_boundary" : @"not_dispatched_execution_boundary";
        }
        if (verified) ++verifiedCount;

        NSDictionary *row(@{
            @"identity": [NSString stringWithFormat:@"%@|%@|%@", scope, kind, name],
            @"scope": scope ?: @"none", @"kind": kind ?: @"unknown", @"name": name ?: @"",
            @"family": CydiaLegacyBridgeOperationFamilyName([member family]),
            @"expected": expected ? @"allow" : @"deny",
            @"target": targetAvailable ? @"canonical" :
                (excludedScope ? @"excluded-scope" : @"unavailable"),
            @"boundary": excludedScope ? @"application-compatibility-service" :
                (snapshot != nil ? @"native-snapshot-session" : @"native-session"),
            @"callerContext": @"trusted_in_process", @"invoked": @(invoked),
            @"boundaryAttempted": @(invoked), @"executorEntries": @(executorEntries),
            @"nativeRejections": @(nativeRejections), @"verified": @(verified),
            @"typedUnavailable": @(typedUnavailable),
            @"dispatchStatus": dispatchStatus, @"resultShape":
                invoked ? CydiaNativeCompatibilityExecutionShape(value) : @"undefined",
            @"reason": reason,
            @"decision": decision == nil ? @"unavailable" :
                ([decision isAllowed] ? @"allow" : @"deny"),
            @"denial": nativeRejections == 0 ? @"none" :
                CydiaNativeCompatibilityMatrixDenialName([observedSession lastDenialReason]),
        });
        [rows addObject:row];
    }

    NSMutableDictionary *identity([NSMutableDictionary dictionary]);
    NSDictionary *environment([[NSProcessInfo processInfo] environment]);
    for (NSString *key in @[
        @"CYDIA_NATIVE_COMPATIBILITY_EXPECTED_SOURCE_COMMIT",
        @"CYDIA_NATIVE_COMPATIBILITY_EXPECTED_SOURCE_TREE_SHA256",
        @"CYDIA_NATIVE_COMPATIBILITY_EXPECTED_VERSION"]) {
        NSString *value([environment objectForKey:key]);
        if (![value isKindOfClass:[NSString class]] || [value length] == 0 ||
            [value length] > 256 ||
            [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound)
            value = nil;
        if (value != nil)
            [identity setObject:value forKey:
                [key hasSuffix:@"SOURCE_COMMIT"] ? @"expectedSourceCommit" :
                ([key hasSuffix:@"SOURCE_TREE_SHA256"] ? @"expectedSourceTreeSHA256" : @"expectedVersion")];
    }
    [identity setObject:@((unsigned int)getpid()) forKey:@"processID"];

    NSDictionary *receipt(@{
        @"schema": @2, @"mode": @"installed-boundary-matrix",
        @"runID": CydiaLegacyUICompatibilityRuntimeEvidenceRunID() ?: @"matrix",
        @"identity": identity,
        @"packageIdentity": [[canonicalPackage id] description] ?: @"",
        @"counts": @{ @"members": @(rows.count), @"expectedAllow": @(expectedAllow),
            @"expectedDeny": @(expectedDeny), @"invoked": @(invokedCount),
            @"notAttempted": @(rows.count - invokedCount), @"verified": @(verifiedCount),
            @"gaps": @(rows.count - verifiedCount) }, @"members": rows,
        @"mutation": @"not-dispatched", @"callerContext": @"trusted_in_process",
    });
    NSData *data([NSJSONSerialization dataWithJSONObject:receipt
        options:NSJSONWritingPrettyPrinted error:nil]);
    if (data == nil || ![data writeToFile:path options:NSDataWritingAtomic error:nil])
        return;
    legacyCompatibilityMatrixEvidenceConsumed_ = YES;
}
@end
