/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibilityNativeCaller.h"

#include <objc/runtime.h>

@interface CydiaLegacyUICompatibilityNativeSnapshot (NativeCallerBinding)
- (BOOL) isBoundToSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
@end

@interface CydiaLegacyUICompatibilityNativeCapability (NativeCallerBinding)
- (BOOL) _isIssuedForApplication:(id)application;
@end

namespace {

BOOL ExactRuntimeClass(id object, Class expected) {
    return object != nil && expected != Nil && object_getClass(object) == expected;
}

BOOL IsSafeIdentity(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0 ||
        [value isEqualToString:@"."] || [value isEqualToString:@".."])
        return NO;
    return [value rangeOfString:@"/"].location == NSNotFound &&
        [value rangeOfString:@"\\"].location == NSNotFound &&
        [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location ==
            NSNotFound;
}

BOOL IsSafeSourceKey(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0 ||
        [value length] > 2048 ||
        [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound ||
        [value rangeOfString:@"\\"].location != NSNotFound)
        return NO;
    /* Source keys are generated as type:URI:distribution.  Keep the key
     * opaque to providers, but reject unrelated strings at this boundary. */
    if (![value hasPrefix:@"deb:"] && ![value hasPrefix:@"deb-src:"])
        return NO;
    NSArray *parts([value componentsSeparatedByString:@":"]);
    return [parts count] >= 3 && [[parts objectAtIndex:0] length] != 0 &&
        [[parts objectAtIndex:1] length] != 0 && [[parts lastObject] length] != 0;
}

BOOL OptionalStringEqual(NSString *left, NSString *right) {
    return left == right || (left != nil && right != nil && [left isEqualToString:right]);
}

BOOL IsBoundContext(CydiaUIRouteContext *context,
                    CydiaLegacyUICompatibilityNativeCapability *capability) {
    return ExactRuntimeClass(context, [CydiaUIRouteContext class]) &&
        [context caller] == CydiaUIRouteCallerTrustedInProcess &&
        [context inProcessCapability] == capability &&
        [context initiatingOrigin] == nil &&
        [context depictionPackageIdentity] == nil && [context isMainFrame];
}

BOOL InvokeBooleanSelector(id object, SEL selector) {
    if (object == nil || selector == NULL || ![object respondsToSelector:selector])
        return NO;
    NSMethodSignature *signature([object methodSignatureForSelector:selector]);
    if (signature == nil || [signature numberOfArguments] != 2)
        return NO;
    const char *returnType([signature methodReturnType]);
    if (returnType == NULL)
        return NO;
    NSInvocation *invocation([NSInvocation invocationWithMethodSignature:signature]);
    [invocation setTarget:object];
    [invocation setSelector:selector];
    @try {
        [invocation invoke];
        if ((returnType[0] == 'B' || returnType[0] == 'c' || returnType[0] == 'C') &&
            [signature methodReturnLength] <= sizeof(BOOL)) {
            BOOL value(NO);
            [invocation getReturnValue:&value];
            return value;
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    return NO;
}

BOOL CapabilityIsValid(id capability) {
    if (capability == nil)
        return NO;
    Class cls(NSClassFromString(
        @"CydiaLegacyUICompatibilityNativeCapability"));
    SEL selector(NSSelectorFromString(@"_isValidForLegacyBridge"));
    if (!ExactRuntimeClass(capability, cls) ||
        ![capability respondsToSelector:selector])
        return NO;
    return InvokeBooleanSelector(capability, selector);
}

BOOL ApplicationMayIssue(id application) {
    if (application == nil)
        return NO;
    /* Only the shipped Cydia application object may mint this authority.
     * Exact class identity prevents a depiction/web object or subclass from
     * opting in by merely implementing a marker selector.  The private
     * application-owned predicate additionally rejects another exact-class
     * instance that is not the running UIApplication singleton. */
    Class cydiaClass(NSClassFromString(@"Cydia"));
    SEL selector(NSSelectorFromString(
        @"cydiaLegacyUICompatibilityApplicationMayIssueCapability"));
    return ExactRuntimeClass(application, cydiaClass) &&
        InvokeBooleanSelector(application, selector);
}

BOOL IsBoundScope(NSString *scope) {
    return [@[@"CydiaObject", @"CyteObject", @"Package", @"Source",
              @"CydiaOperation", @"CydiaClause", @"CydiaRelation",
              @"MIMEAddress", @"NSDictionary"] containsObject:scope];
}

BOOL IsExactCydiaApplicationTarget(id target,
                                   CydiaLegacyUICompatibilityNativeCapability *capability) {
    Class cydiaClass(NSClassFromString(@"Cydia"));
    Class capabilityClass(NSClassFromString(
        @"CydiaLegacyUICompatibilityNativeCapability"));
    return ExactRuntimeClass(target, cydiaClass) &&
        ApplicationMayIssue(target) && ExactRuntimeClass(capability, capabilityClass) &&
        [capability _isIssuedForApplication:target];
}

/* CyteObject is the historical superclass of CydiaObject.  Keep that
 * inheritance explicit and deliberately narrow: the app-owned application
 * session may expose only the Foundation-only `localize` and `format`
 * renderers, while all other CyteObject methods still require a matching
 * CyteObject session and therefore cannot gain an accidental chrome/device
 * capability. */
BOOL IsInheritedCyteObjectLocalize(NSString *sessionScope,
                                   NSString *scope,
                                   CydiaLegacyBridgeMemberKind memberKind,
                                   NSString *memberName,
                                   id target,
                                   CydiaLegacyUICompatibilityNativeCapability *capability) {
    return [sessionScope isEqualToString:@"CydiaObject"] &&
        [scope isEqualToString:@"CyteObject"] &&
        memberKind == CydiaLegacyBridgeMemberKindMethod &&
        [memberName isEqualToString:@"localize"] &&
        IsExactCydiaApplicationTarget(target, capability);
}

BOOL IsInheritedCyteObjectFormat(NSString *sessionScope,
                                 NSString *scope,
                                 CydiaLegacyBridgeMemberKind memberKind,
                                 NSString *memberName,
                                 NSArray *arguments,
                                 id target,
                                 CydiaLegacyUICompatibilityNativeCapability *capability) {
    return [sessionScope isEqualToString:@"CydiaObject"] &&
        [scope isEqualToString:@"CyteObject"] &&
        memberKind == CydiaLegacyBridgeMemberKindMethod &&
        [memberName isEqualToString:@"format"] &&
        [arguments isKindOfClass:[NSArray class]] && [arguments count] == 2 &&
        IsExactCydiaApplicationTarget(target, capability);
}

BOOL IsInheritedCyteObjectRenderer(
    NSString *sessionScope, NSString *scope,
    CydiaLegacyBridgeMemberKind memberKind, NSString *memberName,
    NSArray *arguments, id target,
    CydiaLegacyUICompatibilityNativeCapability *capability) {
    return IsInheritedCyteObjectLocalize(sessionScope, scope, memberKind,
        memberName, target, capability) ||
        IsInheritedCyteObjectFormat(sessionScope, scope, memberKind, memberName,
            arguments, target, capability);
}

BOOL IsPackageScope(NSString *scope) {
    return [@[@"Package", @"CydiaOperation", @"CydiaClause",
              @"CydiaRelation", @"MIMEAddress"] containsObject:scope];
}

BOOL IsNestedSnapshotScope(NSString *scope) {
    return [@[@"CydiaOperation", @"CydiaClause", @"CydiaRelation",
              @"MIMEAddress"] containsObject:scope];
}

CydiaLegacyUICompatibilityNativeSnapshotKind SnapshotKindForScope(NSString *scope) {
    if ([scope isEqualToString:@"CydiaOperation"])
        return CydiaLegacyUICompatibilityNativeSnapshotKindOperation;
    if ([scope isEqualToString:@"CydiaClause"])
        return CydiaLegacyUICompatibilityNativeSnapshotKindClause;
    if ([scope isEqualToString:@"CydiaRelation"])
        return CydiaLegacyUICompatibilityNativeSnapshotKindRelation;
    return CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress;
}

NSString *SnapshotScope(CydiaLegacyUICompatibilityNativeSnapshot *snapshot) {
    switch ([snapshot kind]) {
        case CydiaLegacyUICompatibilityNativeSnapshotKindOperation:
            return @"CydiaOperation";
        case CydiaLegacyUICompatibilityNativeSnapshotKindClause:
            return @"CydiaClause";
        case CydiaLegacyUICompatibilityNativeSnapshotKindRelation:
            return @"CydiaRelation";
        case CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress:
            return @"MIMEAddress";
    }
    return nil;
}

BOOL SnapshotMemberAllowed(CydiaLegacyUICompatibilityNativeSnapshotKind kind,
                           NSString *memberName) {
    switch (kind) {
        case CydiaLegacyUICompatibilityNativeSnapshotKindOperation:
            return [@[@"operator", @"value"] containsObject:memberName];
        case CydiaLegacyUICompatibilityNativeSnapshotKindClause:
            return [@[@"package", @"version"] containsObject:memberName];
        case CydiaLegacyUICompatibilityNativeSnapshotKindRelation:
            return [@[@"clauses", @"relationship"] containsObject:memberName];
        case CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress:
            return [@[@"address", @"name"] containsObject:memberName];
    }
    return NO;
}

BOOL SnapshotAllowsInvocation(CydiaLegacyUICompatibilityNativeSnapshot *snapshot,
                              NSString *scope,
                              CydiaLegacyBridgeMemberKind memberKind,
                              NSString *memberName,
                              id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    return snapshot != nil && IsNestedSnapshotScope(scope) &&
        memberKind == CydiaLegacyBridgeMemberKindAttribute &&
        [snapshot kind] == SnapshotKindForScope(scope) &&
        SnapshotMemberAllowed([snapshot kind], memberName) &&
        [snapshot isBoundToSession:parent];
}

BOOL IsValidNestedResult(CydiaLegacyUICompatibilityNativeSnapshot *snapshot,
                         NSString *memberName,
                         id value,
                         id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    if (value == nil || value == [CydiaLegacyUIUndefinedValue value])
        return YES;
    switch ([snapshot kind]) {
        case CydiaLegacyUICompatibilityNativeSnapshotKindOperation:
        case CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress:
            return [value isKindOfClass:[NSString class]];
        case CydiaLegacyUICompatibilityNativeSnapshotKindClause:
            if ([memberName isEqualToString:@"package"])
                return [value isKindOfClass:[NSString class]];
            return value == [NSNull null] ||
                (ExactRuntimeClass(value, [CydiaLegacyUICompatibilityNativeSnapshot class]) &&
                 [(CydiaLegacyUICompatibilityNativeSnapshot *)value kind] ==
                     CydiaLegacyUICompatibilityNativeSnapshotKindOperation &&
                 [(CydiaLegacyUICompatibilityNativeSnapshot *)value
                     isBoundToSession:parent]);
        case CydiaLegacyUICompatibilityNativeSnapshotKindRelation:
            if ([memberName isEqualToString:@"relationship"])
                return [value isKindOfClass:[NSString class]];
            if (![value isKindOfClass:[NSArray class]])
                return NO;
            for (id child in (NSArray *)value)
                if (!ExactRuntimeClass(child, [CydiaLegacyUICompatibilityNativeSnapshot class]) ||
                    [(CydiaLegacyUICompatibilityNativeSnapshot *)child kind] !=
                        CydiaLegacyUICompatibilityNativeSnapshotKindClause ||
                    ![(CydiaLegacyUICompatibilityNativeSnapshot *)child
                        isBoundToSession:parent])
                    return NO;
            return YES;
    }
    return NO;
}

id SanitizedNestedResult(CydiaLegacyUICompatibilityNativeSnapshot *snapshot,
                         NSString *memberName,
                         id value) {
    if (value == nil || value == [CydiaLegacyUIUndefinedValue value] ||
        value == [NSNull null])
        return value;
    switch ([snapshot kind]) {
        case CydiaLegacyUICompatibilityNativeSnapshotKindOperation:
        case CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress:
        case CydiaLegacyUICompatibilityNativeSnapshotKindClause:
            if ([value isKindOfClass:[NSString class]])
                return [[NSString alloc] initWithString:(NSString *)value];
            return value;
        case CydiaLegacyUICompatibilityNativeSnapshotKindRelation:
            if ([memberName isEqualToString:@"clauses"] &&
                [value isKindOfClass:[NSArray class]])
                return [[NSArray alloc] initWithArray:(NSArray *)value copyItems:YES];
            return value;
    }
    return value;
}

BOOL IsUnsupportedFamily(CydiaLegacyBridgeOperationFamily family) {
    return family == CydiaLegacyBridgeOperationFamilySensitive ||
        family == CydiaLegacyBridgeOperationFamilyChrome ||
        family == CydiaLegacyBridgeOperationFamilyClipboard ||
        family == CydiaLegacyBridgeOperationFamilyRetired;
}

} // namespace


@interface CydiaLegacyUICompatibilityNativeCapability () {
    __weak id issuer_;
    NSString *nonce_;
    BOOL valid_;
}
- (instancetype) initWithIssuer:(id)issuer;
- (BOOL) _isValidForLegacyBridge;
- (BOOL) _isIssuedForApplication:(id)application;
@end

@implementation CydiaLegacyUICompatibilityNativeCapability

- (instancetype) initWithIssuer:(id)issuer {
    if (!ApplicationMayIssue(issuer) || (self = [super init]) == nil)
        return nil;
    issuer_ = issuer;
    nonce_ = [[[NSUUID alloc] init] UUIDString];
    valid_ = [nonce_ length] != 0;
    return self;
}

- (instancetype) init {
    return nil;
}

- (BOOL) isValid {
    @synchronized (self) {
        return valid_ && issuer_ != nil && [nonce_ length] != 0;
    }
}

- (void) revoke {
    @synchronized (self) {
        valid_ = NO;
        issuer_ = nil;
        nonce_ = nil;
    }
}

- (BOOL) _isValidForLegacyBridge {
    return [self isValid];
}

- (BOOL) _isIssuedForApplication:(id)application {
    @synchronized (self) {
        return valid_ && issuer_ == application && application != nil &&
            [nonce_ length] != 0;
    }
}

- (id) copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

- (NSString *) description {
    return [self isValid] ? @"<native compatibility capability: live>" :
        @"<native compatibility capability: revoked>";
}

@end


@interface CydiaLegacyUICompatibilityNativeSession () {
    __weak CydiaLegacyUICompatibilityNativeCaller *owner_;
    id<CydiaLegacyUICompatibilityNativeReading> reader_;
    id<CydiaLegacyUICompatibilityNativeCommanding> commander_;
    id<CydiaLegacyUICompatibilityNativeRouting> router_;
    BOOL active_;
    CydiaLegacyUICompatibilityNativeDenialReason lastDenialReason_;
    NSUInteger executorEntryCount_;
    NSUInteger denialCount_;
    NSMutableSet *requestedInvocations_;
    NSMutableArray<CydiaLegacyUICompatibilityNativeSnapshot *> *snapshotTargets_;
    CydiaUIRouteDispatchResult *lastRouteResult_;
}
- (instancetype) initWithOwner:(CydiaLegacyUICompatibilityNativeCaller *)owner
                      capability:(CydiaLegacyUICompatibilityNativeCapability *)capability
                         context:(CydiaUIRouteContext *)context
                           scope:(NSString *)scope
                          target:(id)target
                 packageIdentity:(NSString *)packageIdentity
                       sourceKey:(NSString *)sourceKey
                       presenter:(id)presenter
                          reader:(id<CydiaLegacyUICompatibilityNativeReading>)reader
                       commander:(id<CydiaLegacyUICompatibilityNativeCommanding>)commander
                          router:(id<CydiaLegacyUICompatibilityNativeRouting>)router;
- (void) setDenial:(CydiaLegacyUICompatibilityNativeDenialReason)reason;
- (BOOL) scopeMayExecuteInvocation:
    (CydiaLegacyUICompatibilityInvocation *)invocation;
- (BOOL) invocationIsBound:
    (CydiaLegacyUICompatibilityInvocation *)invocation;
- (CydiaLegacyUICompatibilityNativeSnapshot *) currentSnapshotTarget;
@end

@implementation CydiaLegacyUICompatibilityNativeSession

- (instancetype) initWithOwner:(CydiaLegacyUICompatibilityNativeCaller *)owner
                      capability:(CydiaLegacyUICompatibilityNativeCapability *)capability
                         context:(CydiaUIRouteContext *)context
                           scope:(NSString *)scope
                          target:(id)target
                 packageIdentity:(NSString *)packageIdentity
                       sourceKey:(NSString *)sourceKey
                       presenter:(id)presenter
                          reader:(id<CydiaLegacyUICompatibilityNativeReading>)reader
                       commander:(id<CydiaLegacyUICompatibilityNativeCommanding>)commander
                          router:(id<CydiaLegacyUICompatibilityNativeRouting>)router {
    if (owner == nil || !CapabilityIsValid(capability) ||
        !IsBoundContext(context, capability) || !IsBoundScope(scope) ||
        target == nil || presenter == nil)
        return nil;
    if (([scope isEqualToString:@"Package"] &&
         (!IsSafeIdentity(packageIdentity) || sourceKey != nil)) ||
        ([scope isEqualToString:@"Source"] &&
         (!IsSafeSourceKey(sourceKey) || packageIdentity != nil)) ||
        ([scope isEqualToString:@"NSDictionary"] &&
         ![target isKindOfClass:[NSDictionary class]]))
        return nil;
    if (![scope isEqualToString:@"Package"] &&
        ![scope isEqualToString:@"Source"] &&
        (packageIdentity != nil || sourceKey != nil))
        return nil;

    id boundTarget(target);
    if ([scope isEqualToString:@"NSDictionary"]) {
        @try {
            boundTarget = [[NSDictionary alloc]
                initWithDictionary:(NSDictionary *)target copyItems:NO];
        } @catch (NSException *exception) {
            (void)exception;
            return nil;
        }
        if (boundTarget == nil)
            return nil;
    }

    if ((self = [super init]) != nil) {
        owner_ = owner;
        _capability = capability;
        _context = context;
        _targetScope = [scope copy];
        _target = boundTarget;
        _packageIdentity = [packageIdentity copy];
        _sourceKey = [sourceKey copy];
        _presenter = presenter;
        reader_ = reader;
        commander_ = commander;
        router_ = router;
        requestedInvocations_ = [[NSMutableSet alloc] init];
        snapshotTargets_ = [[NSMutableArray alloc] init];
        active_ = YES;
        lastDenialReason_ = CydiaLegacyUICompatibilityNativeDenialReasonNone;
        _service = [[CydiaLegacyUICompatibilityService alloc]
            initWithContext:context callingOrigin:nil
            packageIdentity:packageIdentity executor:self];
    }
    return self;
}

- (BOOL) isActive {
    CydiaLegacyUICompatibilityNativeCaller *owner(owner_);
    BOOL active(NO);
    @synchronized (self) {
        active = active_;
    }
    return active && [_capability isValid] && owner != nil && [owner isActive];
}

- (CydiaLegacyUICompatibilityNativeDenialReason) lastDenialReason {
    @synchronized (self) {
        return lastDenialReason_;
    }
}

- (void) setDenial:(CydiaLegacyUICompatibilityNativeDenialReason)reason {
    @synchronized (self) {
        lastDenialReason_ = reason;
        if (reason != CydiaLegacyUICompatibilityNativeDenialReasonNone)
            ++denialCount_;
    }
}

- (NSUInteger) executorEntryCount {
    @synchronized (self) { return executorEntryCount_; }
}

- (NSUInteger) denialCount {
    @synchronized (self) { return denialCount_; }
}

- (CydiaLegacyUICompatibilityNativeSnapshot *) currentSnapshotTarget {
    @synchronized (self) {
        return [snapshotTargets_ lastObject];
    }
}

- (BOOL) scopeMayExecuteInvocation:
    (CydiaLegacyUICompatibilityInvocation *)invocation {
    NSString *scope([invocation scope]);
    /* A session is bound to one legacy receiver family.  Even though the
     * policy has a few global/rendering members, allowing a caller to switch
     * families would sever the target binding and make provider mistakes
     * indistinguishable from an application-wide call.  The only inherited
     * exceptions are the explicitly allowlisted Foundation localize and
     * format renderers. */
    if ([scope isEqualToString:_targetScope])
        return YES;
    if (IsNestedSnapshotScope(scope))
        return SnapshotAllowsInvocation([self currentSnapshotTarget], scope,
            [invocation memberKind], [invocation memberName], self);
    return IsInheritedCyteObjectRenderer(_targetScope, scope,
        [invocation memberKind], [invocation memberName], [invocation arguments],
        _target, _capability);
}

- (BOOL) invocationIsBound:(CydiaLegacyUICompatibilityInvocation *)invocation {
    if (!ExactRuntimeClass(invocation, [CydiaLegacyUICompatibilityInvocation class]) ||
        ![self scopeMayExecuteInvocation:invocation] ||
        [invocation context] != _context || [invocation callingOrigin] != nil ||
        !OptionalStringEqual([invocation packageIdentity], _packageIdentity))
        return NO;
    return [invocation context] != nil &&
        [[invocation context] inProcessCapability] == _capability;
}

- (id) invokeScope:(NSString *)scope
         memberKind:(CydiaLegacyBridgeMemberKind)memberKind
         memberName:(NSString *)memberName
          arguments:(NSArray *)arguments
       targetOrigin:(NSURL *)targetOrigin {
    if (![self isActive]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability];
        return [CydiaLegacyUIUndefinedValue value];
    }
    if (![scope isEqualToString:_targetScope] &&
        !SnapshotAllowsInvocation([self currentSnapshotTarget], scope,
            memberKind, memberName, self) &&
        !IsInheritedCyteObjectRenderer(_targetScope, scope, memberKind,
            memberName, arguments, _target, _capability)) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget];
        return [CydiaLegacyUIUndefinedValue value];
    }
    return [_service invokeScope:scope memberKind:memberKind
        memberName:memberName arguments:arguments targetOrigin:targetOrigin];
}

- (CydiaLegacyUICompatibilityDecision *) decisionForScope:(NSString *)scope
                                                memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                                                memberName:(NSString *)memberName
                                                 arguments:(NSArray *)arguments
                                              targetOrigin:(NSURL *)targetOrigin {
    if (![self isActive]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability];
        return CydiaLegacyUIEvaluateCompatibilityInvocation(nil);
    }
    if (![scope isEqualToString:_targetScope] &&
        !SnapshotAllowsInvocation([self currentSnapshotTarget], scope,
            memberKind, memberName, self) &&
        !IsInheritedCyteObjectRenderer(_targetScope, scope, memberKind,
            memberName, arguments, _target, _capability)) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget];
        return CydiaLegacyUIEvaluateCompatibilityInvocation(nil);
    }
    return [_service decisionForScope:scope memberKind:memberKind
        memberName:memberName arguments:arguments targetOrigin:targetOrigin];
}

- (id) invokeSnapshot:(CydiaLegacyUICompatibilityNativeSnapshot *)snapshot
           memberName:(NSString *)memberName
            arguments:(NSArray *)arguments {
    if (![self isActive]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability];
        return [CydiaLegacyUIUndefinedValue value];
    }
    NSString *scope(nil);
    BOOL exactSnapshot(ExactRuntimeClass(snapshot,
        [CydiaLegacyUICompatibilityNativeSnapshot class]));
    if (exactSnapshot)
        scope = SnapshotScope(snapshot);
    BOOL knownMember(exactSnapshot && scope != nil &&
        SnapshotMemberAllowed([snapshot kind], memberName));
    if (!exactSnapshot || scope == nil ||
        !knownMember ||
        ![snapshot isBoundToSession:self]) {
        [self setDenial:exactSnapshot && scope != nil && !knownMember ?
            CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember :
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget];
        return [CydiaLegacyUIUndefinedValue value];
    }

    id value(nil);
    @synchronized (self) {
        [snapshotTargets_ addObject:snapshot];
        @try {
            value = [_service invokeScope:scope
                memberKind:CydiaLegacyBridgeMemberKindAttribute
                memberName:memberName arguments:arguments targetOrigin:nil];
        } @finally {
            [snapshotTargets_ removeLastObject];
        }
    }
    return value ?: [CydiaLegacyUIUndefinedValue value];
}

- (CydiaLegacyUICompatibilityDecision *) decisionForSnapshot:(CydiaLegacyUICompatibilityNativeSnapshot *)snapshot
                                                  memberName:(NSString *)memberName
                                                   arguments:(NSArray *)arguments {
    if (![self isActive]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability];
        return CydiaLegacyUIEvaluateCompatibilityInvocation(nil);
    }
    NSString *scope(nil);
    BOOL exactSnapshot(ExactRuntimeClass(snapshot,
        [CydiaLegacyUICompatibilityNativeSnapshot class]));
    if (exactSnapshot)
        scope = SnapshotScope(snapshot);
    BOOL knownMember(exactSnapshot && scope != nil &&
        SnapshotMemberAllowed([snapshot kind], memberName));
    if (!exactSnapshot || scope == nil ||
        !knownMember ||
        ![snapshot isBoundToSession:self]) {
        [self setDenial:exactSnapshot && scope != nil && !knownMember ?
            CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember :
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget];
        return CydiaLegacyUIEvaluateCompatibilityInvocation(nil);
    }

    CydiaLegacyUICompatibilityDecision *decision(nil);
    @synchronized (self) {
        [snapshotTargets_ addObject:snapshot];
        @try {
            decision = [_service decisionForScope:scope
                memberKind:CydiaLegacyBridgeMemberKindAttribute
                memberName:memberName arguments:arguments targetOrigin:nil];
        } @finally {
            [snapshotTargets_ removeLastObject];
        }
    }
    return decision;
}

- (id) legacyUICompatibilityService:(CydiaLegacyUICompatibilityService *)service
        executeSynchronousInvocation:(CydiaLegacyUICompatibilityInvocation *)invocation {
    @synchronized (self) { ++executorEntryCount_; }
    (void)service;
    if (![self isActive] || ![self invocationIsBound:invocation]) {
        [self setDenial:![self isActive] ?
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability :
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget];
        return [CydiaLegacyUIUndefinedValue value];
    }

    CydiaLegacyUICompatibilityDecision *decision(
        CydiaLegacyUIEvaluateCompatibilityInvocation(invocation));
    if (![decision isAllowed]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
        return [decision unavailableValue];
    }

    CydiaLegacyUICompatibilitySignature *signature(
        CydiaLegacyUICompatibilitySignatureForMember([invocation scope],
            [invocation memberKind], [invocation memberName]));
    CydiaLegacyBridgeMember *member([signature member]);
    if (member == nil || IsUnsupportedFamily([member family]) ||
        [signature dispatchMode] != CydiaLegacyUIDispatchModeSynchronous) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
        return [CydiaLegacyUIUndefinedValue value];
    }

    NSString *scope([invocation scope]);
    NSString *name([invocation memberName]);
    NSArray *arguments([invocation arguments]);

    /* NSDictionary dynamic access is the only built-in object operation.  It
     * is intentionally limited to the immutable dictionary target captured at
     * session creation. */
    if ([scope isEqualToString:@"NSDictionary"] &&
        [_target isKindOfClass:[NSDictionary class]]) {
        if ([name isEqualToString:@"get"] && [arguments count] == 1)
            return [(NSDictionary *)_target objectForKey:[arguments objectAtIndex:0]] ?:
                [CydiaLegacyUIUndefinedValue value];
        if ([name isEqualToString:@"keys"] && [arguments count] == 0)
            return [(NSDictionary *)_target allKeys];
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
        return [CydiaLegacyUIUndefinedValue value];
    }

    /* Small, deterministic rendering helpers do not need an app provider. */
    if ([scope isEqualToString:@"CyteObject"] &&
        [name isEqualToString:@"getPreferredLanguages"])
        return [NSLocale preferredLanguages];
    if ([scope isEqualToString:@"CyteObject"] &&
        [name isEqualToString:@"getLocaleIdentifier"])
        return [[NSLocale currentLocale] localeIdentifier];

    if (IsNestedSnapshotScope(scope)) {
        CydiaLegacyUICompatibilityNativeSnapshot *snapshot([self currentSnapshotTarget]);
        if (!SnapshotAllowsInvocation(snapshot, scope, [invocation memberKind],
                name, self)) {
            [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget];
            return [CydiaLegacyUIUndefinedValue value];
        }
        if (reader_ == nil ||
            ![reader_ respondsToSelector:@selector(
                legacyNativeSession:valueForNestedSnapshotMember:target:arguments:)]) {
            [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonMissingProvider];
            return [CydiaLegacyUIUndefinedValue value];
        }
        id value([reader_ legacyNativeSession:self
            valueForNestedSnapshotMember:name target:snapshot arguments:arguments]);
        if (!IsValidNestedResult(snapshot, name, value, self)) {
            [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
            return [CydiaLegacyUIUndefinedValue value];
        }
        value = SanitizedNestedResult(snapshot, name, value);
        return value ?: [CydiaLegacyUIUndefinedValue value];
    }

    if (reader_ == nil) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonMissingProvider];
        return [CydiaLegacyUIUndefinedValue value];
    }

    id value(nil);
    if (IsPackageScope(scope) &&
        [reader_ respondsToSelector:@selector(legacyNativeSession:valueForPackageScope:memberName:target:arguments:)])
        value = [reader_ legacyNativeSession:self valueForPackageScope:scope
            memberName:name target:_target arguments:arguments];
    else if ([scope isEqualToString:@"Source"] &&
        [reader_ respondsToSelector:@selector(legacyNativeSession:valueForSourceMember:target:arguments:)])
        value = [reader_ legacyNativeSession:self valueForSourceMember:name
            target:_target arguments:arguments];
    /* CydiaObject has both application-wide reads and the historical
     * process-local session store.  Route the session family first; otherwise
     * an object that implements both typed callbacks would silently send
     * getSessionValue through the zero-argument global reader. */
    else if ([scope isEqualToString:@"CydiaObject"] &&
        [member family] == CydiaLegacyBridgeOperationFamilySession &&
        [reader_ respondsToSelector:@selector(legacyNativeSession:valueForSessionMember:arguments:)])
        value = [reader_ legacyNativeSession:self valueForSessionMember:name
            arguments:arguments];
    else if ([scope isEqualToString:@"CydiaObject"] &&
        [reader_ respondsToSelector:@selector(legacyNativeSession:valueForGlobalMember:arguments:)])
        value = [reader_ legacyNativeSession:self valueForGlobalMember:name
            arguments:arguments];
    else if ([scope isEqualToString:@"CyteObject"] &&
        [reader_ respondsToSelector:@selector(legacyNativeSession:valueForRenderingMember:arguments:)])
        value = [reader_ legacyNativeSession:self valueForRenderingMember:name
            arguments:arguments];
    else if ([scope isEqualToString:@"CydiaObject"] &&
        [reader_ respondsToSelector:@selector(legacyNativeSession:valueForSessionMember:arguments:)])
        value = [reader_ legacyNativeSession:self valueForSessionMember:name
            arguments:arguments];
    else {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
        return [CydiaLegacyUIUndefinedValue value];
    }
    return value ?: [CydiaLegacyUIUndefinedValue value];
}

- (void) legacyUICompatibilityService:(CydiaLegacyUICompatibilityService *)service
             enqueueMainThreadInvocation:(CydiaLegacyUICompatibilityInvocation *)invocation {
    @synchronized (self) { ++executorEntryCount_; }
    (void)service;
    if (![self isActive] || ![self invocationIsBound:invocation]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget];
        return;
    }
    /* Main-thread members are all chrome/legacy surfaces and are denied by
     * policy before reaching this executor.  Keep a defensive no-op here. */
    [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
}

- (BOOL) legacyUICompatibilityService:(CydiaLegacyUICompatibilityService *)service
        requestNativeConfirmationForInvocation:(CydiaLegacyUICompatibilityInvocation *)invocation {
    @synchronized (self) { ++executorEntryCount_; }
    (void)service;
    if (![self isActive] || ![self invocationIsBound:invocation]) {
        [self setDenial:![self isActive] ?
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability :
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget];
        return NO;
    }

    CydiaLegacyUICompatibilityDecision *decision(
        CydiaLegacyUIEvaluateCompatibilityInvocation(invocation));
    if (![decision isAllowed]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
        return NO;
    }

    CydiaLegacyUICompatibilitySignature *signature(
        CydiaLegacyUICompatibilitySignatureForMember([invocation scope],
            [invocation memberKind], [invocation memberName]));
    CydiaLegacyBridgeMember *member([signature member]);
    if (member == nil || [member family] != CydiaLegacyBridgeOperationFamilyMutation ||
        [signature dispatchMode] != CydiaLegacyUIDispatchModeNativeConfirmation) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
        return NO;
    }

    NSString *scope([invocation scope]);
    NSString *name([invocation memberName]);
    BOOL packageMutation([scope isEqualToString:@"Package"] &&
        [@[@"clear", @"install", @"remove"] containsObject:name]);
    BOOL sourceMutation([scope isEqualToString:@"Source"] &&
        [@[@"addSection", @"removeSection", @"remove"] containsObject:name]);
    BOOL applicationMutation([scope isEqualToString:@"CydiaObject"] &&
        [@[@"addSource", @"addTrivialSource", @"installPackages",
           @"refreshSources", @"saveConfig"] containsObject:name]);
    BOOL metadataMutation([scope isEqualToString:@"CydiaObject"] &&
        [name isEqualToString:@"setMetadataValue"]);
    if ((!packageMutation && !sourceMutation && !applicationMutation &&
         !metadataMutation) ||
        commander_ == nil || _presenter == nil) {
        [self setDenial:commander_ == nil ?
            CydiaLegacyUICompatibilityNativeDenialReasonMissingProvider :
            (_presenter == nil ?
                CydiaLegacyUICompatibilityNativeDenialReasonMissingPresenter :
                CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember)];
        return NO;
    }

    /* Keep the invocation itself in the set.  Pointer-only keys could alias
     * after an invocation is released, while retaining these tiny objects is
     * bounded by the session lifetime and guarantees one confirmation per
     * command request. */
    @synchronized (self) {
        if ([requestedInvocations_ containsObject:invocation]) {
            lastDenialReason_ =
                CydiaLegacyUICompatibilityNativeDenialReasonAlreadyRequested;
            return NO;
        }
        [requestedInvocations_ addObject:invocation];
    }

    BOOL accepted(NO);
    NSArray *arguments([invocation arguments]);
    if (metadataMutation) {
        NSString *key(CydiaLegacyUICompatibilityCopyMetadataKey(
            [arguments count] == 2 ? [arguments objectAtIndex:0] : nil));
        id value(nil);
        BOOL removing(NO);
        if (key == nil || [arguments count] != 2 ||
            !CydiaLegacyUICompatibilityCopyMetadataValue(
                [arguments objectAtIndex:1], &value, &removing)) {
            [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
        } else if ([commander_ respondsToSelector:@selector(
                legacyNativeSession:requestMetadataMutationForKey:value:removing:presenter:)])
            accepted = [commander_ legacyNativeSession:self
                requestMetadataMutationForKey:key value:value removing:removing
                presenter:_presenter];
        else
            [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonMissingProvider];
    } else if (packageMutation &&
        [commander_ respondsToSelector:@selector(legacyNativeSession:requestPackageMutation:target:packageIdentity:arguments:presenter:)])
        accepted = [commander_ legacyNativeSession:self requestPackageMutation:name
            target:_target packageIdentity:_packageIdentity arguments:arguments
            presenter:_presenter];
    else if (sourceMutation &&
        [commander_ respondsToSelector:@selector(legacyNativeSession:requestSourceMutation:target:sourceKey:arguments:presenter:)])
        accepted = [commander_ legacyNativeSession:self requestSourceMutation:name
            target:_target sourceKey:_sourceKey arguments:arguments
            presenter:_presenter];
    else if (applicationMutation &&
        [commander_ respondsToSelector:@selector(legacyNativeSession:requestApplicationMutation:arguments:presenter:)])
        accepted = [commander_ legacyNativeSession:self requestApplicationMutation:name
            arguments:arguments presenter:_presenter];
    else
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];

    /* The set is both an in-flight reservation and the accepted replay gate.
     * A synchronous rejection means no confirmation or command was accepted,
     * so release only that reservation under the same lock and permit retry. */
    if (!accepted) {
        @synchronized (self) {
            [requestedInvocations_ removeObject:invocation];
        }
    }
    return accepted;
}

- (BOOL) handoffRouteURL:(NSURL *)url {
    if (![self isActive]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability];
        return NO;
    }
    if (router_ == nil ||
        ![router_ respondsToSelector:@selector(legacyNativeSession:handoffRouteDescriptor:context:)]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonRouterUnavailable];
        return NO;
    }

    CydiaUIRouteDispatchResult *result(CydiaUIDispatchRouteURL(url, _context,
        ^BOOL(NSString *sourceKey) {
            return [router_ respondsToSelector:@selector(legacyNativeSession:sourceKeyExists:)] &&
                [router_ legacyNativeSession:self sourceKeyExists:sourceKey];
        }));
    @synchronized (self) {
        lastRouteResult_ = result;
    }
    if (![result isAllowed]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonRouteRejected];
        return NO;
    }

    /* Compatibility handoff is read-only.  Command routes and system-open
     * routes remain available to Cydia's ordinary typed router, not this
     * compatibility session. */
    CydiaUIRouteKind kind([[result descriptor] kind]);
    if (kind == CydiaUIRouteKindSourceAdd ||
        kind == CydiaUIRouteKindLaunchApplication ||
        kind == CydiaUIRouteKindExternalOpen) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember];
        return NO;
    }
    /* The source resolver/router may call application code.  Recheck after
     * parsing so revocation during that callback cannot reach the final
     * handoff with an inactive session. */
    if (![self isActive]) {
        [self setDenial:CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability];
        return NO;
    }
    return [router_ legacyNativeSession:self
        handoffRouteDescriptor:[result descriptor] context:_context];
}

- (CydiaUIRouteDispatchResult *) lastRouteResult {
    @synchronized (self) {
        return lastRouteResult_;
    }
}

- (void) invalidate {
    @synchronized (self) {
        active_ = NO;
        [requestedInvocations_ removeAllObjects];
        [snapshotTargets_ removeAllObjects];
    }
}

@end

@interface CydiaLegacyUICompatibilityNativeCaller () {
    NSMutableArray *sessions_;
    BOOL active_;
}
@end

@implementation CydiaLegacyUICompatibilityNativeCaller

+ (CydiaLegacyUICompatibilityNativeCapability *) issueCapabilityForApplication:(id)application {
    if (!ApplicationMayIssue(application))
        return nil;
    return [[CydiaLegacyUICompatibilityNativeCapability alloc]
        initWithIssuer:application];
}

- (instancetype) initWithCapability:(CydiaLegacyUICompatibilityNativeCapability *)capability
                              reader:(id<CydiaLegacyUICompatibilityNativeReading>)reader
                           commander:(id<CydiaLegacyUICompatibilityNativeCommanding>)commander
                              router:(id<CydiaLegacyUICompatibilityNativeRouting>)router {
    if (!CapabilityIsValid(capability) || (self = [super init]) == nil)
        return nil;
    _capability = capability;
    _reader = reader;
    _commander = commander;
    _router = router;
    sessions_ = [[NSMutableArray alloc] init];
    active_ = YES;
    return self;
}

- (BOOL) isActive {
    @synchronized (self) {
        return active_ && [_capability isValid];
    }
}

- (CydiaLegacyUICompatibilityNativeSession *) sessionForScope:(NSString *)scope
                                                        target:(id)target
                                               packageIdentity:(NSString *)packageIdentity
                                                     sourceKey:(NSString *)sourceKey
                                                      presenter:(id)presenter {
    CydiaUIRouteContext *context(
        [CydiaUIRouteContext trustedInProcessContextWithCapability:_capability]);
    return [self sessionForScope:scope target:target packageIdentity:packageIdentity
        sourceKey:sourceKey presenter:presenter context:context];
}

- (CydiaLegacyUICompatibilityNativeSession *) sessionForScope:(NSString *)scope
                                                        target:(id)target
                                               packageIdentity:(NSString *)packageIdentity
                                                     sourceKey:(NSString *)sourceKey
                                                      presenter:(id)presenter
                                                       context:(CydiaUIRouteContext *)context {
    if (![self isActive] || !IsBoundContext(context, _capability))
        return nil;

    CydiaLegacyUICompatibilityNativeSession *session(
        [[CydiaLegacyUICompatibilityNativeSession alloc]
            initWithOwner:self capability:_capability context:context scope:scope
            target:target packageIdentity:packageIdentity sourceKey:sourceKey
            presenter:presenter reader:_reader commander:_commander router:_router]);
    if (session != nil) {
        @synchronized (self) {
            if (!active_ || ![_capability isValid]) {
                [session invalidate];
                session = nil;
            } else {
                [sessions_ addObject:session];
            }
        }
    }
    return session;
}

- (void) invalidate {
    NSArray *sessions(nil);
    @synchronized (self) {
        if (!active_)
            return;
        active_ = NO;
        sessions = [sessions_ copy];
        [sessions_ removeAllObjects];
    }
    for (CydiaLegacyUICompatibilityNativeSession *session in sessions)
        [session invalidate];
    [_capability revoke];
}

@end
