/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_LegacyUICompatibility_H
#define Cydia_LegacyUICompatibility_H

#include "Cydia/LegacyBridgePolicy.h"

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, CydiaLegacyUIValueKind) {
    CydiaLegacyUIValueKindVoid,
    CydiaLegacyUIValueKindObject,
    CydiaLegacyUIValueKindString,
    CydiaLegacyUIValueKindNumber,
    CydiaLegacyUIValueKindBoolean,
    CydiaLegacyUIValueKindArray,
};

typedef NS_ENUM(NSUInteger, CydiaLegacyUIUnavailableConvention) {
    CydiaLegacyUIUnavailableConventionUndefined,
    CydiaLegacyUIUnavailableConventionNull,
    CydiaLegacyUIUnavailableConventionFalse,
};

typedef NS_ENUM(NSUInteger, CydiaLegacyUIDispatchMode) {
    CydiaLegacyUIDispatchModeSynchronous,
    CydiaLegacyUIDispatchModeMainThreadAsync,
    CydiaLegacyUIDispatchModeNativeConfirmation,
};

typedef NS_ENUM(NSUInteger, CydiaLegacyUIArgumentKind) {
    CydiaLegacyUIArgumentKindString,
    CydiaLegacyUIArgumentKindOptionalString,
    CydiaLegacyUIArgumentKindNumber,
    CydiaLegacyUIArgumentKindOptionalNumber,
    CydiaLegacyUIArgumentKindBooleanLike,
    CydiaLegacyUIArgumentKindOptionalBooleanLike,
    CydiaLegacyUIArgumentKindSequence,
    CydiaLegacyUIArgumentKindOpaque,
    CydiaLegacyUIArgumentKindOptionalAny,
    CydiaLegacyUIArgumentKindURLString,
    CydiaLegacyUIArgumentKindMetadataKey,
    CydiaLegacyUIArgumentKindOptionalPropertyList,
};

typedef NS_ENUM(NSUInteger, CydiaLegacyUICompatibilityDenialReason) {
    CydiaLegacyUICompatibilityDenialReasonNone,
    CydiaLegacyUICompatibilityDenialReasonPolicy,
    CydiaLegacyUICompatibilityDenialReasonMalformedArguments,
};

/* Foundation stand-in for JavaScript `undefined`. The transitional private-
 * WebScript adapter converts this marker to its platform undefined object. */
@interface CydiaLegacyUIUndefinedValue : NSObject
+ (instancetype) value;
- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;
@end

@interface CydiaLegacyUICompatibilitySignature : NSObject

@property (nonatomic, readonly, strong) CydiaLegacyBridgeMember *member;
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *argumentKinds;
@property (nonatomic, readonly) CydiaLegacyUIValueKind resultKind;
@property (nonatomic, readonly) CydiaLegacyUIUnavailableConvention unavailableConvention;
@property (nonatomic, readonly) CydiaLegacyUIDispatchMode dispatchMode;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end


@interface CydiaLegacyUICompatibilityInvocation : NSObject

@property (nonatomic, readonly, copy) NSString *scope;
@property (nonatomic, readonly) CydiaLegacyBridgeMemberKind memberKind;
@property (nonatomic, readonly, copy) NSString *memberName;
@property (nonatomic, readonly, strong) CydiaUIRouteContext *context;
@property (nonatomic, readonly, copy) NSURL *callingOrigin;
@property (nonatomic, readonly, copy) NSString *packageIdentity;
@property (nonatomic, readonly, copy) NSURL *targetOrigin;
@property (nonatomic, readonly, copy) NSArray *arguments;

- (instancetype) initWithScope:(NSString *)scope
                    memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                    memberName:(NSString *)memberName
                       context:(CydiaUIRouteContext *)context
                 callingOrigin:(NSURL *)callingOrigin
               packageIdentity:(NSString *)packageIdentity
                  targetOrigin:(NSURL *)targetOrigin
                     arguments:(NSArray *)arguments NS_DESIGNATED_INITIALIZER;
- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end


@interface CydiaLegacyUICompatibilityDecision : NSObject

@property (nonatomic, readonly, strong) CydiaLegacyUICompatibilitySignature *signature;
@property (nonatomic, readonly, strong) CydiaLegacyBridgeAuthorization *authorization;
@property (nonatomic, readonly) CydiaLegacyUICompatibilityDenialReason denialReason;
@property (nonatomic, readonly, getter=isAllowed) BOOL allowed;
@property (nonatomic, readonly, strong) id unavailableValue;

@end


@class CydiaLegacyUICompatibilityService;

/* The service owns policy, argument/result validation, and dispatch choice.
 * A backend owns only the authorized app operation. Keeping three distinct
 * entry points prevents a package/source mutation from silently falling back
 * to the historical immediate selector.
 *
 * The convenience initializer intentionally creates a policy-only service:
 * it has no executor and therefore never performs an operation. A caller that
 * wants execution must use the designated initializer and retain the executor
 * for at least as long as the service. This keeps the policy surface usable by
 * static/host callers without implying that a legacy HTML bridge exists. */
@protocol CydiaLegacyUICompatibilityExecuting <NSObject>
- (id) legacyUICompatibilityService:(CydiaLegacyUICompatibilityService *)service
        executeSynchronousInvocation:(CydiaLegacyUICompatibilityInvocation *)invocation;
- (void) legacyUICompatibilityService:(CydiaLegacyUICompatibilityService *)service
             enqueueMainThreadInvocation:(CydiaLegacyUICompatibilityInvocation *)invocation;
- (BOOL) legacyUICompatibilityService:(CydiaLegacyUICompatibilityService *)service
        requestNativeConfirmationForInvocation:(CydiaLegacyUICompatibilityInvocation *)invocation;
@end


@interface CydiaLegacyUICompatibilityService : NSObject

@property (nonatomic, readonly, strong) CydiaUIRouteContext *context;
@property (nonatomic, readonly, copy) NSURL *callingOrigin;
@property (nonatomic, readonly, copy) NSString *packageIdentity;
@property (nonatomic, readonly, weak) id<CydiaLegacyUICompatibilityExecuting> executor;
/* YES only while an explicitly supplied executor is alive. */
@property (nonatomic, readonly, getter=isExecutable) BOOL executable;

- (instancetype) initWithContext:(CydiaUIRouteContext *)context
                   callingOrigin:(NSURL *)callingOrigin
                 packageIdentity:(NSString *)packageIdentity;
- (instancetype) initWithContext:(CydiaUIRouteContext *)context
                   callingOrigin:(NSURL *)callingOrigin
                 packageIdentity:(NSString *)packageIdentity
                        executor:(id<CydiaLegacyUICompatibilityExecuting>)executor
    NS_DESIGNATED_INITIALIZER;
- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

- (CydiaLegacyUICompatibilityDecision *) decisionForScope:(NSString *)scope
                                                memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                                                memberName:(NSString *)memberName
                                                 arguments:(NSArray *)arguments
                                              targetOrigin:(NSURL *)targetOrigin;
- (id) invokeScope:(NSString *)scope
         memberKind:(CydiaLegacyBridgeMemberKind)memberKind
         memberName:(NSString *)memberName
          arguments:(NSArray *)arguments
       targetOrigin:(NSURL *)targetOrigin;

@end


FOUNDATION_EXPORT NSArray<CydiaLegacyUICompatibilitySignature *> *
    CydiaLegacyUICompatibilitySignatures(void);
FOUNDATION_EXPORT CydiaLegacyUICompatibilitySignature *
    CydiaLegacyUICompatibilitySignatureForMember(NSString *scope,
                                                  CydiaLegacyBridgeMemberKind kind,
                                                  NSString *name);
FOUNDATION_EXPORT CydiaLegacyUICompatibilityDecision *
    CydiaLegacyUIEvaluateCompatibilityInvocation(
        CydiaLegacyUICompatibilityInvocation *invocation);

/* Foundation-only implementation of the historical CyteObject `localize`
 * method.  The bundle is supplied by the app-owned caller (production passes
 * the main application bundle); callers cannot cause a resource lookup from a
 * URL, network, or device path.  `key` is required.  `value` and `table` may
 * be NSString instances or the Foundation stand-ins for JavaScript
 * undefined/null.  A malformed argument or bundle returns nil so the typed
 * session converts it to the signature's undefined convention. */
FOUNDATION_EXPORT NSString *
    CydiaLegacyUICompatibilityLocalizedStringInBundle(NSBundle *bundle,
                                                       id key,
                                                       id value,
                                                       id table);

/* Convenience form used by the app-owned provider. */
FOUNDATION_EXPORT NSString *
    CydiaLegacyUICompatibilityLocalizedString(id key, id value, id table);

/* Bounded Foundation implementation of the historical CyteObject `format`
 * method.  `format` accepts only literal text, `%%`, and `%@`; `arguments`
 * must be an NSArray or NSOrderedSet whose values are NSString, NSNumber,
 * NSNull, or CydiaLegacyUIUndefinedValue instances.  The format, values,
 * argument count, and expanded result are capped by the implementation.  A
 * malformed format, unsupported printf grammar, count mismatch, unsafe value,
 * or exceeded bound returns nil. */
FOUNDATION_EXPORT NSString *
    CydiaLegacyUICompatibilityFormatString(NSString *format, id arguments);

/* The persistent CydiaValues dictionary is a property-list boundary.  These
 * helpers keep its one retained legacy writer bounded and deterministic:
 * keys are non-empty, control-free NSString values; non-removal values are
 * deeply copied through an immutable binary property list.  NSNull and the
 * undefined marker preserve the historical remove convention. */
FOUNDATION_EXPORT NSString *
    CydiaLegacyUICompatibilityCopyMetadataKey(id key);
FOUNDATION_EXPORT BOOL
    CydiaLegacyUICompatibilityCopyMetadataValue(id value,
                                                 id _Nullable * _Nullable copy,
                                                 BOOL * _Nullable removesValue);

#endif // Cydia_LegacyUICompatibility_H
