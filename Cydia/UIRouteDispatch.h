/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_UIRouteDispatch_H
#define Cydia_UIRouteDispatch_H

#include "Cydia/UIRouteContext.h"

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, CydiaUIRouteDispatchOutcome) {
    CydiaUIRouteDispatchOutcomeUnhandled,
    CydiaUIRouteDispatchOutcomeRejected,
    CydiaUIRouteDispatchOutcomeAllowed,
};

typedef NS_ENUM(NSUInteger, CydiaUIRouteDispatchDenialReason) {
    CydiaUIRouteDispatchDenialReasonNone,
    CydiaUIRouteDispatchDenialReasonMalformed,
    CydiaUIRouteDispatchDenialReasonPolicy,
    CydiaUIRouteDispatchDenialReasonUnknownSource,
};

typedef BOOL (^CydiaUIRouteSourceLookup)(NSString *sourceKey);

@interface CydiaUIRouteDispatchResult : NSObject

@property (nonatomic, readonly) CydiaUIRouteDispatchOutcome outcome;
@property (nonatomic, readonly) CydiaUIRouteDispatchDenialReason denialReason;
@property (nonatomic, readonly, strong) CydiaUIRouteDescriptor *descriptor;
@property (nonatomic, readonly, strong) CydiaUIRouteDecision *decision;
@property (nonatomic, readonly, copy) NSError *parseError;
@property (nonatomic, readonly, copy) NSString *requiredSourceKey;
@property (nonatomic, readonly, getter=isHandled) BOOL handled;
@property (nonatomic, readonly, getter=isAllowed) BOOL allowed;
@property (nonatomic, readonly, getter=isPolicyEnforced) BOOL policyEnforced;
@property (nonatomic, readonly, getter=isShadowDenied) BOOL shadowDenied;

@end

/* Every typed caller enforces CydiaUIEvaluateRoute. Source-key existence is a
 * separate execution-safety invariant: unresolved keys fail closed instead
 * of degrading to an all-sources controller. policyEnforced and shadowDenied
 * remain readable for source compatibility; enforced results always report
 * YES and NO respectively. */
FOUNDATION_EXPORT CydiaUIRouteDispatchResult *CydiaUIDispatchRouteURL(
    NSURL *url,
    CydiaUIRouteContext *context,
    CydiaUIRouteSourceLookup sourceLookup);

/* Returns a stable, ordered trusted-native stack. Invalid children are
 * omitted; an invalid or missing root falls back to defaultRoute. Commands
 * such as source/add and launch are never restored from serialized state. */
FOUNDATION_EXPORT NSArray *CydiaUIRestorationRouteURLs(
    NSArray *savedRoutes,
    NSString *defaultRoute,
    CydiaUIRouteSourceLookup sourceLookup);

#endif // Cydia_UIRouteDispatch_H
