/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibility.h"

#include <cstdlib>
#include <iostream>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (!condition) {
        std::cerr << "[verify-legacy-ui-compatibility][fail] "
                  << [message UTF8String] << std::endl;
        std::exit(1);
    }
}

NSString *Key(CydiaLegacyBridgeMember *member) {
    return [NSString stringWithFormat:@"%@\t%@\t%@", [member scope],
        CydiaLegacyBridgeMemberKindName([member kind]), [member name]];
}

CydiaLegacyUICompatibilityDecision *Evaluate(NSString *scope,
    CydiaLegacyBridgeMemberKind kind, NSString *name,
    CydiaUIRouteContext *context, NSURL *origin, NSString *identity,
    NSURL *target, NSArray *arguments) {
    CydiaLegacyUICompatibilityInvocation *invocation(
        [[CydiaLegacyUICompatibilityInvocation alloc]
            initWithScope:scope memberKind:kind memberName:name
            context:context callingOrigin:origin packageIdentity:identity
            targetOrigin:target arguments:arguments]);
    return CydiaLegacyUIEvaluateCompatibilityInvocation(invocation);
}

void VerifyLocalization(void) {
    NSString *root([[NSFileManager defaultManager] currentDirectoryPath]);
    NSBundle *applicationBundle([NSBundle bundleWithPath:
        [root stringByAppendingPathComponent:@"MobileCydia.app"]]);
    Expect(applicationBundle != nil, @"application bundle is available to host test");
    NSBundle *englishBundle([NSBundle bundleWithPath:
        [applicationBundle pathForResource:@"en" ofType:@"lproj"]]);
    Expect(englishBundle != nil, @"English localization bundle is available");

    id translated(CydiaLegacyUICompatibilityLocalizedStringInBundle(
        englishBundle, @"CONFIRM", [CydiaLegacyUIUndefinedValue value],
        [CydiaLegacyUIUndefinedValue value]));
    Expect([translated isEqualToString:@"Confirm"],
           @"undefined optional localize arguments use the main strings table");

    id tableTranslated(CydiaLegacyUICompatibilityLocalizedStringInBundle(
        englishBundle, @"System", [NSNull null], @"Sections_"));
    Expect([tableTranslated isEqualToString:@"System"],
           @"explicit table selects the Foundation localization table");

    id fallback(CydiaLegacyUICompatibilityLocalizedStringInBundle(
        englishBundle, @"MISSING_NATIVE_COMPAT_KEY", @"Fallback", nil));
    Expect([fallback isEqualToString:@"Fallback"],
           @"missing key preserves the explicit fallback string");

    id keyFallback(CydiaLegacyUICompatibilityLocalizedStringInBundle(
        englishBundle, @"MISSING_NATIVE_COMPAT_KEY", nil, nil));
    Expect([keyFallback isEqualToString:@"MISSING_NATIVE_COMPAT_KEY"],
           @"missing key without fallback preserves Foundation key behavior");

    Expect(CydiaLegacyUICompatibilityLocalizedStringInBundle(
               englishBundle, nil, nil, nil) == nil,
           @"missing localize key is rejected");
    Expect(CydiaLegacyUICompatibilityLocalizedStringInBundle(
               englishBundle, @"", nil, nil) == nil,
           @"empty localize key is rejected");
    Expect(CydiaLegacyUICompatibilityLocalizedStringInBundle(
               englishBundle, @"BAD\nKEY", nil, nil) == nil,
           @"control characters in localize key are rejected");
    Expect(CydiaLegacyUICompatibilityLocalizedStringInBundle(
               englishBundle, @"CONFIRM", @42, nil) == nil,
           @"non-string optional localize fallback is rejected");
    Expect(CydiaLegacyUICompatibilityLocalizedStringInBundle(
               englishBundle, @"System", nil, @"../Sections_") == nil,
           @"table path traversal is rejected");
    Expect(CydiaLegacyUICompatibilityLocalizedStringInBundle(
               nil, @"CONFIRM", nil, nil) == nil,
           @"missing localization bundle is rejected");
}

void VerifyMetadataValueBoundary(void) {
    NSString *key(CydiaLegacyUICompatibilityCopyMetadataKey(@"fixture.key"));
    Expect([key isEqualToString:@"fixture.key"],
           @"metadata keys are copied at the typed boundary");
    Expect(CydiaLegacyUICompatibilityCopyMetadataKey(@"") == nil,
           @"empty metadata keys are rejected");
    Expect(CydiaLegacyUICompatibilityCopyMetadataKey(@"bad\nkey") == nil,
           @"metadata keys reject control characters");

    NSMutableArray *nested([NSMutableArray arrayWithObject:@"before"]);
    NSMutableDictionary *mutableValue([@{
        @"text": nested,
        @"number": @42,
        @"date": [NSDate dateWithTimeIntervalSinceReferenceDate:42],
        @"data": [NSData dataWithBytes:"abc" length:3],
    } mutableCopy]);
    id copied(nil);
    BOOL removes(NO);
    Expect(CydiaLegacyUICompatibilityCopyMetadataValue(
               mutableValue, &copied, &removes) && !removes && copied != nil,
           @"property-list metadata values are accepted");
    [nested addObject:@"after"];
    Expect([[[copied objectForKey:@"text"] lastObject]
               isEqualToString:@"before"],
           @"metadata values are immutable creation-time snapshots");
    Expect([NSPropertyListSerialization propertyList:copied
        isValidForFormat:NSPropertyListBinaryFormat_v1_0],
           @"normalized metadata value remains property-list serializable");
    id scalar(nil);
    Expect(CydiaLegacyUICompatibilityCopyMetadataValue(@42, &scalar, &removes) &&
           !removes && [scalar isEqual:@42],
           @"scalar property-list metadata values remain supported");

    Expect(CydiaLegacyUICompatibilityCopyMetadataValue(
               [NSNull null], NULL, &removes) && removes,
           @"explicit null removes metadata values");
    removes = NO;
    Expect(CydiaLegacyUICompatibilityCopyMetadataValue(
               [CydiaLegacyUIUndefinedValue value], NULL, &removes) && removes,
           @"undefined removes metadata values");
    Expect(!CydiaLegacyUICompatibilityCopyMetadataValue(
               [[NSObject alloc] init], NULL, NULL),
           @"arbitrary objects cannot cross the metadata boundary");
    Expect(!CydiaLegacyUICompatibilityCopyMetadataValue(
               [NSSet setWithObject:@"not-a-plist"], NULL, NULL),
           @"sets cannot cross the property-list metadata boundary");

    NSMutableArray *cycle([NSMutableArray array]);
    [cycle addObject:cycle];
    Expect(!CydiaLegacyUICompatibilityCopyMetadataValue(cycle, NULL, NULL),
           @"cyclic metadata containers fail closed");
}

} // namespace


@interface CydiaTestCompatibilityExecutor : NSObject
    <CydiaLegacyUICompatibilityExecuting>
@property (nonatomic, strong) id synchronousResult;
@property (nonatomic, strong) CydiaLegacyUICompatibilityInvocation *lastSynchronous;
@property (nonatomic, strong) CydiaLegacyUICompatibilityInvocation *lastAsynchronous;
@property (nonatomic, strong) CydiaLegacyUICompatibilityInvocation *lastConfirmation;
@property (nonatomic) BOOL acceptsConfirmation;
@end

@implementation CydiaTestCompatibilityExecutor
- (id) legacyUICompatibilityService:(CydiaLegacyUICompatibilityService *)service
        executeSynchronousInvocation:(CydiaLegacyUICompatibilityInvocation *)invocation {
    (void) service;
    self.lastSynchronous = invocation;
    return self.synchronousResult;
}
- (void) legacyUICompatibilityService:(CydiaLegacyUICompatibilityService *)service
             enqueueMainThreadInvocation:(CydiaLegacyUICompatibilityInvocation *)invocation {
    (void) service;
    self.lastAsynchronous = invocation;
}
- (BOOL) legacyUICompatibilityService:(CydiaLegacyUICompatibilityService *)service
        requestNativeConfirmationForInvocation:(CydiaLegacyUICompatibilityInvocation *)invocation {
    (void) service;
    self.lastConfirmation = invocation;
    return self.acceptsConfirmation;
}
@end


int main() {
    @autoreleasepool {
        NSArray *members(CydiaLegacyBridgeMembers());
        NSArray *signatures(CydiaLegacyUICompatibilitySignatures());
        Expect([members count] == 152, @"policy inventory count changed");
        Expect([signatures count] == [members count],
            @"every policy member has exactly one call signature");

        NSMutableSet *memberKeys([NSMutableSet set]);
        for (CydiaLegacyBridgeMember *member in members)
            [memberKeys addObject:Key(member)];
        NSMutableSet *signatureKeys([NSMutableSet set]);
        for (CydiaLegacyUICompatibilitySignature *signature in signatures) {
            Expect([signature member] != nil, @"signature resolves a policy member");
            NSString *key(Key([signature member]));
            Expect(![signatureKeys containsObject:key], @"signature keys are unique");
            [signatureKeys addObject:key];
        }
        Expect([memberKeys isEqualToSet:signatureKeys],
            @"call signatures exactly cover methods, attributes, globals, dynamic names, and wildcard debt");
        for (CydiaLegacyUICompatibilitySignature *signature in signatures) {
            CydiaLegacyBridgeMember *member([signature member]);
            if ([member family] == CydiaLegacyBridgeOperationFamilyMutation ||
                [member family] == CydiaLegacyBridgeOperationFamilyClipboard)
                Expect([signature dispatchMode] ==
                        CydiaLegacyUIDispatchModeNativeConfirmation,
                    @"mutations and clipboard writes cannot execute outside the native-confirmation backend");
        }

        NSURL *trustedOrigin([NSURL URLWithString:@"https://cydia.saurik.com/ui/"]);
        CydiaUIRouteContext *trusted([CydiaUIRouteContext
            trustedLegacyPageContextWithOrigin:trustedOrigin mainFrame:YES
            userGesture:YES]);
        NSURL *depictionOrigin([NSURL URLWithString:@"https://repo.example/depiction"]);
        NSString *identity(@"sample:iphoneos-arm64");
        CydiaUIRouteContext *depiction([CydiaUIRouteContext
            repositoryDepictionContextWithOrigin:depictionOrigin
            packageIdentity:identity mainFrame:YES userGesture:YES]);

        CydiaLegacyUICompatibilityDecision *format(Evaluate(@"CyteObject",
            CydiaLegacyBridgeMemberKindMethod, @"format", trusted,
            trustedOrigin, nil, nil, @[@"%@", @[@"value"]]));
        Expect([format isAllowed] &&
               [[format signature] resultKind] == CydiaLegacyUIValueKindString &&
               [[format signature] dispatchMode] == CydiaLegacyUIDispatchModeSynchronous,
            @"trusted rendering method preserves synchronous string contract");

        CydiaLegacyUICompatibilitySignature *localizeSignature(
            CydiaLegacyUICompatibilitySignatureForMember(
                @"CyteObject", CydiaLegacyBridgeMemberKindMethod, @"localize"));
        Expect(localizeSignature != nil &&
               [[localizeSignature argumentKinds] count] == 3 &&
               [[localizeSignature argumentKinds] objectAtIndex:0].unsignedIntegerValue ==
                   CydiaLegacyUIArgumentKindString &&
               [[localizeSignature argumentKinds] objectAtIndex:1].unsignedIntegerValue ==
                   CydiaLegacyUIArgumentKindOptionalString &&
               [[localizeSignature argumentKinds] objectAtIndex:2].unsignedIntegerValue ==
                   CydiaLegacyUIArgumentKindOptionalString &&
               [localizeSignature resultKind] == CydiaLegacyUIValueKindString &&
               [localizeSignature unavailableConvention] ==
                   CydiaLegacyUIUnavailableConventionUndefined,
               @"localize retains its three-string Foundation signature");

        CydiaLegacyUICompatibilityDecision *localize(Evaluate(@"CyteObject",
            CydiaLegacyBridgeMemberKindMethod, @"localize", trusted,
            trustedOrigin, nil, nil, @[@"CONFIRM",
                [CydiaLegacyUIUndefinedValue value], [NSNull null]]));
        Expect([localize isAllowed],
               @"undefined and null localize optionals pass typed validation");
        CydiaLegacyUICompatibilityDecision *badLocalize(Evaluate(@"CyteObject",
            CydiaLegacyBridgeMemberKindMethod, @"localize", trusted,
            trustedOrigin, nil, nil, @[@"CONFIRM", @42,
                [CydiaLegacyUIUndefinedValue value]]));
        Expect(![badLocalize isAllowed] &&
               [badLocalize denialReason] ==
                   CydiaLegacyUICompatibilityDenialReasonMalformedArguments &&
               [badLocalize unavailableValue] == [CydiaLegacyUIUndefinedValue value],
               @"malformed localize fallback keeps the undefined convention");

        CydiaLegacyUICompatibilityDecision *badFormat(Evaluate(@"CyteObject",
            CydiaLegacyBridgeMemberKindMethod, @"format", trusted,
            trustedOrigin, nil, nil, @[@"%@"]));
        Expect(![badFormat isAllowed] && [badFormat denialReason] ==
                CydiaLegacyUICompatibilityDenialReasonMalformedArguments &&
               [badFormat unavailableValue] == [CydiaLegacyUIUndefinedValue value],
            @"malformed arguments fail closed with the method's undefined convention");

        CydiaLegacyUICompatibilityDecision *packageName(Evaluate(@"Package",
            CydiaLegacyBridgeMemberKindAttribute, @"name", depiction,
            depictionOrigin, identity, nil, @[]));
        Expect([packageName isAllowed] && [[packageName signature] argumentKinds].count == 0,
            @"current depiction package property is authorized without arguments");
        Expect(![Evaluate(@"Package", CydiaLegacyBridgeMemberKindAttribute,
                @"name", depiction, depictionOrigin, @"other", nil, @[]) isAllowed],
            @"depiction cannot read a different package object");

        CydiaLegacyUICompatibilityDecision *reachability(Evaluate(@"CyteObject",
            CydiaLegacyBridgeMemberKindMethod, @"isReachable", depiction,
            depictionOrigin, identity, depictionOrigin, @[@"repo.example"]));
        Expect([reachability isAllowed], @"same-origin depiction reachability is retained");
        CydiaLegacyUICompatibilityDecision *crossReachability(Evaluate(@"CyteObject",
            CydiaLegacyBridgeMemberKindMethod, @"isReachable", depiction,
            depictionOrigin, identity, [NSURL URLWithString:@"https://evil.example/"],
            @[@"evil.example"]));
        Expect(![crossReachability isAllowed] &&
               [[crossReachability unavailableValue] isEqual:@NO],
            @"cross-origin depiction reachability returns the defined false result");

        CydiaLegacyUICompatibilityDecision *mutation(Evaluate(@"CydiaObject",
            CydiaLegacyBridgeMemberKindMethod, @"installPackages", depiction,
            depictionOrigin, identity, nil, @[@[identity]]));
        Expect(![mutation isAllowed], @"depiction mutation is denied per call");
        CydiaLegacyUICompatibilityDecision *trustedMutation(Evaluate(@"CydiaObject",
            CydiaLegacyBridgeMemberKindMethod, @"installPackages", trusted,
            trustedOrigin, nil, nil, @[@[identity]]));
        Expect([trustedMutation isAllowed] && [[trustedMutation signature] dispatchMode] ==
                CydiaLegacyUIDispatchModeNativeConfirmation,
            @"trusted mutation is typed as a native-confirmation command");

        CydiaLegacyUICompatibilitySignature *metadataSignature(
            CydiaLegacyUICompatibilitySignatureForMember(
                @"CydiaObject", CydiaLegacyBridgeMemberKindMethod,
                @"setMetadataValue"));
        Expect(metadataSignature != nil &&
               [[metadataSignature argumentKinds] count] == 2 &&
               [[metadataSignature argumentKinds] objectAtIndex:0].unsignedIntegerValue ==
                   CydiaLegacyUIArgumentKindMetadataKey &&
               [[metadataSignature argumentKinds] objectAtIndex:1].unsignedIntegerValue ==
                   CydiaLegacyUIArgumentKindOptionalPropertyList &&
               [metadataSignature dispatchMode] ==
                   CydiaLegacyUIDispatchModeNativeConfirmation,
               @"metadata writer has a dedicated typed confirmation signature");
        CydiaLegacyUICompatibilitySignature *metadataKeysSignature(
            CydiaLegacyUICompatibilitySignatureForMember(
                @"CydiaObject", CydiaLegacyBridgeMemberKindMethod,
                @"getMetadataKeys"));
        Expect(metadataKeysSignature != nil &&
               [metadataKeysSignature.member family] ==
                   CydiaLegacyBridgeOperationFamilyGlobalRead &&
               [[metadataKeysSignature argumentKinds] count] == 0 &&
               [metadataKeysSignature resultKind] == CydiaLegacyUIValueKindArray &&
               [metadataKeysSignature dispatchMode] ==
                   CydiaLegacyUIDispatchModeSynchronous,
               @"metadata-key enumeration keeps its bounded synchronous signature");
        CydiaLegacyUICompatibilitySignature *metadataValueSignature(
            CydiaLegacyUICompatibilitySignatureForMember(
                @"CydiaObject", CydiaLegacyBridgeMemberKindMethod,
                @"getMetadataValue"));
        Expect(metadataValueSignature != nil &&
               [metadataValueSignature.member family] ==
                   CydiaLegacyBridgeOperationFamilyGlobalRead &&
               [[metadataValueSignature argumentKinds] count] == 1 &&
               [[metadataValueSignature argumentKinds] objectAtIndex:0].unsignedIntegerValue ==
                   CydiaLegacyUIArgumentKindMetadataKey &&
               [metadataValueSignature resultKind] == CydiaLegacyUIValueKindObject &&
               [metadataValueSignature dispatchMode] ==
                   CydiaLegacyUIDispatchModeSynchronous,
               @"metadata-value reads use the bounded key signature");
        CydiaLegacyUICompatibilityDecision *metadataValueAllowed(
            Evaluate(@"CydiaObject", CydiaLegacyBridgeMemberKindMethod,
                @"getMetadataValue", trusted, trustedOrigin, nil, nil,
                @[@"fixture.key"]));
        Expect([metadataValueAllowed isAllowed],
               @"bounded metadata-value read is authorized for trusted Cydia");
        CydiaLegacyUICompatibilityDecision *emptyMetadataValue(
            Evaluate(@"CydiaObject", CydiaLegacyBridgeMemberKindMethod,
                @"getMetadataValue", trusted, trustedOrigin, nil, nil,
                @[@""]));
        CydiaLegacyUICompatibilityDecision *objectMetadataValue(
            Evaluate(@"CydiaObject", CydiaLegacyBridgeMemberKindMethod,
                @"getMetadataValue", trusted, trustedOrigin, nil, nil,
                @[[[NSObject alloc] init]]));
        Expect(![emptyMetadataValue isAllowed] &&
               ![objectMetadataValue isAllowed],
               @"malformed metadata-value keys fail before provider dispatch");
        Expect([Evaluate(@"CydiaObject", CydiaLegacyBridgeMemberKindMethod,
                @"setMetadataValue", trusted, trustedOrigin, nil, nil,
                @[@"fixture.key", @{ @"nested": @[@"value"] }]) isAllowed],
               @"property-list metadata write is authorized for trusted Cydia");
        Expect(![Evaluate(@"CydiaObject", CydiaLegacyBridgeMemberKindMethod,
                @"setMetadataValue", trusted, trustedOrigin, nil, nil,
                @[@"fixture.key", [[NSObject alloc] init]]) isAllowed],
               @"non-property-list metadata write is rejected before dispatch");

        CydiaLegacyUICompatibilityDecision *nullConvention(Evaluate(@"CyteObject",
            CydiaLegacyBridgeMemberKindAttribute, @"ecid", trusted,
            trustedOrigin, nil, nil, @[]));
        Expect([nullConvention isAllowed] && [nullConvention unavailableValue] == [NSNull null],
            @"legacy explicit-null property convention is retained");
        CydiaLegacyUICompatibilityDecision *dictionaryGet(Evaluate(@"NSDictionary",
            CydiaLegacyBridgeMemberKindDynamicMethod, @"get", trusted,
            trustedOrigin, nil, nil, @[@"key"]));
        Expect([dictionaryGet isAllowed], @"authorized dynamic dictionary get remains named");
        Expect(![Evaluate(@"NSDictionary", CydiaLegacyBridgeMemberKindDynamicMethod,
                @"get", trusted, trustedOrigin, nil, nil, @[]) isAllowed],
            @"dynamic dictionary get validates argument count");

        CydiaLegacyUICompatibilityDecision *wildcard(Evaluate(@"CyteObject",
            CydiaLegacyBridgeMemberKindKeyPolicy, @"*", trusted,
            trustedOrigin, nil, nil, @[]));
        Expect(![wildcard isAllowed] && [[wildcard unavailableValue] isEqual:@NO],
            @"historical wildcard remains inventoried but cannot authorize a call");
        Expect(![CydiaLegacyUIEvaluateCompatibilityInvocation(nil) isAllowed],
            @"nil invocation fails closed");

        CydiaLegacyUICompatibilityService *service(
            [[CydiaLegacyUICompatibilityService alloc]
                initWithContext:trusted callingOrigin:trustedOrigin
                packageIdentity:nil]);
        Expect(![service isExecutable] && [service executor] == nil,
            @"convenience service is explicitly policy-only without an executor");
        Expect([[service decisionForScope:@"CyteObject"
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"supports"
            arguments:@[@"window.open"] targetOrigin:nil] isAllowed],
            @"bound service evaluates the same immutable caller context");
        Expect([[service invokeScope:@"CyteObject"
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"supports"
            arguments:@[@"window.open"] targetOrigin:nil] isEqual:@NO],
            @"policy-only service returns the typed unavailable value without a backend");

        CydiaTestCompatibilityExecutor *executor(
            [[CydiaTestCompatibilityExecutor alloc] init]);
        CydiaLegacyUICompatibilityService *executingService(
            [[CydiaLegacyUICompatibilityService alloc]
                initWithContext:trusted callingOrigin:trustedOrigin
                packageIdentity:nil executor:executor]);
        Expect([executingService isExecutable] &&
               [executingService executor] == executor,
            @"designated service reports an explicitly supplied executor");
        executor.synchronousResult = @"supported";
        id supportsResult([executingService invokeScope:@"CyteObject"
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"supports"
            arguments:@[@"window.open"] targetOrigin:nil]);
        Expect([supportsResult isEqual:@NO] && executor.lastSynchronous != nil,
            @"wrong backend result type is rejected with the boolean false convention");
        executor.synchronousResult = @YES;
        Expect([[executingService invokeScope:@"CyteObject"
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"supports"
            arguments:@[@"window.open"] targetOrigin:nil] isEqual:@YES],
            @"valid synchronous backend result is returned");

        executor.acceptsConfirmation = YES;
        id saveResult([executingService invokeScope:@"CydiaObject"
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"saveConfig"
            arguments:@[] targetOrigin:nil]);
        Expect(saveResult == [CydiaLegacyUIUndefinedValue value] &&
               [[executor.lastConfirmation memberName] isEqualToString:@"saveConfig"],
            @"configuration writes use the native-confirmation backend");

        id sourceResult([executingService invokeScope:@"Source"
            memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"addSection"
            arguments:@[@"Utilities"] targetOrigin:nil]);
        Expect([sourceResult isEqual:@YES] &&
               [[executor.lastConfirmation memberName] isEqualToString:@"addSection"],
            @"mutation enters the native-confirmation backend exactly once");

        executor.lastConfirmation = nil;
        id deniedMutation([[[CydiaLegacyUICompatibilityService alloc]
            initWithContext:depiction callingOrigin:depictionOrigin
            packageIdentity:identity executor:executor]
            invokeScope:@"Package" memberKind:CydiaLegacyBridgeMemberKindMethod
            memberName:@"install" arguments:@[] targetOrigin:nil]);
        Expect(deniedMutation == [CydiaLegacyUIUndefinedValue value] &&
               executor.lastConfirmation == nil,
            @"denied depiction mutation never reaches a backend");

        CydiaTestCompatibilityExecutor *shortLivedExecutor(
            [[CydiaTestCompatibilityExecutor alloc] init]);
        CydiaLegacyUICompatibilityService *shortLivedService(
            [[CydiaLegacyUICompatibilityService alloc]
                initWithContext:trusted callingOrigin:trustedOrigin
                packageIdentity:nil executor:shortLivedExecutor]);
        shortLivedExecutor = nil;
        Expect(![shortLivedService isExecutable] &&
               [[shortLivedService invokeScope:@"CyteObject"
                   memberKind:CydiaLegacyBridgeMemberKindMethod
                   memberName:@"supports" arguments:@[@"window.open"]
                   targetOrigin:nil] isEqual:@NO],
            @"service becomes policy-only when its weak executor owner is released");

        VerifyLocalization();
        VerifyMetadataValueBoundary();

        std::cout << "[verify-legacy-ui-compatibility][ ok ] "
                  << [signatures count]
                  << " names have typed arguments, results, dispatch, and denial conventions"
                  << std::endl;
    }
    return 0;
}
