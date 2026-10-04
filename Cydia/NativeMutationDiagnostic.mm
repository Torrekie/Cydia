/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "Cydia/NativeMutationDiagnostic.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/AppState.h"
#include "Cydia/LegacyUICompatibilityNativeCaller.h"
#include "Cydia/LegacyUICompatibilityRuntimeEvidence.h"
#include <objc/runtime.h>
#include <unistd.h>

BOOL CydiaNativeCompatibilityB17FixtureRequested(void) {
    return [[[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_B17_FIXTURE"]
        isEqualToString:@"1"];
}

NSString *CydiaNativeCompatibilityMutationDiagnosticSourceURL(void) {
    return CydiaNativeCompatibilityB17FixtureRequested() ?
        @"https://native-compatibility.invalid/" :
        @"https://native-compatibility-diagnostic.invalid/";
}

NSString *CydiaNativeCompatibilityMutationDiagnosticDistribution(void) {
    return @"native-compatibility";
}

NSString *CydiaNativeCompatibilityMutationDiagnosticSection(void) {
    return CydiaNativeCompatibilityB17FixtureRequested() ?
        @"b17-lifetime-rejection-section" : @"native-compatibility-section";
}

NSString *CydiaNativeCompatibilityMutationDiagnosticMetadataKey(void) {
    return CydiaNativeCompatibilityB17FixtureRequested() ?
        @"b17.metadata" : @"native-compatibility-runtime-probe";
}

NSString *CydiaNativeCompatibilityMutationDiagnosticOperationForValue(id operation) {
    if (![operation isKindOfClass:[NSString class]])
        return nil;
    for (NSString *allowed in @[
        @"Source.addSection", @"Source.removeSection", @"Source.remove",
        @"CydiaObject.refreshSources", @"CydiaObject.saveConfig",
        @"CydiaObject.addTrivialSource", @"CydiaObject.addSource",
        @"Package.clear", @"Package.install", @"Package.remove",
        @"CydiaObject.installPackages"
    ])
        if ([operation isEqualToString:allowed])
            return operation;
    return nil;
}

NSString *CydiaNativeCompatibilityMutationDiagnosticPackageIdentifier(void) {
    return CydiaNativeCompatibilityB17FixtureRequested() ?
        @"com.example.native-compatibility" :
        @"com.torrekie.cydia-ui-transaction-fixture";
}

/* Never fall back to an arbitrary installed package or manufacture a model.
 * The fixed inert fixture must already belong to the loaded database. */
Package *CydiaNativeCompatibilityMutationDiagnosticPackage(Database *database) {
    for (id candidate in [database packages])
        if (object_getClass(candidate) == [Package class] &&
            [[(Package *)candidate id] isEqualToString:
                CydiaNativeCompatibilityMutationDiagnosticPackageIdentifier()])
            return (Package *)candidate;
    return nil;
}

/* Clear needs a nonempty queue to demonstrate an effect. Seed only this
 * reserved fixture's in-memory install mark, never a package transaction.
 * Existing queued state is not overwritten. This is fixture setup, not an
 * observed Package.install API call, and is labeled separately in the receipt. */
BOOL CydiaNativeCompatibilityMutationDiagnosticPreparePackage(NSString *operation, Package *package) {
    if (![operation isEqualToString:@"Package.clear"])
        return YES;
    if (object_getClass(package) != [Package class] ||
        ![[package id] isEqualToString:CydiaNativeCompatibilityMutationDiagnosticPackageIdentifier()] ||
        [package mode] != nil)
        return NO;
    [package install];
    return [package mode] != nil;
}

id CydiaNativeCompatibilityMutationDiagnosticValue(void) {
    if (CydiaNativeCompatibilityB17FixtureRequested())
        return @"b17-lifetime-rejection-value";
    NSString *runID(CydiaLegacyUICompatibilityRuntimeEvidenceRunID());
    return @{
        @"marker": @"native-compatibility-runtime-probe",
        @"runID": [runID isKindOfClass:[NSString class]] &&
            [runID length] != 0 ? runID : @"runtime-mutation-probe",
    };
}

NSDictionary *CydiaNativeCompatibilityPackageMutationObservation(NSString *operation,
    CydiaLegacyUICompatibilityNativeSession *session, Package *package,
    NSString *modeBefore, NSUInteger entriesBefore, NSUInteger rejectionsBefore, id result) {
    NSString *scope([session targetScope]);
    return @{
        @"schema": @1, @"mode": @"fixed-package-mutation-boundary",
        @"operation": operation, @"scope": scope,
        @"member": [operation substringFromIndex:[scope length] + 1],
        @"kind": @"method", @"callerContext": @"trusted_in_process",
        @"processID": @((unsigned int)getpid()), @"runtimeVersion": Cydia_ ?: @"unknown",
        @"runID": CydiaLegacyUICompatibilityRuntimeEvidenceRunID() ?: @"unset",
        @"packageIdentity": [package id],
        @"targetClass": NSStringFromClass(object_getClass([session target])),
        @"boundaryAttempted": @YES,
        @"executorEntries": @([session executorEntryCount] - entriesBefore),
        @"nativeRejections": @([session denialCount] - rejectionsBefore),
        @"denialReason": @([session lastDenialReason]),
        @"resultShape": result == nil || result == [CydiaLegacyUIUndefinedValue value] ?
            @"undefined" : NSStringFromClass(object_getClass(result)),
        @"resultDescription": [result description] ?: @"undefined",
        @"fixtureSetup": [operation isEqualToString:@"Package.clear"] ?
            @"in-memory-fixture-install-mark-not-API-evidence" : @"none",
        @"packageModeBefore": modeBefore ?: @"none",
        @"packageModeAfter": [package mode] ?: @"none",
        @"acceptance": @"typed-request-only; native transaction and disk outcome require independent evidence",
    };
}
