/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_LegacyBridgePolicy_H
#define Cydia_LegacyBridgePolicy_H

#include "Cydia/UIRouteContext.h"

#import <Foundation/Foundation.h>

@class CydiaLegacyUICompatibilityNativeCapability;

typedef NS_ENUM(NSUInteger, CydiaLegacyBridgeOperationFamily) {
    CydiaLegacyBridgeOperationFamilySensitive,
    CydiaLegacyBridgeOperationFamilyMutation,
    CydiaLegacyBridgeOperationFamilyGlobalRead,
    CydiaLegacyBridgeOperationFamilyPackageRead,
    CydiaLegacyBridgeOperationFamilySourceRead,
    CydiaLegacyBridgeOperationFamilySession,
    CydiaLegacyBridgeOperationFamilyChrome,
    CydiaLegacyBridgeOperationFamilyClipboard,
    CydiaLegacyBridgeOperationFamilyRendering,
    /* Historical WebScript data retained only until its source declarations
       are deleted; it is never an authorization capability. */
    CydiaLegacyBridgeOperationFamilyRetired,
};

typedef NS_ENUM(NSUInteger, CydiaLegacyBridgeMemberKind) {
    CydiaLegacyBridgeMemberKindMethod,
    CydiaLegacyBridgeMemberKindAttribute,
    CydiaLegacyBridgeMemberKindGlobal,
    CydiaLegacyBridgeMemberKindDynamicMethod,
    CydiaLegacyBridgeMemberKindKeyPolicy,
};

typedef NS_ENUM(NSUInteger, CydiaLegacyBridgeAccessRequirement) {
    CydiaLegacyBridgeAccessRequirementDenied,
    CydiaLegacyBridgeAccessRequirementAllowed,
    CydiaLegacyBridgeAccessRequirementUserGesture,
    CydiaLegacyBridgeAccessRequirementCurrentPackage,
    CydiaLegacyBridgeAccessRequirementCurrentSource,
    CydiaLegacyBridgeAccessRequirementAllowlistedOrigin,
    CydiaLegacyBridgeAccessRequirementRetired,
};

typedef NS_ENUM(NSUInteger, CydiaLegacyBridgeAuthorizationDisposition) {
    CydiaLegacyBridgeAuthorizationDispositionDenied,
    CydiaLegacyBridgeAuthorizationDispositionTrustedLegacyCompatibility,
    CydiaLegacyBridgeAuthorizationDispositionDepictionReadOnly,
};

typedef NS_ENUM(NSUInteger, CydiaLegacyBridgeDenialReason) {
    CydiaLegacyBridgeDenialReasonNone,
    CydiaLegacyBridgeDenialReasonMalformedRequest,
    CydiaLegacyBridgeDenialReasonUnknownMember,
    CydiaLegacyBridgeDenialReasonMissingContext,
    CydiaLegacyBridgeDenialReasonCaller,
    CydiaLegacyBridgeDenialReasonOrigin,
    CydiaLegacyBridgeDenialReasonMainFrame,
    CydiaLegacyBridgeDenialReasonUserGesture,
    CydiaLegacyBridgeDenialReasonPackageIdentity,
    CydiaLegacyBridgeDenialReasonTargetOrigin,
    CydiaLegacyBridgeDenialReasonRetiredSurface,
};

@interface CydiaLegacyBridgeMember : NSObject

@property (nonatomic, readonly, copy) NSString *scope;
@property (nonatomic, readonly) CydiaLegacyBridgeMemberKind kind;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *sourceForm;
@property (nonatomic, readonly) CydiaLegacyBridgeOperationFamily family;
@property (nonatomic, readonly) CydiaLegacyBridgeAccessRequirement trustedLegacyRequirement;
@property (nonatomic, readonly) CydiaLegacyBridgeAccessRequirement repositoryDepictionRequirement;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end

/* `callingOrigin` is the origin of the frame making this particular call; it
 * is intentionally separate from the immutable initiating origin in the route
 * context. `packageIdentity` is also the provenance for a Source reached from
 * the current package. `targetOrigin` is required only by allowlisted network
 * queries such as isReachable. */
@interface CydiaLegacyBridgeRequest : NSObject

@property (nonatomic, readonly, copy) NSString *scope;
@property (nonatomic, readonly) CydiaLegacyBridgeMemberKind memberKind;
@property (nonatomic, readonly, copy) NSString *memberName;
@property (nonatomic, readonly, strong) CydiaUIRouteContext *context;
@property (nonatomic, readonly, copy) NSURL *callingOrigin;
@property (nonatomic, readonly, copy) NSString *packageIdentity;
@property (nonatomic, readonly, copy) NSURL *targetOrigin;
/* Only capability-bound in-process requests carry this token.  Policy checks
 * identity and liveness; nil is required for all web/depiction callers. */
@property (nonatomic, readonly, strong)
    CydiaLegacyUICompatibilityNativeCapability *inProcessCapability;

- (instancetype) initWithScope:(NSString *)scope
                    memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                    memberName:(NSString *)memberName
                       context:(CydiaUIRouteContext *)context
                   callingOrigin:(NSURL *)callingOrigin
                 packageIdentity:(NSString *)packageIdentity
                  targetOrigin:(NSURL *)targetOrigin;
- (instancetype) initWithScope:(NSString *)scope
                    memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                    memberName:(NSString *)memberName
                       context:(CydiaUIRouteContext *)context
                 callingOrigin:(NSURL *)callingOrigin
               packageIdentity:(NSString *)packageIdentity
                  targetOrigin:(NSURL *)targetOrigin
          inProcessCapability:(CydiaLegacyUICompatibilityNativeCapability *)capability
    NS_DESIGNATED_INITIALIZER;
- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end


@interface CydiaLegacyBridgeAuthorization : NSObject

@property (nonatomic, readonly, strong) CydiaLegacyBridgeMember *member;
@property (nonatomic, readonly) CydiaLegacyBridgeAuthorizationDisposition disposition;
@property (nonatomic, readonly) CydiaLegacyBridgeDenialReason denialReason;
@property (nonatomic, readonly, getter=isAllowed) BOOL allowed;
@property (nonatomic, readonly, getter=isDepictionReadOnly) BOOL depictionReadOnly;

@end


FOUNDATION_EXPORT NSArray<CydiaLegacyBridgeMember *> *CydiaLegacyBridgeMembers(void);
FOUNDATION_EXPORT CydiaLegacyBridgeMember *CydiaLegacyBridgeMemberForName(NSString *scope,
                                                                          CydiaLegacyBridgeMemberKind kind,
                                                                          NSString *name);
FOUNDATION_EXPORT NSString *CydiaLegacyBridgeMemberKindName(CydiaLegacyBridgeMemberKind kind);
FOUNDATION_EXPORT NSString *CydiaLegacyBridgeOperationFamilyName(CydiaLegacyBridgeOperationFamily family);
FOUNDATION_EXPORT NSString *CydiaLegacyBridgeAccessRequirementName(CydiaLegacyBridgeAccessRequirement requirement);
FOUNDATION_EXPORT CydiaLegacyBridgeAuthorization *CydiaLegacyBridgeAuthorize(CydiaLegacyBridgeRequest *request);

#endif // Cydia_LegacyBridgePolicy_H
