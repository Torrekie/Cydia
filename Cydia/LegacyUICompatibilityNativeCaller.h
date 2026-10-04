/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_LegacyUICompatibilityNativeCaller_H
#define Cydia_LegacyUICompatibilityNativeCaller_H

#include "Cydia/LegacyUICompatibility.h"
#include "Cydia/LegacyUICompatibilityNativeSnapshot.h"
#include "Cydia/UIRouteDispatch.h"

#import <Foundation/Foundation.h>

@class CydiaLegacyUICompatibilityNativeCaller;
@class CydiaLegacyUICompatibilityNativeSession;

/* Opaque authority for a trusted in-process session.  The implementation
 * binds this object to the issuing application and the policy layer checks
 * liveness on every member invocation. */
@interface CydiaLegacyUICompatibilityNativeCapability : NSObject <NSCopying>
@property (nonatomic, readonly, getter=isValid) BOOL valid;
- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;
- (void) revoke;
@end

/* Application-owned read snapshots.  There is intentionally no generic KVC
 * or selector callback: providers opt into one typed data family at a time. */
@protocol CydiaLegacyUICompatibilityNativeReading <NSObject>
@optional
- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
      valueForPackageScope:(NSString *)scope
                memberName:(NSString *)memberName
                    target:(id)target
                 arguments:(NSArray *)arguments;
- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
      valueForSourceMember:(NSString *)memberName
                    target:(id)target
                 arguments:(NSArray *)arguments;
- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
       valueForGlobalMember:(NSString *)memberName
                  arguments:(NSArray *)arguments;
- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
     valueForRenderingMember:(NSString *)memberName
                    arguments:(NSArray *)arguments;
- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
       valueForSessionMember:(NSString *)memberName
                  arguments:(NSArray *)arguments;
- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
 valueForNestedSnapshotMember:(NSString *)memberName
                       target:(CydiaLegacyUICompatibilityNativeSnapshot *)target
                    arguments:(NSArray *)arguments;
@end

/* Mutations are handed to the app's existing native confirmation/operation
 * path.  A provider returns YES only after accepting the typed request.  A
 * session permits at most one accepted request per invocation object, while a
 * synchronous rejection leaves that invocation retryable. */
@protocol CydiaLegacyUICompatibilityNativeCommanding <NSObject>
@optional
- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
        requestPackageMutation:(NSString *)memberName
                          target:(id)target
                 packageIdentity:(NSString *)packageIdentity
                       arguments:(NSArray *)arguments
                        presenter:(id)presenter;
- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
         requestSourceMutation:(NSString *)memberName
                          target:(id)target
                        sourceKey:(NSString *)sourceKey
                       arguments:(NSArray *)arguments
                        presenter:(id)presenter;
- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
    requestApplicationMutation:(NSString *)memberName
                       arguments:(NSArray *)arguments
                        presenter:(id)presenter;
- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
   requestMetadataMutationForKey:(NSString *)key
                            value:(id)value
                          removing:(BOOL)removing
                         presenter:(id)presenter;
@end

/* Route handoff receives only a parsed, policy-approved descriptor. */
@protocol CydiaLegacyUICompatibilityNativeRouting <NSObject>
@optional
- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
           sourceKeyExists:(NSString *)sourceKey;
- (BOOL) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
      handoffRouteDescriptor:(CydiaUIRouteDescriptor *)descriptor
                      context:(CydiaUIRouteContext *)context;
@end

typedef NS_ENUM(NSUInteger, CydiaLegacyUICompatibilityNativeDenialReason) {
    CydiaLegacyUICompatibilityNativeDenialReasonNone,
    CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability,
    CydiaLegacyUICompatibilityNativeDenialReasonInvalidContext,
    CydiaLegacyUICompatibilityNativeDenialReasonInvalidTarget,
    CydiaLegacyUICompatibilityNativeDenialReasonUnsupportedMember,
    CydiaLegacyUICompatibilityNativeDenialReasonMissingProvider,
    CydiaLegacyUICompatibilityNativeDenialReasonMissingPresenter,
    CydiaLegacyUICompatibilityNativeDenialReasonAlreadyRequested,
    CydiaLegacyUICompatibilityNativeDenialReasonRouteRejected,
    CydiaLegacyUICompatibilityNativeDenialReasonRouterUnavailable,
};

@interface CydiaLegacyUICompatibilityNativeSession : NSObject
    <CydiaLegacyUICompatibilityExecuting,
     CydiaLegacyUICompatibilityNativeSnapshotParent>
@property (nonatomic, readonly, strong)
    CydiaLegacyUICompatibilityNativeCapability *capability;
@property (nonatomic, readonly, strong) CydiaUIRouteContext *context;
@property (nonatomic, readonly, strong)
    CydiaLegacyUICompatibilityService *service;
@property (nonatomic, readonly, copy) NSString *targetScope;
@property (nonatomic, readonly, strong) id target;
@property (nonatomic, readonly, copy) NSString *packageIdentity;
@property (nonatomic, readonly, copy) NSString *sourceKey;
/* Opaque so this header remains Foundation-only; app providers treat it as
 * their native UIViewController presenter. */
@property (nonatomic, readonly, strong) id presenter;
@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, readonly) CydiaLegacyUICompatibilityNativeDenialReason
    lastDenialReason;
/* Observation only: an undefined result does not say whether execution
 * occurred. Deltas distinguish executor entry from boundary rejection without
 * changing policy, authority, or the provider's return value. */
@property (nonatomic, readonly) NSUInteger executorEntryCount;
@property (nonatomic, readonly) NSUInteger denialCount;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

- (id) invokeScope:(NSString *)scope
         memberKind:(CydiaLegacyBridgeMemberKind)memberKind
         memberName:(NSString *)memberName
          arguments:(NSArray *)arguments
       targetOrigin:(NSURL *)targetOrigin;
- (CydiaLegacyUICompatibilityDecision *) decisionForScope:(NSString *)scope
                                                memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                                                memberName:(NSString *)memberName
                                                 arguments:(NSArray *)arguments
                                              targetOrigin:(NSURL *)targetOrigin;
- (id) invokeSnapshot:(CydiaLegacyUICompatibilityNativeSnapshot *)snapshot
           memberName:(NSString *)memberName
            arguments:(NSArray *)arguments;
- (CydiaLegacyUICompatibilityDecision *) decisionForSnapshot:(CydiaLegacyUICompatibilityNativeSnapshot *)snapshot
                                                  memberName:(NSString *)memberName
                                                   arguments:(NSArray *)arguments;
- (BOOL) handoffRouteURL:(NSURL *)url;
@property (nonatomic, readonly, strong)
    CydiaUIRouteDispatchResult *lastRouteResult;
- (void) invalidate;
@end

@interface CydiaLegacyUICompatibilityNativeCaller : NSObject
@property (nonatomic, readonly, strong)
    CydiaLegacyUICompatibilityNativeCapability *capability;
@property (nonatomic, readonly, strong)
    id<CydiaLegacyUICompatibilityNativeReading> reader;
@property (nonatomic, readonly, strong)
    id<CydiaLegacyUICompatibilityNativeCommanding> commander;
@property (nonatomic, readonly, strong)
    id<CydiaLegacyUICompatibilityNativeRouting> router;
@property (nonatomic, readonly, getter=isActive) BOOL active;

/* Called by Cydia-owned startup code only.  The application object is bound
 * weakly by the capability; releasing/revoking it invalidates old sessions. */
+ (CydiaLegacyUICompatibilityNativeCapability *)
    issueCapabilityForApplication:(id)application;

- (instancetype) initWithCapability:(CydiaLegacyUICompatibilityNativeCapability *)capability
                              reader:(id<CydiaLegacyUICompatibilityNativeReading>)reader
                           commander:(id<CydiaLegacyUICompatibilityNativeCommanding>)commander
                              router:(id<CydiaLegacyUICompatibilityNativeRouting>)router
    NS_DESIGNATED_INITIALIZER;
- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

- (CydiaLegacyUICompatibilityNativeSession *) sessionForScope:(NSString *)scope
                                                        target:(id)target
                                               packageIdentity:(NSString *)packageIdentity
                                                     sourceKey:(NSString *)sourceKey
                                                      presenter:(id)presenter;
- (CydiaLegacyUICompatibilityNativeSession *) sessionForScope:(NSString *)scope
                                                        target:(id)target
                                               packageIdentity:(NSString *)packageIdentity
                                                     sourceKey:(NSString *)sourceKey
                                                      presenter:(id)presenter
                                                       context:(CydiaUIRouteContext *)context;
- (void) invalidate;
@end

#endif // Cydia_LegacyUICompatibilityNativeCaller_H
