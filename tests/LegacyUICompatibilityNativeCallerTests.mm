/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibilityNativeCaller.h"

#include <cstdlib>
#include <iostream>
#include <objc/runtime.h>

namespace {

__weak id CurrentNativeTestCydiaIssuer;

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    std::cerr << "[verify-legacy-ui-compatibility-native][FAIL] "
              << [message UTF8String] << std::endl;
    std::exit(1);
}

BOOL IsUndefined(id value) {
    return value == [CydiaLegacyUIUndefinedValue value];
}

BOOL NativeTestCydiaMayIssue(id application, SEL selector) {
    (void)selector;
    return [NSThread isMainThread] && application != nil &&
        application == CurrentNativeTestCydiaIssuer;
}

BOOL NativeSafeRenderingString(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] != 0 &&
        [value length] <= 4096 &&
        [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

BOOL NativeSafeReachabilityName(id value) {
    if (!NativeSafeRenderingString(value) || [value length] > 253)
        return NO;
    NSString *name((NSString *)value);
    NSCharacterSet *allowed([NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"]);
    if ([name rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound)
        return NO;
    for (NSString *label in [name componentsSeparatedByString:@"."])
        if ([label length] == 0 || [label length] > 63 ||
            [label hasPrefix:@"-"] || [label hasSuffix:@"-"])
            return NO;
    return YES;
}

} // namespace

@interface NativeTestApplication : NSObject
@end

@implementation NativeTestApplication
- (BOOL) cydiaLegacyUICompatibilityApplicationMayIssueCapability {
    return YES;
}
- (Class) class {
    return NSClassFromString(@"Cydia") ?: [NativeTestApplication class];
}
@end

@interface NativeForgedRouteContext : CydiaUIRouteContext
@property (nonatomic, strong)
    CydiaLegacyUICompatibilityNativeCapability *forgedCapability;
@end

@implementation NativeForgedRouteContext
- (Class) class { return [CydiaUIRouteContext class]; }
- (CydiaUIRouteCaller) caller { return CydiaUIRouteCallerTrustedInProcess; }
- (BOOL) isMainFrame { return YES; }
- (BOOL) hasUserGesture { return YES; }
- (NSURL *) initiatingOrigin { return nil; }
- (NSString *) depictionPackageIdentity { return nil; }
- (CydiaLegacyUICompatibilityNativeCapability *) inProcessCapability {
    return _forgedCapability;
}
@end

@interface NativeTestProvider : NSObject
    <CydiaLegacyUICompatibilityNativeReading,
     CydiaLegacyUICompatibilityNativeCommanding,
     CydiaLegacyUICompatibilityNativeRouting>
@property (nonatomic) NSUInteger readCount;
@property (nonatomic) NSUInteger mutationCount;
@property (nonatomic) NSUInteger routeCount;
@property (nonatomic) BOOL mutationOnMainThread;
@property (nonatomic) BOOL rejectNextMutation;
@property (nonatomic) BOOL packageMutationUnavailable;
@property (nonatomic, strong)
    CydiaLegacyUICompatibilityInvocation *reentrantInvocation;
@property (nonatomic) BOOL reentrantAccepted;
@property (nonatomic) CydiaLegacyUICompatibilityNativeDenialReason
    reentrantDenialReason;
@property (nonatomic) BOOL revokeDuringSourceLookup;
@property (nonatomic, strong) id lastTarget;
@property (nonatomic, copy) NSString *lastIdentity;
@property (nonatomic, copy) NSString *lastMutationMember;
@property (nonatomic, copy) NSArray *lastMutationArguments;
@property (nonatomic) NSUInteger globalReadCount;
@property (nonatomic) NSUInteger sessionReadCount;
@property (nonatomic, copy) NSString *lastSessionKey;
@property (nonatomic, strong) id sessionValue;
@property (nonatomic, copy) NSArray *metadataKeys;
@property (nonatomic, strong) id metadataValue;
@property (nonatomic) NSUInteger metadataMutationCount;
@property (nonatomic) BOOL metadataOnMainThread;
@property (nonatomic) BOOL metadataRemoving;
@property (nonatomic, copy) NSString *lastMetadataKey;
@property (nonatomic, strong) id lastMetadataValue;
@end

@implementation NativeTestProvider
- (BOOL) respondsToSelector:(SEL)selector {
    if (_packageMutationUnavailable && selector == @selector(
            legacyNativeSession:requestPackageMutation:target:packageIdentity:arguments:presenter:))
        return NO;
    return [super respondsToSelector:selector];
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
      valueForPackageScope:(NSString *)scope
                memberName:(NSString *)memberName
                    target:(id)target
                 arguments:(NSArray *)arguments {
    (void)session;
    (void)scope;
    (void)arguments;
    ++_readCount;
    _lastTarget = target;
    if ([memberName isEqualToString:@"name"])
        return @"Fixture Package";
    if ([memberName isEqualToString:@"getField"])
        return @"Fixture Value";
    return nil;
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
      valueForSourceMember:(NSString *)memberName
                    target:(id)target
                 arguments:(NSArray *)arguments {
    (void)session;
    (void)arguments;
    ++_readCount;
    _lastTarget = target;
    return [memberName isEqualToString:@"label"] ? @"Fixture Source" : nil;
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
     valueForRenderingMember:(NSString *)memberName
                  arguments:(NSArray *)arguments {
    ++_readCount;
    _lastTarget = [session target];
    if ([memberName isEqualToString:@"format"] && [arguments count] == 2)
        return CydiaLegacyUICompatibilityFormatString(
            [arguments objectAtIndex:0], [arguments objectAtIndex:1]);
    if ([memberName isEqualToString:@"localize"] && [arguments count] == 3)
        return CydiaLegacyUICompatibilityLocalizedString(
            [arguments objectAtIndex:0], [arguments objectAtIndex:1],
            [arguments objectAtIndex:2]);
    if ([memberName isEqualToString:@"supports"] && [arguments count] == 1 &&
        NativeSafeRenderingString([arguments objectAtIndex:0]))
        return @([[arguments objectAtIndex:0] isEqualToString:@"window.open"]);
    if ([memberName isEqualToString:@"isReachable"] && [arguments count] == 1 &&
        NativeSafeReachabilityName([arguments objectAtIndex:0]))
        return @NO;
    return nil;
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
       valueForGlobalMember:(NSString *)memberName
                  arguments:(NSArray *)arguments {
    (void)session;
    ++_globalReadCount;
    if ([memberName isEqualToString:@"getMetadataKeys"] &&
        [arguments count] == 0)
        return _metadataKeys;
    if ([memberName isEqualToString:@"getMetadataValue"]) {
        if ([arguments count] == 1 &&
            [[arguments objectAtIndex:0] isEqualToString:@"fixture.key"])
            return _metadataValue;
        return nil;
    }
    return [memberName isEqualToString:@"getAllSources"] ? @[] : @"global-value";
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
       valueForSessionMember:(NSString *)memberName
                   arguments:(NSArray *)arguments {
    (void)session;
    if (![memberName isEqualToString:@"getSessionValue"] ||
        [arguments count] != 1)
        return nil;
    ++_sessionReadCount;
    _lastSessionKey = [[arguments objectAtIndex:0] copy];
    return _sessionValue;
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
        requestPackageMutation:(NSString *)memberName
                          target:(id)target
                 packageIdentity:(NSString *)packageIdentity
                       arguments:(NSArray *)arguments
                        presenter:(id)presenter {
    (void)session;
    _lastMutationMember = [memberName copy];
    _lastMutationArguments = [arguments copy];
    Expect(presenter != nil, @"mutation receives bound presenter");
    ++_mutationCount;
    _mutationOnMainThread = [NSThread isMainThread];
    _lastTarget = target;
    _lastIdentity = [packageIdentity copy];
    CydiaLegacyUICompatibilityInvocation *reentrant(_reentrantInvocation);
    _reentrantInvocation = nil;
    if (reentrant != nil) {
        _reentrantAccepted = [session
            legacyUICompatibilityService:[session service]
            requestNativeConfirmationForInvocation:reentrant];
        _reentrantDenialReason = [session lastDenialReason];
    }
    if (_rejectNextMutation) {
        _rejectNextMutation = NO;
        return NO;
    }
    return YES;
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
   requestMetadataMutationForKey:(NSString *)key
                            value:(id)value
                          removing:(BOOL)removing
                         presenter:(id)presenter {
    (void)session;
    Expect(presenter != nil, @"metadata mutation receives bound presenter");
    ++_metadataMutationCount;
    _metadataOnMainThread = [NSThread isMainThread];
    _metadataRemoving = removing;
    _lastMetadataKey = [key copy];
    _lastMetadataValue = value;
    return YES;
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
           sourceKeyExists:(NSString *)sourceKey {
    if (_revokeDuringSourceLookup)
        [session invalidate];
    return [sourceKey isEqualToString:@"deb:https://repo.example/:./"];
}

- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
      handoffRouteDescriptor:(CydiaUIRouteDescriptor *)descriptor
                      context:(CydiaUIRouteContext *)context {
    (void)session;
    Expect([context caller] == CydiaUIRouteCallerTrustedInProcess,
           @"router receives in-process context");
    ++_routeCount;
    return [descriptor kind] == CydiaUIRouteKindPackage ||
        [descriptor kind] == CydiaUIRouteKindSource;
}
@end

@interface NativePackageCommandProvider : NativeTestProvider
@end
@implementation NativePackageCommandProvider
- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
    requestApplicationMutation:(NSString *)memberName
                       arguments:(NSArray *)arguments
                        presenter:(id)presenter {
    Expect(presenter == [session presenter], @"application mutation keeps bound presenter");
    self.mutationCount += 1;
    self.mutationOnMainThread = [NSThread isMainThread];
    self.lastMutationMember = memberName;
    self.lastMutationArguments = arguments;
    self.lastTarget = [session target];
    return YES;
}
@end

namespace {

CydiaLegacyBridgeRequest *Request(NSString *scope,
                                  CydiaLegacyBridgeMemberKind kind,
                                  NSString *name,
                                  CydiaUIRouteContext *context,
                                  id capability,
                                  NSString *packageIdentity) {
    return [[CydiaLegacyBridgeRequest alloc]
        initWithScope:scope memberKind:kind memberName:name context:context
        callingOrigin:nil packageIdentity:packageIdentity targetOrigin:nil
        inProcessCapability:capability];
}

id CydiaIssuer(void) {
    Class cydiaClass(NSClassFromString(@"Cydia"));
    if (cydiaClass == Nil) {
        cydiaClass = objc_allocateClassPair([NSObject class], "Cydia", 0);
        Expect(cydiaClass != Nil, @"create exact Cydia test class");
        static char methodTypes[4];
        methodTypes[0] = @encode(BOOL)[0];
        methodTypes[1] = '@';
        methodTypes[2] = ':';
        methodTypes[3] = '\0';
        BOOL added(class_addMethod(cydiaClass,
            NSSelectorFromString(
                @"cydiaLegacyUICompatibilityApplicationMayIssueCapability"),
            reinterpret_cast<IMP>(NativeTestCydiaMayIssue), methodTypes));
        Expect(added, @"install exact Cydia issuer predicate");
        objc_registerClassPair(cydiaClass);
    }
    id application([[cydiaClass alloc] init]);
    CurrentNativeTestCydiaIssuer = application;
    return application;
}

CydiaLegacyUICompatibilityInvocation *Invocation(
    CydiaLegacyUICompatibilityNativeSession *session,
    NSString *scope,
    NSString *name) {
    return [[CydiaLegacyUICompatibilityInvocation alloc]
        initWithScope:scope memberKind:CydiaLegacyBridgeMemberKindMethod
        memberName:name context:[session context] callingOrigin:nil
        packageIdentity:[session packageIdentity] targetOrigin:nil arguments:@[]];
}

void VerifyIssuanceAndPolicy(void) {
    Expect([CydiaLegacyUICompatibilityNativeCaller issueCapabilityForApplication:nil] == nil,
           @"nil issuer denied");
    Expect([CydiaLegacyUICompatibilityNativeCaller
            issueCapabilityForApplication:[[NSObject alloc] init]] == nil,
           @"ordinary object cannot issue capability");

    id application(CydiaIssuer());
    id sameClassImpostor([[NSClassFromString(@"Cydia") alloc] init]);
    Expect([CydiaLegacyUICompatibilityNativeCaller
            issueCapabilityForApplication:sameClassImpostor] == nil,
           @"same-class non-application object cannot issue capability");
    NativeTestApplication *spoof([[NativeTestApplication alloc] init]);
    Expect([CydiaLegacyUICompatibilityNativeCaller
            issueCapabilityForApplication:spoof] == nil,
           @"marker-like web object cannot issue capability");
    CydiaLegacyUICompatibilityNativeCapability *capability(
        [CydiaLegacyUICompatibilityNativeCaller
            issueCapabilityForApplication:application]);
    Expect(capability != nil && [capability isValid], @"app-issued capability is live");
    Expect([capability copy] == capability, @"opaque capability cannot be cloned");

    CydiaUIRouteContext *context(
        [CydiaUIRouteContext trustedInProcessContextWithCapability:capability]);
    Expect(context != nil && [context inProcessCapability] == capability,
           @"BOOL validator ABI creates a bound context");

    NativeForgedRouteContext *forgedContext(
        [NativeForgedRouteContext trustedNativeContext]);
    [forgedContext setForgedCapability:capability];
    CydiaLegacyBridgeAuthorization *forgedContextAuthorization(
        CydiaLegacyBridgeAuthorize(Request(@"Package",
            CydiaLegacyBridgeMemberKindAttribute, @"name", forgedContext,
            capability, @"fixture.package")));
    Expect(![forgedContextAuthorization isAllowed] &&
        [forgedContextAuthorization denialReason] ==
            CydiaLegacyBridgeDenialReasonMissingContext,
        @"route-context subclass cannot forge trusted in-process policy");

    CydiaUIRouteDescriptor *homeDescriptor(
        CydiaUIParseRouteURL([NSURL URLWithString:@"cydia://home"], NULL));
    Expect(![CydiaUIEvaluateRoute(homeDescriptor, forgedContext) isAllowed],
        @"route-context subclass cannot forge typed route authority");
    Expect([CydiaUIEvaluateRoute(homeDescriptor, context) isAllowed],
        @"live in-process capability authorizes typed route");

    CydiaLegacyBridgeAuthorization *read(CydiaLegacyBridgeAuthorize(Request(
        @"Package", CydiaLegacyBridgeMemberKindAttribute, @"name", context,
        capability, @"fixture.package")));
    Expect([read isAllowed], @"live exact capability authorizes safe read");

    Expect(![CydiaLegacyBridgeAuthorize(Request(@"Package",
        CydiaLegacyBridgeMemberKindAttribute, @"name", context, nil,
        @"fixture.package")) isAllowed], @"missing request capability denied");
    Expect(![CydiaLegacyBridgeAuthorize(Request(@"Package",
        CydiaLegacyBridgeMemberKindAttribute, @"name", context,
        [[NSObject alloc] init], @"fixture.package")) isAllowed],
        @"forged token denied");
    Expect(![CydiaLegacyBridgeAuthorize(Request(@"CyteObject",
        CydiaLegacyBridgeMemberKindMethod, @"getKernelString", context,
        capability, nil)) isAllowed], @"sensitive member denied");
    Expect(![CydiaLegacyBridgeAuthorize(Request(@"CyteObject",
        CydiaLegacyBridgeMemberKindMethod, @"setButtonTitle", context,
        capability, nil)) isAllowed], @"chrome member denied");
    Expect(![CydiaLegacyBridgeAuthorize(Request(@"CyteObject",
        CydiaLegacyBridgeMemberKindMethod, @"setPasteboardString", context,
        capability, nil)) isAllowed], @"clipboard member denied");
    Expect(![CydiaLegacyBridgeAuthorize(Request(@"CydiaProgressData",
        CydiaLegacyBridgeMemberKindAttribute, @"events", context,
        capability, nil)) isAllowed], @"retired member denied");

    CydiaUIRouteContext *webContext([context contextForRedirectWithOrigin:
        [NSURL URLWithString:@"https://repo.example/depiction"]
        mainFrame:YES userGesture:YES]);
    Expect([webContext caller] == CydiaUIRouteCallerUntrustedWebPage &&
           [webContext inProcessCapability] == nil,
           @"web redirect strips in-process capability");

    [capability revoke];
    CydiaUIRouteDecision *revokedRouteDecision(
        CydiaUIEvaluateRoute(homeDescriptor, context));
    Expect(![capability isValid] &&
           [CydiaUIRouteContext trustedInProcessContextWithCapability:capability] == nil &&
           ![revokedRouteDecision isAllowed] &&
           [revokedRouteDecision denialReason] ==
                CydiaUIRouteDenialReasonCaller &&
           ![CydiaLegacyBridgeAuthorize(read == nil ? nil : Request(@"Package",
                CydiaLegacyBridgeMemberKindAttribute, @"name", context,
                capability, @"fixture.package")) isAllowed],
           @"revoked capability fails context and policy");

    __strong CydiaLegacyUICompatibilityNativeCapability *expired(nil);
    @autoreleasepool {
        id shortLived(CydiaIssuer());
        expired = [CydiaLegacyUICompatibilityNativeCaller
            issueCapabilityForApplication:shortLived];
        Expect([expired isValid], @"short-lived issuer initially valid");
    }
    Expect(![expired isValid] &&
           [CydiaUIRouteContext trustedInProcessContextWithCapability:expired] == nil,
           @"weak issuer lifetime expires capability");
}

void VerifyExecutionObservations(void) {
    id application(CydiaIssuer());
    NativeTestProvider *provider([[NativeTestProvider alloc] init]);
    auto capability([CydiaLegacyUICompatibilityNativeCaller
        issueCapabilityForApplication:application]);
    auto caller([[CydiaLegacyUICompatibilityNativeCaller alloc]
        initWithCapability:capability reader:provider commander:provider router:provider]);
    NSObject *presenter([[NSObject alloc] init]);
    auto package([caller sessionForScope:@"Package" target:[[NSObject alloc] init]
        packageIdentity:@"fixture.package" sourceKey:nil presenter:presenter]);
    Expect([[package invokeScope:@"Package" memberKind:CydiaLegacyBridgeMemberKindAttribute
        memberName:@"name" arguments:@[] targetOrigin:nil] isEqual:@"Fixture Package"] &&
        [package executorEntryCount] == 1 && [provider readCount] == 1,
        @"defined read enters the executor and provider once");
    Expect(IsUndefined([package invokeScope:@"Package"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"longDescription"
        arguments:@[] targetOrigin:nil]) && [package executorEntryCount] == 2 &&
        [package denialCount] == 0 && [provider readCount] == 2,
        @"undefined read still enters the real provider once without rejection");
    auto dictionary([caller sessionForScope:@"NSDictionary" target:@{}
        packageIdentity:nil sourceKey:nil presenter:presenter]);
    Expect(IsUndefined([dictionary invokeScope:@"NSDictionary"
        memberKind:CydiaLegacyBridgeMemberKindDynamicMethod memberName:@"get"
        arguments:@[@"missing"] targetOrigin:nil]) &&
        [dictionary executorEntryCount] == 1 && [dictionary denialCount] == 0,
        @"absent dictionary key is an executed read, not a missing target");
    auto applicationSession([caller sessionForScope:@"CydiaObject" target:application
        packageIdentity:nil sourceKey:nil presenter:presenter]);
    NSUInteger denied(0);
    for (CydiaLegacyBridgeMember *member in CydiaLegacyBridgeMembers()) {
        auto family([member family]);
        if (family != CydiaLegacyBridgeOperationFamilySensitive &&
            family != CydiaLegacyBridgeOperationFamilyChrome &&
            family != CydiaLegacyBridgeOperationFamilyClipboard &&
            family != CydiaLegacyBridgeOperationFamilyRetired &&
            !(family == CydiaLegacyBridgeOperationFamilySession &&
                ![[member name] isEqualToString:@"getSessionValue"]) &&
            [member trustedLegacyRequirement] != CydiaLegacyBridgeAccessRequirementDenied &&
            [member trustedLegacyRequirement] != CydiaLegacyBridgeAccessRequirementRetired)
            continue;
        auto signature(CydiaLegacyUICompatibilitySignatureForMember(
            [member scope], [member kind], [member name]));
        NSMutableArray *arguments([NSMutableArray array]);
        for (NSNumber *kind in [signature argumentKinds]) {
            id argument([NSNull null]);
            switch ([kind unsignedIntegerValue]) {
                case CydiaLegacyUIArgumentKindString:
                case CydiaLegacyUIArgumentKindOpaque:
                    argument = @"fixture"; break;
                case CydiaLegacyUIArgumentKindNumber: argument = @0; break;
                case CydiaLegacyUIArgumentKindBooleanLike: argument = @NO; break;
                case CydiaLegacyUIArgumentKindSequence: argument = @[]; break;
                case CydiaLegacyUIArgumentKindURLString:
                    argument = @"https://fixture.invalid/"; break;
                case CydiaLegacyUIArgumentKindMetadataKey:
                    argument = @"fixture.key"; break;
                default: break; // Optional arguments deliberately remain null.
            }
            [arguments addObject:argument];
        }
        auto service([applicationSession service]);
        auto decision([service decisionForScope:[member scope] memberKind:[member kind]
            memberName:[member name] arguments:arguments targetOrigin:nil]);
        Expect(![decision isAllowed] && [applicationSession executorEntryCount] == 0,
            @"decision-only queries never enter an executor");
        id result([service invokeScope:[member scope] memberKind:[member kind]
            memberName:[member name] arguments:arguments targetOrigin:nil]);
        Expect((result == [decision unavailableValue] || [result isEqual:[decision unavailableValue]]) &&
            [applicationSession executorEntryCount] == 0 && [provider readCount] == 2 &&
            [provider mutationCount] == 0 && [provider globalReadCount] == 0 &&
            [provider sessionReadCount] == 0 && [provider routeCount] == 0,
            [NSString stringWithFormat:@"denied %@.%@ returns typed unavailable with no executor/provider entry",
                [member scope], [member name]]);
        ++denied;
    }
    Expect(denied == 65, @"all 65 denied names actually attempt the bound service");
    Expect(IsUndefined([package invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"label"
        arguments:@[] targetOrigin:nil]) && [package executorEntryCount] == 2 &&
        [package denialCount] == 1,
        @"out-of-scope boundary attempt rejects before executor entry");
    NSUInteger entries([package executorEntryCount]);
    [package invokeScope:@"Package" memberKind:CydiaLegacyBridgeMemberKindMethod
        memberName:@"install" arguments:@[] targetOrigin:nil];
    Expect([package executorEntryCount] == entries + 1 && [provider mutationCount] == 1,
        @"confirmation executor entry is counted independently of its result kind");
    [package invalidate];
    Expect(IsUndefined([package invokeScope:@"Package"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"name"
        arguments:@[] targetOrigin:nil]) && [package executorEntryCount] == entries + 1 &&
        [package denialCount] == 2,
        @"revoked session increments rejection count without executor entry");
}

void VerifySession(void) {
    id application(CydiaIssuer());
    NativeTestProvider *provider([[NativeTestProvider alloc] init]);
    CydiaLegacyUICompatibilityNativeCapability *capability(
        [CydiaLegacyUICompatibilityNativeCaller
            issueCapabilityForApplication:application]);
    CydiaLegacyUICompatibilityNativeCaller *caller(
        [[CydiaLegacyUICompatibilityNativeCaller alloc]
            initWithCapability:capability reader:provider commander:provider
            router:provider]);
    NSObject *target([[NSObject alloc] init]);
    NSObject *presenter([[NSObject alloc] init]);

    Expect(caller != nil && [caller isActive], @"caller retains live providers");
    Expect([caller sessionForScope:@"Package" target:nil
        packageIdentity:@"fixture.package" sourceKey:nil presenter:presenter] == nil,
        @"package target required");
    Expect([caller sessionForScope:@"Package" target:target
        packageIdentity:@"fixture.package" sourceKey:nil presenter:nil] == nil,
        @"native session requires a presenter");
    Expect([caller sessionForScope:@"Package" target:target
        packageIdentity:@"../fixture" sourceKey:nil presenter:presenter] == nil,
        @"unsafe package identity denied");

    NSMutableDictionary *mutableTarget(
        [@{ @"fixture": @"before" } mutableCopy]);
    CydiaLegacyUICompatibilityNativeSession *dictionarySession([caller
        sessionForScope:@"NSDictionary" target:mutableTarget
        packageIdentity:nil sourceKey:nil presenter:presenter]);
    [mutableTarget setObject:@"after" forKey:@"fixture"];
    id frozenValue([dictionarySession invokeScope:@"NSDictionary"
        memberKind:CydiaLegacyBridgeMemberKindDynamicMethod memberName:@"get"
        arguments:@[@"fixture"] targetOrigin:nil]);
    Expect([frozenValue isEqualToString:@"before"],
        @"dictionary session reads an immutable creation-time snapshot");
    Expect([caller sessionForScope:@"Source" target:target packageIdentity:nil
        sourceKey:@"not-a-source-key" presenter:presenter] == nil,
        @"malformed source key denied");
    Expect([caller sessionForScope:@"Package" target:target
        packageIdentity:@"fixture.package" sourceKey:@"deb:https://repo.example/:./"
        presenter:presenter] == nil, @"package/source identity cannot mix");

    CydiaLegacyUICompatibilityNativeSession *session([caller
        sessionForScope:@"Package" target:target
        packageIdentity:@"fixture.package" sourceKey:nil presenter:presenter]);
    Expect(session != nil && [session isActive] && [session target] == target &&
           [[session packageIdentity] isEqualToString:@"fixture.package"] &&
           [session presenter] == presenter && [[session service] isExecutable],
           @"session strongly binds executor, target, identity, and presenter");

    id packageName([session invokeScope:@"Package"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"name"
        arguments:@[] targetOrigin:nil]);
    Expect([packageName isEqualToString:@"Fixture Package"] &&
           [provider readCount] == 1 && [provider lastTarget] == target,
           @"safe package read reaches typed provider");

    id crossScope([session invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"label"
        arguments:@[] targetOrigin:nil]);
    Expect(IsUndefined(crossScope) &&
           [session lastDenialReason] ==
                CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget &&
           [provider readCount] == 1,
           @"cross-scope execution cannot reach provider");
    Expect(![[session decisionForScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"label"
        arguments:@[] targetOrigin:nil] isAllowed],
        @"cross-scope decision fails closed");

    id sensitive([session invokeScope:@"Package"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"notAnAPI"
        arguments:@[] targetOrigin:nil]);
    Expect(IsUndefined(sensitive) && [provider readCount] == 1,
           @"unsupported member never reaches provider");

    id accepted([session invokeScope:@"Package"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"install"
        arguments:@[] targetOrigin:nil]);
    Expect(IsUndefined(accepted) && [provider mutationCount] == 1 &&
           [provider mutationOnMainThread] && [provider lastTarget] == target &&
           [[provider lastIdentity] isEqualToString:@"fixture.package"],
           @"package mutation uses typed one-shot confirmation on main thread");

    CydiaLegacyUICompatibilityInvocation *invocation(
        Invocation(session, @"Package", @"install"));
    NSUInteger mutationsBeforeRetry([provider mutationCount]);
    provider.rejectNextMutation = YES;
    provider.reentrantInvocation = invocation;
    Expect(![session legacyUICompatibilityService:[session service]
        requestNativeConfirmationForInvocation:invocation] &&
        [provider mutationCount] == mutationsBeforeRetry + 1 &&
        ![provider reentrantAccepted] &&
        [provider reentrantDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonAlreadyRequested,
        @"in-flight invocation is reserved while provider rejects transiently");
    Expect([session legacyUICompatibilityService:[session service]
        requestNativeConfirmationForInvocation:invocation] &&
        [provider mutationCount] == mutationsBeforeRetry + 2,
        @"provider rejection releases the invocation for retry");
    Expect(![session legacyUICompatibilityService:[session service]
        requestNativeConfirmationForInvocation:invocation] &&
        [provider mutationCount] == mutationsBeforeRetry + 2 &&
        [session lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonAlreadyRequested,
        @"accepted invocation remains one-shot");

    CydiaLegacyUICompatibilityInvocation *unavailableInvocation(
        Invocation(session, @"Package", @"install"));
    NSUInteger mutationsBeforeUnavailable([provider mutationCount]);
    provider.packageMutationUnavailable = YES;
    Expect(![session legacyUICompatibilityService:[session service]
        requestNativeConfirmationForInvocation:unavailableInvocation] &&
        [provider mutationCount] == mutationsBeforeUnavailable,
        @"missing optional commander callback rejects before acceptance");
    provider.packageMutationUnavailable = NO;
    Expect([session legacyUICompatibilityService:[session service]
        requestNativeConfirmationForInvocation:unavailableInvocation] &&
        [provider mutationCount] == mutationsBeforeUnavailable + 1 &&
        ![session legacyUICompatibilityService:[session service]
            requestNativeConfirmationForInvocation:unavailableInvocation] &&
        [provider mutationCount] == mutationsBeforeUnavailable + 1 &&
        [session lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonAlreadyRequested,
        @"commander availability retry accepts once and then denies replay");

    CydiaLegacyUICompatibilityInvocation *foreign(
        [[CydiaLegacyUICompatibilityInvocation alloc]
            initWithScope:@"Package" memberKind:CydiaLegacyBridgeMemberKindMethod
            memberName:@"install" context:[session context] callingOrigin:nil
            packageIdentity:@"other.package" targetOrigin:nil arguments:@[]]);
    Expect(![session legacyUICompatibilityService:[session service]
        requestNativeConfirmationForInvocation:foreign],
        @"mismatched package identity cannot confirm");

    Expect([session handoffRouteURL:[NSURL URLWithString:@"cydia://package/demo"]] &&
           [provider routeCount] == 1 && [[session lastRouteResult] isAllowed],
           @"read-only package route hands off typed descriptor");
    Expect([session handoffRouteURL:[NSURL URLWithString:
        @"cydia://sources/deb%3Ahttps%3A%2F%2Frepo.example%2F%3A.%2F"]] &&
        [provider routeCount] == 2, @"known source route hands off");
    Expect(![session handoffRouteURL:[NSURL URLWithString:
        @"cydia://sources/deb%3Ahttps%3A%2F%2Funknown.example%2F%3A.%2F"]] &&
        ![[session lastRouteResult] isAllowed], @"unknown source route denied");
    Expect(![session handoffRouteURL:[NSURL URLWithString:@"cydia://launch/app"]],
           @"command route unavailable to compatibility session");

    NSUInteger readsBeforeInheritedLocalize([provider readCount]);
    CydiaLegacyUICompatibilityNativeSession *applicationSession([caller
        sessionForScope:@"CydiaObject" target:application
        packageIdentity:nil sourceKey:nil presenter:presenter]);
    Expect(applicationSession != nil && [applicationSession isActive],
           @"application session is available for inherited CyteObject reads");

    provider.metadataKeys = @[@"fixture.key", @"fixture.other"];
    provider.metadataValue = @{ @"nested": @[@"value"], @"number": @42 };
    NSUInteger globalReadsBeforeMetadata([provider globalReadCount]);
    id metadataKeys([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getMetadataKeys"
        arguments:@[] targetOrigin:nil]);
    Expect([metadataKeys isEqualToArray:provider.metadataKeys] &&
           [provider globalReadCount] == globalReadsBeforeMetadata + 1,
           @"metadata-key enumeration reaches the typed global reader");
    id metadataValue([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getMetadataValue"
        arguments:@[@"fixture.key"] targetOrigin:nil]);
    Expect([metadataValue isEqual:provider.metadataValue] &&
           [provider globalReadCount] == globalReadsBeforeMetadata + 2,
           @"metadata-value lookup reaches the typed global reader");
    id missingMetadataValue([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getMetadataValue"
        arguments:@[@"fixture.missing"] targetOrigin:nil]);
    Expect(IsUndefined(missingMetadataValue) &&
           [provider globalReadCount] == globalReadsBeforeMetadata + 3,
           @"missing metadata values preserve the undefined convention");
    id malformedMetadataRead([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getMetadataValue"
        arguments:@[@""] targetOrigin:nil]);
    Expect(IsUndefined(malformedMetadataRead) &&
           [provider globalReadCount] == globalReadsBeforeMetadata + 3,
           @"malformed metadata keys fail before global provider dispatch");

    NSUInteger globalReadsBeforeSession([provider globalReadCount]);
    provider.sessionValue = @"Fixture Session";
    id sessionValue([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getSessionValue"
        arguments:@[@"fixture-key"] targetOrigin:nil]);
    Expect([sessionValue isEqualToString:@"Fixture Session"] &&
           [provider sessionReadCount] == 1 &&
           [provider globalReadCount] == globalReadsBeforeSession &&
           [[provider lastSessionKey] isEqualToString:@"fixture-key"],
           @"session-family CydiaObject reads use the typed session callback");

    id metadataResult([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"setMetadataValue"
        arguments:@[@"fixture.key", @{ @"nested": @[@"value"] }]
        targetOrigin:nil]);
    Expect(IsUndefined(metadataResult) &&
           [provider metadataMutationCount] == 1 &&
           [provider metadataOnMainThread] &&
           [[provider lastMetadataKey] isEqualToString:@"fixture.key"] &&
           ![provider metadataRemoving] &&
           [[[provider lastMetadataValue] objectForKey:@"nested"]
               isEqual:@[ @"value" ]],
           @"metadata writer reaches the dedicated typed native command");
    id malformedMetadata([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"setMetadataValue"
        arguments:@[@"fixture.key", [[NSObject alloc] init]] targetOrigin:nil]);
    Expect(IsUndefined(malformedMetadata) &&
           [provider metadataMutationCount] == 1,
           @"non-property-list metadata never reaches the command provider");
    CydiaLegacyUICompatibilityInvocation *metadataInvocation(
        [[CydiaLegacyUICompatibilityInvocation alloc]
            initWithScope:@"CydiaObject"
            memberKind:CydiaLegacyBridgeMemberKindMethod
            memberName:@"setMetadataValue" context:[applicationSession context]
            callingOrigin:nil packageIdentity:nil targetOrigin:nil
            arguments:@[@"fixture.remove", [NSNull null]]]);
    Expect([applicationSession legacyUICompatibilityService:[applicationSession service]
        requestNativeConfirmationForInvocation:metadataInvocation] &&
           [provider metadataMutationCount] == 2 &&
           [provider metadataRemoving] &&
           ![applicationSession legacyUICompatibilityService:[applicationSession service]
        requestNativeConfirmationForInvocation:metadataInvocation] &&
           [applicationSession lastDenialReason] ==
               CydiaLegacyUICompatibilityNativeDenialReasonAlreadyRequested,
           @"metadata confirmation invocation is one-shot");
    id malformedSessionValue([applicationSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getSessionValue"
        arguments:@[] targetOrigin:nil]);
    Expect(IsUndefined(malformedSessionValue) &&
           [provider sessionReadCount] == 1 &&
           [provider globalReadCount] == globalReadsBeforeSession,
           @"session value argument shape fails before either provider callback");

    id inheritedLocalize([applicationSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"localize"
        arguments:@[@"NATIVE_LOCALIZE_MISSING", @"Inherited fallback",
            [CydiaLegacyUIUndefinedValue value]] targetOrigin:nil]);
    Expect([inheritedLocalize isEqualToString:@"Inherited fallback"] &&
           [provider readCount] == readsBeforeInheritedLocalize + 1,
           @"CydiaObject session reaches only its inherited localize renderer");
    NSUInteger readsBeforeInheritedDenial([provider readCount]);
    id inheritedSupports([applicationSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"supports"
        arguments:@[@"window.open"] targetOrigin:nil]);
    Expect(IsUndefined(inheritedSupports) &&
           [applicationSession lastDenialReason] ==
               CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget &&
           [provider readCount] == readsBeforeInheritedDenial,
           @"inherited scope does not widen to other CyteObject renderers");
    id inheritedReachability([applicationSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"isReachable"
        arguments:@[@"repo.example"] targetOrigin:nil]);
    Expect(IsUndefined(inheritedReachability) &&
           [applicationSession lastDenialReason] ==
               CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget &&
           [provider readCount] == readsBeforeInheritedDenial,
           @"CydiaObject inheritance cannot expose reachability");
    NSUInteger readsBeforeInheritedFormat([provider readCount]);
    id inheritedFormat([applicationSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"format"
        arguments:@[@"Inherited %@", @[@"format"]] targetOrigin:nil]);
    Expect([inheritedFormat isEqualToString:@"Inherited format"] &&
           [provider readCount] == readsBeforeInheritedFormat + 1,
           @"CydiaObject session reaches only its inherited format renderer");
    id malformedInheritedFormat([applicationSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"format"
        arguments:@[@"%s", @[@"format"]] targetOrigin:nil]);
    Expect(IsUndefined(malformedInheritedFormat) &&
           [provider readCount] == readsBeforeInheritedFormat + 2,
           @"unsupported format grammar fails closed through the typed renderer");
    Expect(![applicationSession decisionForScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"format"
        arguments:@[@"%@"] targetOrigin:nil].isAllowed,
           @"inherited format requires exactly two outer arguments");

    CydiaLegacyUICompatibilityNativeSession *renderingSession([caller
        sessionForScope:@"CyteObject" target:application packageIdentity:nil
        sourceKey:nil presenter:presenter]);
    Expect(renderingSession != nil && [renderingSession isActive] &&
           [renderingSession target] == application &&
           [renderingSession presenter] == presenter &&
           [[renderingSession targetScope] isEqualToString:@"CyteObject"],
           @"explicit rendering session binds the exact app target and presenter");
    NSUInteger renderingReadsBefore([provider readCount]);
    id supportsWindowOpen([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"supports"
        arguments:@[@"window.open"] targetOrigin:nil]);
    id supportsUnknown([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"supports"
        arguments:@[@"window.location"] targetOrigin:nil]);
    id reachable([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"isReachable"
        arguments:@[@"repo.example"] targetOrigin:nil]);
    id malformedReachability([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"isReachable"
        arguments:@[@"https://repo.example/"] targetOrigin:nil]);
    Expect([supportsWindowOpen boolValue] && ![supportsUnknown boolValue] &&
           [reachable isEqual:@NO] && [malformedReachability isEqual:@NO] &&
           [provider readCount] == renderingReadsBefore + 4,
           @"rendering supports/isReachable use deterministic bounded results");
    NSUInteger renderingReadsBeforeShape([provider readCount]);
    id malformedSupportsZero([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"supports"
        arguments:@[] targetOrigin:nil]);
    id malformedSupportsTwo([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"supports"
        arguments:@[@"window.open", @"extra"] targetOrigin:nil]);
    Expect([malformedSupportsZero isEqual:@NO] && [malformedSupportsTwo isEqual:@NO] &&
           [provider readCount] == renderingReadsBeforeShape,
           @"supports rejects every argument shape except one string before provider dispatch");
    NSUInteger renderingReadsBeforeLocale([provider readCount]);
    id locale([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getLocaleIdentifier"
        arguments:@[] targetOrigin:nil]);
    id languages([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getPreferredLanguages"
        arguments:@[] targetOrigin:nil]);
    Expect([locale isKindOfClass:[NSString class]] &&
           [languages isKindOfClass:[NSArray class]] &&
           [provider readCount] == renderingReadsBeforeLocale,
           @"zero-argument locale rendering remains deterministic and provider-free");
    id renderingLocalize([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"localize"
        arguments:@[@"NATIVE_LOCALIZE_MISSING", @"Rendering fallback", [NSNull null]]
        targetOrigin:nil]);
    id renderingFormat([renderingSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"format"
        arguments:@[@"Rendering %@", @[@"format"]] targetOrigin:nil]);
    Expect([renderingLocalize isEqualToString:@"Rendering fallback"] &&
           [renderingFormat isEqualToString:@"Rendering format"] &&
           [provider readCount] == renderingReadsBeforeLocale + 2,
           @"rendering localize/format retain their historical argument shapes");
    NSUInteger renderingReadsBeforeCrossScope([provider readCount]);
    id renderingCrossScope([renderingSession invokeScope:@"CydiaObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"getAllSources"
        arguments:@[] targetOrigin:nil]);
    Expect(IsUndefined(renderingCrossScope) &&
           [renderingSession lastDenialReason] ==
               CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget &&
           [provider readCount] == renderingReadsBeforeCrossScope,
           @"rendering session cannot cross into the CydiaObject scope");
    CydiaLegacyUICompatibilityNativeSession *forgedApplicationSession([caller
        sessionForScope:@"CydiaObject" target:[[NSObject alloc] init]
        packageIdentity:nil sourceKey:nil presenter:presenter]);
    Expect(forgedApplicationSession != nil,
           @"caller can construct a session before target-bound execution checks");
    id forgedLocalize([forgedApplicationSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"localize"
        arguments:@[@"NATIVE_LOCALIZE_MISSING", @"forged", [NSNull null]]
        targetOrigin:nil]);
    Expect(IsUndefined(forgedLocalize) &&
           [forgedApplicationSession lastDenialReason] ==
               CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget,
           @"inherited localize requires the exact app-owned target");
    id forgedFormat([forgedApplicationSession invokeScope:@"CyteObject"
        memberKind:CydiaLegacyBridgeMemberKindMethod memberName:@"format"
        arguments:@[@"%@", @[@"forged"]] targetOrigin:nil]);
    Expect(IsUndefined(forgedFormat) &&
           [forgedApplicationSession lastDenialReason] ==
               CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget,
           @"inherited format requires the exact app-owned target and capability");

    CydiaLegacyUICompatibilityNativeSession *revokedRouteSession([caller
        sessionForScope:@"Package" target:target
        packageIdentity:@"fixture.package" sourceKey:nil presenter:presenter]);
    NSUInteger routeCount([provider routeCount]);
    [provider setRevokeDuringSourceLookup:YES];
    Expect(![revokedRouteSession handoffRouteURL:[NSURL URLWithString:
        @"cydia://sources/deb%3Ahttps%3A%2F%2Frepo.example%2F%3A.%2F"]] &&
        ![revokedRouteSession isActive] && [provider routeCount] == routeCount &&
        [revokedRouteSession lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability,
        @"route revocation during source lookup blocks final handoff");
    [provider setRevokeDuringSourceLookup:NO];

    CydiaUIRouteContext *depiction([CydiaUIRouteContext
        repositoryDepictionContextWithOrigin:[NSURL URLWithString:@"https://repo.example/"]
        packageIdentity:@"fixture.package" mainFrame:YES userGesture:YES]);
    Expect([caller sessionForScope:@"Package" target:target
        packageIdentity:@"fixture.package" sourceKey:nil presenter:presenter
        context:depiction] == nil, @"depiction cannot impersonate native caller");

    [caller invalidate];
    Expect(![caller isActive] && ![session isActive] && ![capability isValid] &&
           ![[session decisionForScope:@"Package"
                memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"name"
                arguments:@[] targetOrigin:nil] isAllowed] &&
           IsUndefined([session invokeScope:@"Package"
                memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"name"
                arguments:@[] targetOrigin:nil]),
           @"caller invalidation revokes sessions and decisions");
}

void VerifyFourPackageMutationEntries(void) {
    id application(CydiaIssuer());
    NativePackageCommandProvider *provider([[NativePackageCommandProvider alloc] init]);
    CydiaLegacyUICompatibilityNativeCaller *caller(
        [[CydiaLegacyUICompatibilityNativeCaller alloc]
            initWithCapability:[CydiaLegacyUICompatibilityNativeCaller
                issueCapabilityForApplication:application]
            reader:provider commander:provider router:provider]);
    id fixture([[NSObject alloc] init]);
    id presenter([[NSObject alloc] init]);
    CydiaLegacyUICompatibilityNativeSession *package([caller sessionForScope:@"Package"
        target:fixture packageIdentity:@"com.torrekie.cydia-ui-transaction-fixture"
        sourceKey:nil presenter:presenter]);
    for (NSString *member in @[@"clear", @"install", @"remove"]) {
        NSUInteger before([package executorEntryCount]);
        NSUInteger effects([provider mutationCount]);
        id result([package invokeScope:@"Package" memberKind:CydiaLegacyBridgeMemberKindMethod
            memberName:member arguments:@[] targetOrigin:nil]);
        Expect(IsUndefined(result) && [package executorEntryCount] == before + 1 &&
            [provider mutationCount] == effects + 1 && [provider mutationOnMainThread] &&
            [package lastDenialReason] == CydiaLegacyUICompatibilityNativeDenialReasonNone &&
            [provider lastTarget] == fixture && [[provider lastMutationMember] isEqualToString:member] &&
            [[provider lastMutationArguments] count] == 0,
            @"all three void package APIs reach one typed executor/provider request");
    }
    CydiaLegacyUICompatibilityNativeSession *app([caller sessionForScope:@"CydiaObject"
        target:application packageIdentity:nil sourceKey:nil presenter:presenter]);
    id result([app invokeScope:@"CydiaObject" memberKind:CydiaLegacyBridgeMemberKindMethod
        memberName:@"installPackages" arguments:@[@[fixture]] targetOrigin:nil]);
    Expect(IsUndefined(result) && [app executorEntryCount] == 1 &&
        [provider mutationCount] == 4 && [provider lastTarget] == application &&
        [app lastDenialReason] == CydiaLegacyUICompatibilityNativeDenialReasonNone &&
        [[provider lastMutationMember] isEqualToString:@"installPackages"] &&
        [[provider lastMutationArguments] count] == 1 &&
        [[provider lastMutationArguments][0] count] == 1 &&
        [provider lastMutationArguments][0][0] == fixture,
        @"batch install keeps the exact fixture object in its one sequence argument");
}

void VerifyWeakExecutorLifetime(void) {
    CydiaLegacyUICompatibilityService *service(nil);
    @autoreleasepool {
        id application(CydiaIssuer());
        NativeTestProvider *provider([[NativeTestProvider alloc] init]);
        CydiaLegacyUICompatibilityNativeCapability *capability(
            [CydiaLegacyUICompatibilityNativeCaller
                issueCapabilityForApplication:application]);
        CydiaLegacyUICompatibilityNativeCaller *caller(
            [[CydiaLegacyUICompatibilityNativeCaller alloc]
                initWithCapability:capability reader:provider commander:provider
                router:provider]);
        CydiaLegacyUICompatibilityNativeSession *session([caller
            sessionForScope:@"CydiaObject" target:application packageIdentity:nil
            sourceKey:nil presenter:[[NSObject alloc] init]]);
        Expect(session != nil && [[session service] isExecutable],
               @"service starts with a live executor");
        service = [session service];
        /* Caller invalidation deliberately clears its session table. */
        [caller invalidate];
    }
    Expect(![service isExecutable],
           @"weak executor expires after owner/session lifetime");
}

void VerifyExplicitFinalSessionRelease(void) {
    id application(CydiaIssuer());
    for (NSString *scope in @[@"Package", @"Source", @"CydiaObject"]) {
        __weak CydiaLegacyUICompatibilityNativeSession *weakSession(nil);
        __weak CydiaLegacyUICompatibilityNativeCaller *weakOwner(nil);
        CydiaLegacyUICompatibilityService *service(nil);
        const BOOL metadata([scope isEqualToString:@"CydiaObject"]);
        NSString *member(metadata ? @"getMetadataValue" :
            ([scope isEqualToString:@"Package"] ? @"name" : @"label"));
        auto kind(metadata ? CydiaLegacyBridgeMemberKindMethod : CydiaLegacyBridgeMemberKindAttribute);
        NSArray *arguments(metadata ? @[@"fixture.key"] : @[]);
        @autoreleasepool {
            NativeTestProvider *provider([[NativeTestProvider alloc] init]);
            provider.metadataValue = @"fixture-value";
            auto capability([CydiaLegacyUICompatibilityNativeCaller issueCapabilityForApplication:application]);
            CydiaLegacyUICompatibilityNativeCaller *owner(
                [[CydiaLegacyUICompatibilityNativeCaller alloc] initWithCapability:capability
                    reader:provider commander:provider router:provider]);
            CydiaLegacyUICompatibilityNativeSession *session([owner sessionForScope:scope
                target:metadata ? application : [[NSObject alloc] init]
                packageIdentity:[scope isEqualToString:@"Package"] ? @"fixture.package" : nil
                sourceKey:[scope isEqualToString:@"Source"] ? @"deb:https://repo.example/:./" : nil
                presenter:[[NSObject alloc] init]]);
            weakOwner = owner;
            weakSession = session;
            service = [session service];
            session = nil;
            Expect(weakSession != nil && [weakSession isActive], @"owner retains session without a local strong reference");
            session = weakSession;
            id value([session invokeScope:scope memberKind:kind memberName:member
                arguments:arguments targetOrigin:nil]);
            Expect(value != nil && !IsUndefined(value) && [session executorEntryCount] == 1,
                @"retained package/source/metadata session executes one typed read");
            [owner invalidate];
            Expect(IsUndefined([session invokeScope:scope memberKind:kind memberName:member
                arguments:arguments targetOrigin:nil]) && [session executorEntryCount] == 1 &&
                [session lastDenialReason] == CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability,
                @"owner invalidation rejects without a second provider entry");
            session = nil;
            owner = nil;
        }
        Expect(weakSession == nil && weakOwner == nil, @"final strong-reference removal deallocates owned session and caller");
        Expect(![service isExecutable] && IsUndefined([service invokeScope:scope
            memberKind:kind memberName:member arguments:arguments targetOrigin:nil]),
            @"retained service cannot execute after session deallocation");
    }
}

} // namespace

int main(void) {
    @autoreleasepool {
        VerifyIssuanceAndPolicy();
        VerifyExecutionObservations();
        VerifySession();
        VerifyFourPackageMutationEntries();
        VerifyWeakExecutorLifetime();
        VerifyExplicitFinalSessionRelease();
        std::cout << "[verify-legacy-ui-compatibility-native][ ok ] "
                  << "capability, target binding, typed dispatch, confirmation, and routes"
                  << std::endl;
    }
    return 0;
}
