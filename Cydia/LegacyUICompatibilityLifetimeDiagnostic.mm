#include "Cydia/Application.h"
#include "Cydia/Database.h"
#include "Cydia/LegacyUICompatibilityNativeProvider.h"
#include "Cydia/NativeMutationDiagnostic.h"
#include "Cydia/Package.h"
#include "Cydia/Source.h"

#include <objc/runtime.h>
#include <unistd.h>

// A separate, app-issued owner makes final reference removal observable without
// invalidating the application's ordinary sessions. Only fixed read operations
// are passed by the B1.7 opt-in callsite below; no UI or provider mutation occurs.
static NSDictionary *B17LifetimeRow(Cydia *application, id presenter,
    Database *database, NSString *caseID, NSString *scope, id target,
    CydiaLegacyBridgeMemberKind kind, NSString *member, NSArray *arguments,
    id expected) {
    NSMutableDictionary *row([@{@"caseID": caseID, @"processID": @(getpid())} mutableCopy]);
    __weak CydiaLegacyUICompatibilityNativeSession *weakSession(nil);
    __weak CydiaLegacyUICompatibilityNativeCaller *weakOwner(nil);
    __weak id weakTarget(target), weakPresenter(presenter);
    CydiaLegacyUICompatibilityService *service(nil);
    @autoreleasepool {
        CydiaLegacyUICompatibilityNativeProvider *provider(
            [[CydiaLegacyUICompatibilityNativeProvider alloc]
                initWithApplication:application database:database presenter:presenter]);
        CydiaLegacyUICompatibilityNativeCaller *owner(
            [[CydiaLegacyUICompatibilityNativeCaller alloc]
                initWithCapability:[CydiaLegacyUICompatibilityNativeCaller
                    issueCapabilityForApplication:application]
                reader:provider commander:provider router:provider]);
        [provider attachCaller:owner];
        CydiaLegacyUICompatibilityNativeSession *session(nil);
        if ([scope isEqualToString:@"Package"])
            session = [provider sessionForPackage:target presenter:presenter];
        else if ([scope isEqualToString:@"Source"])
            session = [provider sessionForSource:target presenter:presenter];
        else
            session = [provider sessionForApplicationWithPresenter:presenter];
        weakSession = session;
        weakOwner = owner;
        service = [session service];
        row[@"scope"] = scope;
        row[@"sessionIdentity"] = [NSString stringWithFormat:@"%p", (__bridge void *)session];
        row[@"targetIdentity"] = [NSString stringWithFormat:@"%p", (__bridge void *)[session target]];
        row[@"presenterIdentity"] = [NSString stringWithFormat:@"%p", (__bridge void *)[session presenter]];
        row[@"packageIdentity"] = [session packageIdentity] ?: @"";
        row[@"sourceKey"] = [session sourceKey] ?: @"";
        row[@"sessionRetained"] = @(session != nil && [session isActive] &&
            [session target] == target && [session presenter] == presenter);
        id value([session invokeScope:scope memberKind:kind memberName:member
            arguments:arguments targetOrigin:nil]);
        row[@"retainedReadMatches"] = @(expected != nil && [value isEqual:expected] &&
            [session executorEntryCount] == 1 && [session lastDenialReason] ==
                CydiaLegacyUICompatibilityNativeDenialReasonNone);
        [owner invalidate]; // Releases the owner's strong session registry.
        id rejected([session invokeScope:scope memberKind:kind memberName:member
            arguments:arguments targetOrigin:nil]);
        row[@"ownerInvalidationDenied"] = @(session != nil && ![session isActive] &&
            rejected == [CydiaLegacyUIUndefinedValue value] &&
            [session executorEntryCount] == 1 && [session lastDenialReason] ==
                CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability);
        [provider invalidate];
        session = nil;
        owner = nil;
        provider = nil;
    }
    row[@"sessionDeallocated"] = @(weakSession == nil);
    row[@"ownerDeallocated"] = @(weakOwner == nil);
    row[@"targetLiveAfterRelease"] = @(weakTarget != nil);
    row[@"presenterLiveAfterRelease"] = @(weakPresenter != nil);
    id releasedValue([service invokeScope:scope memberKind:kind memberName:member
        arguments:arguments targetOrigin:nil]);
    row[@"postReleaseReadRejected"] = @(service != nil && ![service isExecutable] &&
        releasedValue == [CydiaLegacyUIUndefinedValue value]);
    return row;
}

NSDictionary *CydiaNativeCompatibilityLifetimeDiagnostic(
    Cydia *application, id presenter, Database *database, NSString *metadataKey) {
    if (application == nil || presenter == nil || database == nil)
        return @{};

    NSString *key(metadataKey ?: @"native-compatibility-diagnostic");
    CydiaLegacyUICompatibilityNativeSession *metadataSession(
        [application legacyUICompatibilitySessionForApplicationWithPresenter:presenter]);
    BOOL metadataSessionRetained(metadataSession != nil &&
        [metadataSession isActive] && [metadataSession target] == application);
    id metadataBefore([metadataSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getMetadataValue"
        arguments:@[key] targetOrigin:nil]);
    BOOL metadataSessionRead(metadataSessionRetained &&
        metadataBefore != nil && metadataBefore != [CydiaLegacyUIUndefinedValue value]);
    [metadataSession invalidate];
    id metadataAfter([metadataSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getMetadataValue"
        arguments:@[key] targetOrigin:nil]);
    BOOL metadataSessionInvalidationDenied(![metadataSession isActive] &&
        metadataAfter == [CydiaLegacyUIUndefinedValue value] &&
        [metadataSession lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability);

    Package *package(nil);
    for (id candidate in [database packages])
        if (object_getClass(candidate) == [Package class]) {
            package = (Package *)candidate;
            break;
        }
    __weak Package *weakPackage(package);
    CydiaLegacyUICompatibilityNativeSession *packageSession(
        package == nil ? nil : [application legacyUICompatibilitySessionForPackage:package
            presenter:presenter]);
    BOOL packageSessionRetained(packageSession != nil && [packageSession isActive] &&
        [packageSession target] == package);
    BOOL packageSessionInvalidationDenied(NO);
    if (packageSession != nil && [packageSession isActive]) {
        [packageSession invalidate];
        id value([packageSession invokeScope:@"Package"
            memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"id"
            arguments:@[] targetOrigin:nil]);
        packageSessionInvalidationDenied = ![packageSession isActive] &&
            value == [CydiaLegacyUIUndefinedValue value] &&
            [packageSession lastDenialReason] ==
                CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability;
    }
    NSMutableDictionary *result([@{
        @"packageSessionRetained": @(packageSessionRetained),
        @"packageSessionInvalidationDenied": @(packageSessionInvalidationDenied),
        @"packageTargetLiveAfterRelease": @(weakPackage != nil),
        @"metadataSessionRetained": @(metadataSessionRetained),
        @"metadataSessionRead": @(metadataSessionRead),
        @"metadataSessionInvalidationDenied": @(metadataSessionInvalidationDenied),
        @"metadataTargetLiveAfterRelease": @(application != nil),
    } mutableCopy]);
    if (CydiaNativeCompatibilityB17FixtureRequested()) {
        Package *fixture(CydiaNativeCompatibilityMutationDiagnosticPackage(database));
        NSString *sourceKey([NSString stringWithFormat:@"deb:%@:%@",
            CydiaNativeCompatibilityMutationDiagnosticSourceURL(),
            CydiaNativeCompatibilityMutationDiagnosticDistribution()]);
        Source *source([database sourceWithKey:sourceKey]);
        result[@"b17LifetimeCases"] = @[
            B17LifetimeRow(application, presenter, database, @"package-session",
                @"Package", fixture, CydiaLegacyBridgeMemberKindAttribute, @"id", @[],
                CydiaNativeCompatibilityMutationDiagnosticPackageIdentifier()),
            B17LifetimeRow(application, presenter, database, @"source-session",
                @"Source", source, CydiaLegacyBridgeMemberKindAttribute, @"key", @[], sourceKey),
            B17LifetimeRow(application, presenter, database, @"metadata-session",
                @"CydiaObject", application, CydiaLegacyBridgeMemberKindMethod,
                @"getMetadataValue", @[CydiaNativeCompatibilityMutationDiagnosticMetadataKey()],
                CydiaNativeCompatibilityMutationDiagnosticValue())
        ];
    }
    return result;
}
