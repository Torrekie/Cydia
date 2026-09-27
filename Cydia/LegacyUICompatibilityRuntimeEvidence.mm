/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibilityRuntimeEvidence.h"

#include <errno.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

NSString * const CydiaLegacyUICompatibilityRuntimeEvidencePathEnvironment =
    @"CYDIA_NATIVE_COMPATIBILITY_EVIDENCE_PATH";
NSString * const CydiaLegacyUICompatibilityRuntimeEvidenceRunIDEnvironment =
    @"CYDIA_NATIVE_COMPATIBILITY_EVIDENCE_RUN_ID";

namespace {

const NSUInteger kMaximumEvidencePathLength = 1024;
const NSUInteger kMaximumEvidenceRunIDLength = 128;
const NSUInteger kMaximumEvidenceStringLength = 256;
const NSUInteger kMaximumEvidenceBytes = 512 * 1024;

NSString *SafeString(id value, NSUInteger maximum) {
    if (![value isKindOfClass:[NSString class]])
        return nil;
    NSString *string((NSString *)value);
    if ([string length] == 0 || [string length] > maximum ||
        [string rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound)
        return nil;
    return [string copy];
}

NSString *EnvironmentString(NSString *key, NSUInteger maximum) {
    id value([[[NSProcessInfo processInfo] environment] objectForKey:key]);
    return SafeString(value, maximum);
}

BOOL IsSafePath(NSString *path) {
    if (SafeString(path, kMaximumEvidencePathLength) == nil ||
        ![path hasPrefix:@"/"] || [path length] > kMaximumEvidencePathLength)
        return NO;

    /* Reject traversal and normalization changes.  This keeps the receipt
     * destination within the run-owned path selected by the caller instead
     * of silently redirecting it through a relative component. */
    for (NSString *component in [path pathComponents]) {
        if ([component isEqualToString:@"."] ||
            [component isEqualToString:@".."])
            return NO;
    }
    if (![[path stringByStandardizingPath] isEqualToString:path])
        return NO;

    NSString *parent([path stringByDeletingLastPathComponent]);
    if ([parent length] == 0)
        parent = @"/";
    struct stat parentStatus;
    if (lstat([parent fileSystemRepresentation], &parentStatus) != 0 ||
        !S_ISDIR(parentStatus.st_mode))
        return NO;

    struct stat destinationStatus;
    if (lstat([path fileSystemRepresentation], &destinationStatus) == 0)
        return NO;
    if (errno != ENOENT)
        return NO;
    return access([parent fileSystemRepresentation], W_OK) == 0;
}

NSString *MemberTargetScope(NSString *scope) {
    if ([scope isEqualToString:@"CydiaObject"] ||
        [scope isEqualToString:@"Package"] ||
        [scope isEqualToString:@"Source"] ||
        [scope isEqualToString:@"NSDictionary"])
        return scope;
    if ([scope isEqualToString:@"CydiaOperation"] ||
        [scope isEqualToString:@"CydiaClause"] ||
        [scope isEqualToString:@"CydiaRelation"] ||
        [scope isEqualToString:@"MIMEAddress"])
        return @"nested-package-snapshot";
    if ([scope isEqualToString:@"CyteObject"])
        return @"CyteObject";
    return @"none";
}

BOOL IsSessionScope(NSString *scope) {
    return [scope isEqualToString:@"CydiaObject"] ||
        [scope isEqualToString:@"CyteObject"] ||
        [scope isEqualToString:@"Package"] ||
        [scope isEqualToString:@"Source"] ||
        [scope isEqualToString:@"NSDictionary"];
}

BOOL IsNestedScope(NSString *scope) {
    return [scope isEqualToString:@"CydiaOperation"] ||
        [scope isEqualToString:@"CydiaClause"] ||
        [scope isEqualToString:@"CydiaRelation"] ||
        [scope isEqualToString:@"MIMEAddress"];
}

BOOL IsExpectedAllowed(CydiaLegacyBridgeMember *member) {
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

NSString *ArgumentKindName(CydiaLegacyUIArgumentKind kind) {
    switch (kind) {
        case CydiaLegacyUIArgumentKindString: return @"string";
        case CydiaLegacyUIArgumentKindOptionalString: return @"optional-string";
        case CydiaLegacyUIArgumentKindNumber: return @"number";
        case CydiaLegacyUIArgumentKindOptionalNumber: return @"optional-number";
        case CydiaLegacyUIArgumentKindBooleanLike: return @"boolean-like";
        case CydiaLegacyUIArgumentKindOptionalBooleanLike: return @"optional-boolean-like";
        case CydiaLegacyUIArgumentKindSequence: return @"sequence";
        case CydiaLegacyUIArgumentKindOpaque: return @"opaque";
        case CydiaLegacyUIArgumentKindOptionalAny: return @"optional-any";
        case CydiaLegacyUIArgumentKindURLString: return @"url-string";
        case CydiaLegacyUIArgumentKindMetadataKey: return @"metadata-key";
        case CydiaLegacyUIArgumentKindOptionalPropertyList: return @"optional-property-list";
    }
    return @"unknown";
}

NSString *ResultKindName(CydiaLegacyUIValueKind kind) {
    switch (kind) {
        case CydiaLegacyUIValueKindVoid: return @"void";
        case CydiaLegacyUIValueKindObject: return @"object";
        case CydiaLegacyUIValueKindString: return @"string";
        case CydiaLegacyUIValueKindNumber: return @"number";
        case CydiaLegacyUIValueKindBoolean: return @"boolean";
        case CydiaLegacyUIValueKindArray: return @"array";
    }
    return @"unknown";
}

NSString *UnavailableConventionName(CydiaLegacyUIUnavailableConvention convention) {
    switch (convention) {
        case CydiaLegacyUIUnavailableConventionUndefined: return @"undefined";
        case CydiaLegacyUIUnavailableConventionNull: return @"null";
        case CydiaLegacyUIUnavailableConventionFalse: return @"false";
    }
    return @"unknown";
}

NSString *DispatchModeName(CydiaLegacyUIDispatchMode mode) {
    switch (mode) {
        case CydiaLegacyUIDispatchModeSynchronous: return @"synchronous";
        case CydiaLegacyUIDispatchModeMainThreadAsync: return @"main-thread-async";
        case CydiaLegacyUIDispatchModeNativeConfirmation: return @"native-confirmation";
    }
    return @"unknown";
}

NSString *CompatibilityDenialName(CydiaLegacyUICompatibilityDenialReason reason) {
    switch (reason) {
        case CydiaLegacyUICompatibilityDenialReasonNone: return @"none";
        case CydiaLegacyUICompatibilityDenialReasonPolicy: return @"policy";
        case CydiaLegacyUICompatibilityDenialReasonMalformedArguments:
            return @"malformed-arguments";
    }
    return @"unknown";
}

NSString *BridgeDenialName(CydiaLegacyBridgeDenialReason reason) {
    switch (reason) {
        case CydiaLegacyBridgeDenialReasonNone: return @"none";
        case CydiaLegacyBridgeDenialReasonMalformedRequest: return @"malformed-request";
        case CydiaLegacyBridgeDenialReasonUnknownMember: return @"unknown-member";
        case CydiaLegacyBridgeDenialReasonMissingContext: return @"missing-context";
        case CydiaLegacyBridgeDenialReasonCaller: return @"caller";
        case CydiaLegacyBridgeDenialReasonOrigin: return @"origin";
        case CydiaLegacyBridgeDenialReasonMainFrame: return @"main-frame";
        case CydiaLegacyBridgeDenialReasonUserGesture: return @"user-gesture";
        case CydiaLegacyBridgeDenialReasonPackageIdentity: return @"package-identity";
        case CydiaLegacyBridgeDenialReasonTargetOrigin: return @"target-origin";
        case CydiaLegacyBridgeDenialReasonRetiredSurface: return @"retired-surface";
    }
    return @"unknown";
}

id SafeArgument(CydiaLegacyUIArgumentKind kind) {
    switch (kind) {
        case CydiaLegacyUIArgumentKindString:
            return @"runtime-evidence";
        case CydiaLegacyUIArgumentKindOptionalString:
            return [NSNull null];
        case CydiaLegacyUIArgumentKindNumber:
            return @0;
        case CydiaLegacyUIArgumentKindOptionalNumber:
            return [NSNull null];
        case CydiaLegacyUIArgumentKindBooleanLike:
            return @NO;
        case CydiaLegacyUIArgumentKindOptionalBooleanLike:
            return [NSNull null];
        case CydiaLegacyUIArgumentKindSequence:
            return @[];
        case CydiaLegacyUIArgumentKindOpaque:
            return @"runtime-evidence-opaque";
        case CydiaLegacyUIArgumentKindOptionalAny:
            return [NSNull null];
        case CydiaLegacyUIArgumentKindURLString:
            return @"https://runtime-evidence.invalid/";
        case CydiaLegacyUIArgumentKindMetadataKey:
            return @"runtime.evidence.key";
        case CydiaLegacyUIArgumentKindOptionalPropertyList:
            return [NSNull null];
    }
    return [NSNull null];
}

NSArray *SafeArguments(CydiaLegacyUICompatibilitySignature *signature) {
    if (signature == nil)
        return @[];
    NSMutableArray *arguments([NSMutableArray arrayWithCapacity:
        [[signature argumentKinds] count]]);
    for (NSNumber *number in [signature argumentKinds])
        [arguments addObject:SafeArgument((CydiaLegacyUIArgumentKind)
            [number unsignedIntegerValue])];
    return [arguments copy];
}

NSDictionary *SignatureReceipt(CydiaLegacyUICompatibilitySignature *signature) {
    if (signature == nil)
        return @{
            @"present": @NO,
            @"argumentKinds": @[],
            @"resultKind": @"unknown",
            @"unavailableConvention": @"unknown",
            @"dispatchMode": @"unknown",
        };

    NSMutableArray *argumentKinds([NSMutableArray arrayWithCapacity:
        [[signature argumentKinds] count]]);
    for (NSNumber *number in [signature argumentKinds])
        [argumentKinds addObject:ArgumentKindName((CydiaLegacyUIArgumentKind)
            [number unsignedIntegerValue])];
    return @{
        @"present": @YES,
        @"argumentKinds": [argumentKinds copy],
        @"resultKind": ResultKindName([signature resultKind]),
        @"unavailableConvention": UnavailableConventionName(
            [signature unavailableConvention]),
        @"dispatchMode": DispatchModeName([signature dispatchMode]),
    };
}

NSDictionary *SanitizedIdentity(NSDictionary *identity) {
    NSDictionary *input([identity isKindOfClass:[NSDictionary class]] ? identity : @{});
    NSMutableDictionary *result([NSMutableDictionary dictionary]);
    NSArray *stringKeys = @[
        @"expectedSourceCommit", @"expectedSourceTreeSHA256", @"expectedVersion",
        @"runtimeVersion", @"bundleShortVersion", @"bundleVersion",
    ];
    for (NSString *key in stringKeys) {
        NSString *value(SafeString([input objectForKey:key], kMaximumEvidenceStringLength));
        [result setObject:value ?: [NSNull null] forKey:key];
    }
    id processID([input objectForKey:@"processID"]);
    if ([processID isKindOfClass:[NSNumber class]] &&
        [processID unsignedLongLongValue] <= UINT_MAX)
        [result setObject:@([processID unsignedLongLongValue]) forKey:@"processID"];
    else
        [result setObject:[NSNull null] forKey:@"processID"];
    [result setObject:@"expected-from-environment" forKey:@"sourceIdentityAttestation"];
    return [result copy];
}

BOOL SessionCanEvaluate(id session) {
    return session != nil && session != [NSNull null] &&
        [session respondsToSelector:@selector(decisionForScope:memberKind:memberName:arguments:targetOrigin:)];
}

NSString *TargetReason(NSString *scope, BOOL available) {
    if (available)
        return @"typed-native-session";
    if ([scope isEqualToString:@"CyteObject"])
        return @"no-production-target-factory";
    if (IsNestedScope(scope))
        return @"missing-canonical-package-snapshot";
    if (IsSessionScope(scope))
        return @"canonical-target-session-unavailable";
    return @"no-safe-canonical-target";
}

NSString *DispatchStatus(NSString *scope, CydiaLegacyBridgeMember *member,
                         BOOL targetAvailable, BOOL evaluated, BOOL actualAllowed) {
    if (!targetAvailable) {
        if ([scope isEqualToString:@"CyteObject"])
            return @"not_dispatched_no_production_target";
        if (IsNestedScope(scope))
            return @"not_dispatched_missing_canonical_package_snapshot";
        return @"not_dispatched_target_unavailable";
    }
    if ([member family] == CydiaLegacyBridgeOperationFamilyMutation)
        return @"not_dispatched_mutation_disabled";
    if (!evaluated)
        return @"not_dispatched_decision_unavailable";
    if (!actualAllowed)
        return @"not_dispatched_policy_denied";
    return @"not_dispatched_decision_only";
}

NSDictionary *CallerContextReceipt(void) {
    return @{
        @"caller": @"trusted_in_process",
        @"mainFrame": @YES,
        @"userGesture": @YES,
        @"origin": @"none",
    };
}

NSDictionary *RowForMember(CydiaLegacyBridgeMember *member,
                           NSDictionary *sessions,
                           NSUInteger *evaluatedCount,
                           NSUInteger *allowedCount,
                           NSUInteger *deniedCount) {
    NSString *scope([member scope]);
    CydiaLegacyUICompatibilitySignature *signature(
        CydiaLegacyUICompatibilitySignatureForMember(scope, [member kind], [member name]));
    BOOL expectedAllowed(IsExpectedAllowed(member));
    NSString *targetScope(MemberTargetScope(scope));
    id session([sessions objectForKey:scope]);
    BOOL targetAvailable(IsSessionScope(scope) && SessionCanEvaluate(session));
    BOOL evaluated(NO);
    BOOL actualAllowed(NO);
    NSString *actualDecision(@"not_evaluated");
    NSString *actualReason(@"target-unavailable");
    NSString *bridgeReason(@"none");

    if (targetAvailable) {
        NSArray *arguments(SafeArguments(signature));
        CydiaLegacyUICompatibilityDecision *decision(
            [session decisionForScope:scope memberKind:[member kind]
                memberName:[member name] arguments:arguments targetOrigin:nil]);
        if (decision != nil) {
            evaluated = YES;
            actualAllowed = [decision isAllowed];
            actualDecision = actualAllowed ? @"allow" : @"deny";
            actualReason = CompatibilityDenialName([decision denialReason]);
            bridgeReason = BridgeDenialName([[decision authorization] denialReason]);
            if (evaluatedCount != NULL)
                ++*evaluatedCount;
            if (actualAllowed) {
                if (allowedCount != NULL)
                    ++*allowedCount;
            } else if (deniedCount != NULL) {
                ++*deniedCount;
            }
        } else {
            actualReason = @"decision-unavailable";
        }
    }

    NSDictionary *policyDecision(@{
        @"expected": expectedAllowed ? @"allow" : @"deny",
        @"actual": actualDecision,
        @"actualReason": actualReason,
        @"authorizationReason": bridgeReason,
    });
    NSDictionary *target(@{
        @"scope": targetScope,
        @"availability": targetAvailable ? @"available" : @"unavailable",
        @"reason": TargetReason(scope, targetAvailable),
    });
    return @{
        @"identity": [NSString stringWithFormat:@"%@|%@|%@", scope,
            CydiaLegacyBridgeMemberKindName([member kind]), [member name]],
        @"scope": scope,
        @"kind": CydiaLegacyBridgeMemberKindName([member kind]),
        @"name": [member name],
        @"family": CydiaLegacyBridgeOperationFamilyName([member family]),
        @"sourceForm": [member sourceForm],
        @"callerContext": CallerContextReceipt(),
        @"policyDecision": policyDecision,
        @"signature": SignatureReceipt(signature),
        @"target": target,
        @"dispatchStatus": DispatchStatus(scope, member, targetAvailable,
            evaluated, actualAllowed),
        @"resultShape": @"not_observed",
    };
}

NSError *EvidenceError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"dev.torrekie.cydia.runtime-evidence"
        code:code userInfo:@{NSLocalizedDescriptionKey: description ?: @"Runtime evidence error"}];
}

} // namespace

BOOL CydiaLegacyUICompatibilityRuntimeEvidenceRequested(void) {
    NSString *path(EnvironmentString(
        CydiaLegacyUICompatibilityRuntimeEvidencePathEnvironment,
        kMaximumEvidencePathLength));
    return path != nil && IsSafePath(path);
}

NSString *CydiaLegacyUICompatibilityRuntimeEvidenceOutputPath(void) {
    return EnvironmentString(CydiaLegacyUICompatibilityRuntimeEvidencePathEnvironment,
        kMaximumEvidencePathLength);
}

NSString *CydiaLegacyUICompatibilityRuntimeEvidenceRunID(void) {
    NSString *requested(EnvironmentString(CydiaLegacyUICompatibilityRuntimeEvidenceRunIDEnvironment,
        kMaximumEvidenceRunIDLength));
    if (requested != nil)
        return requested;
    return [NSString stringWithFormat:@"pid-%u", (unsigned int)getpid()];
}

NSDictionary *CydiaLegacyUICompatibilityRuntimeEvidenceBuildReceipt(
    NSString *runID,
    NSDictionary *identity,
    NSDictionary *sessions) {
    NSString *safeRunID(SafeString(runID, kMaximumEvidenceRunIDLength));
    if (safeRunID == nil)
        safeRunID = [NSString stringWithFormat:@"pid-%u", (unsigned int)getpid()];
    NSDictionary *safeSessions([sessions isKindOfClass:[NSDictionary class]] ?
        [NSDictionary dictionaryWithDictionary:sessions] : @{});

    NSMutableArray *rows([NSMutableArray array]);
    NSUInteger expectedAllow(0);
    NSUInteger expectedDeny(0);
    NSUInteger evaluated(0);
    NSUInteger actualAllow(0);
    NSUInteger actualDeny(0);
    for (CydiaLegacyBridgeMember *member in CydiaLegacyBridgeMembers()) {
        if (IsExpectedAllowed(member))
            ++expectedAllow;
        else
            ++expectedDeny;
        [rows addObject:RowForMember(member, safeSessions, &evaluated,
            &actualAllow, &actualDeny)];
    }

    NSDictionary *counts(@{
        @"members": @([rows count]),
        @"expectedAllow": @(expectedAllow),
        @"expectedDeny": @(expectedDeny),
        @"evaluated": @(evaluated),
        @"actualAllow": @(actualAllow),
        @"actualDeny": @(actualDeny),
        @"notEvaluated": @([rows count] - evaluated),
    });
    NSDictionary *mutationMode(@{
        @"status": @"disabled",
        @"automated": @NO,
        @"singleCasePerRun": @YES,
        @"authorizationRequired": @YES,
        @"requestedMember": [NSNull null],
        @"prompt": @"not-presented",
        @"userAction": @"not-observed",
        @"effect": @"not-observed",
        @"validity": @"not-evaluated",
    });
    return @{
        @"schema": @1,
        @"kind": @"cydia-legacy-ui-runtime-compatibility-evidence",
        @"mode": @"decision-only",
        @"runID": safeRunID,
        @"identity": SanitizedIdentity(identity),
        @"callerContext": CallerContextReceipt(),
        @"counts": counts,
        @"mutationMode": mutationMode,
        @"members": [rows copy],
    };
}

BOOL CydiaLegacyUICompatibilityRuntimeEvidenceWriteReceipt(
    NSString *path,
    NSString *runID,
    NSDictionary *identity,
    NSDictionary *sessions,
    NSError **error) {
    if (error != NULL)
        *error = nil;
    if (!IsSafePath(path)) {
        if (error != NULL)
            *error = EvidenceError(1, @"evidence path is not an absolute, bounded, writable new file");
        return NO;
    }

    NSDictionary *receipt(CydiaLegacyUICompatibilityRuntimeEvidenceBuildReceipt(
        runID, identity, sessions));
    NSError *serializationError(nil);
    NSData *data([NSJSONSerialization dataWithJSONObject:receipt
        options:NSJSONWritingSortedKeys error:&serializationError]);
    if (data == nil || [data length] > kMaximumEvidenceBytes) {
        if (error != NULL)
            *error = serializationError ?: EvidenceError(2, @"evidence receipt exceeds the bounded size");
        return NO;
    }
    NSError *writeError(nil);
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        if (error != NULL)
            *error = writeError ?: EvidenceError(3, @"evidence receipt write failed");
        return NO;
    }
    return YES;
}
