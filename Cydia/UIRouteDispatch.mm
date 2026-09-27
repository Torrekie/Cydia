/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/UIRouteDispatch.h"

namespace {

BOOL IsApplicationRouteURL(NSURL *url) {
    NSString *scheme([[url scheme] lowercaseString]);
    return [scheme isEqualToString:@"cydia"] || [scheme isEqualToString:@"apptapp"];
}

NSString *RequiredSourceKey(CydiaUIRouteDescriptor *descriptor) {
    NSArray *arguments([descriptor arguments]);
    if ([descriptor kind] == CydiaUIRouteKindSource && [arguments count] == 1)
        return [arguments objectAtIndex:0];
    if ([descriptor kind] == CydiaUIRouteKindSection && [arguments count] == 2) {
        NSString *key([arguments objectAtIndex:0]);
        return [key isEqualToString:@"*"] ? nil : key;
    }
    return nil;
}

BOOL IsRestorableDescriptor(CydiaUIRouteDescriptor *descriptor) {
    switch ([descriptor kind]) {
        case CydiaUIRouteKindSourceAdd:
        case CydiaUIRouteKindLaunchApplication:
        case CydiaUIRouteKindExternalOpen:
            return NO;
        default:
            return YES;
    }
}

BOOL RestorableRootsMatch(CydiaUIRouteDescriptor *saved,
                          CydiaUIRouteDescriptor *standard) {
    if (saved == nil || standard == nil || [saved kind] != [standard kind])
        return NO;

    /* Search deliberately permits a serialized query as the root variation;
     * every other root must retain the same semantic arguments. */
    if ([standard kind] == CydiaUIRouteKindSearch)
        return YES;
    return [[saved arguments] isEqual:[standard arguments]];
}

} // namespace


@interface CydiaUIRouteDispatchResult ()
- (instancetype) initWithOutcome:(CydiaUIRouteDispatchOutcome)outcome
                    denialReason:(CydiaUIRouteDispatchDenialReason)denialReason
                      descriptor:(CydiaUIRouteDescriptor *)descriptor
                        decision:(CydiaUIRouteDecision *)decision
                      parseError:(NSError *)parseError
               requiredSourceKey:(NSString *)requiredSourceKey
                  policyEnforced:(BOOL)policyEnforced
                    shadowDenied:(BOOL)shadowDenied;
@end

@implementation CydiaUIRouteDispatchResult

- (instancetype) initWithOutcome:(CydiaUIRouteDispatchOutcome)outcome
                    denialReason:(CydiaUIRouteDispatchDenialReason)denialReason
                      descriptor:(CydiaUIRouteDescriptor *)descriptor
                        decision:(CydiaUIRouteDecision *)decision
                      parseError:(NSError *)parseError
               requiredSourceKey:(NSString *)requiredSourceKey
                  policyEnforced:(BOOL)policyEnforced
                    shadowDenied:(BOOL)shadowDenied {
    if ((self = [super init]) != nil) {
        _outcome = outcome;
        _denialReason = denialReason;
        _descriptor = descriptor;
        _decision = decision;
        _parseError = [parseError copy];
        _requiredSourceKey = [requiredSourceKey copy];
        _policyEnforced = policyEnforced;
        _shadowDenied = shadowDenied;
    }
    return self;
}

- (BOOL) isHandled {
    return _outcome != CydiaUIRouteDispatchOutcomeUnhandled;
}

- (BOOL) isAllowed {
    return _outcome == CydiaUIRouteDispatchOutcomeAllowed;
}

@end


CydiaUIRouteDispatchResult *CydiaUIDispatchRouteURL(
    NSURL *url,
    CydiaUIRouteContext *context,
    CydiaUIRouteSourceLookup sourceLookup) {
    const BOOL policyEnforced(YES);
    if (!IsApplicationRouteURL(url))
        return [[CydiaUIRouteDispatchResult alloc]
            initWithOutcome:CydiaUIRouteDispatchOutcomeUnhandled
            denialReason:CydiaUIRouteDispatchDenialReasonNone
            descriptor:nil decision:nil parseError:nil requiredSourceKey:nil
            policyEnforced:policyEnforced shadowDenied:NO];

    NSError *error(nil);
    CydiaUIRouteDescriptor *descriptor(CydiaUIParseRouteURL(url, &error));
    CydiaUIRouteDecision *decision(CydiaUIEvaluateRoute(descriptor, context));
    if (descriptor == nil)
        return [[CydiaUIRouteDispatchResult alloc]
            initWithOutcome:CydiaUIRouteDispatchOutcomeRejected
            denialReason:CydiaUIRouteDispatchDenialReasonMalformed
            descriptor:nil decision:decision parseError:error requiredSourceKey:nil
            policyEnforced:policyEnforced shadowDenied:NO];

    if (![decision isAllowed])
        return [[CydiaUIRouteDispatchResult alloc]
            initWithOutcome:CydiaUIRouteDispatchOutcomeRejected
            denialReason:CydiaUIRouteDispatchDenialReasonPolicy
            descriptor:descriptor decision:decision parseError:nil requiredSourceKey:nil
            policyEnforced:YES shadowDenied:NO];

    /* A missing opaque key must never flow into a source:nil factory and
     * widen a scoped route to all sources. */
    NSString *sourceKey(RequiredSourceKey(descriptor));
    if (sourceKey != nil && (sourceLookup == nil || !sourceLookup(sourceKey)))
        return [[CydiaUIRouteDispatchResult alloc]
            initWithOutcome:CydiaUIRouteDispatchOutcomeRejected
            denialReason:CydiaUIRouteDispatchDenialReasonUnknownSource
            descriptor:descriptor decision:decision parseError:nil
            requiredSourceKey:sourceKey policyEnforced:YES shadowDenied:NO];

    return [[CydiaUIRouteDispatchResult alloc]
        initWithOutcome:CydiaUIRouteDispatchOutcomeAllowed
        denialReason:CydiaUIRouteDispatchDenialReasonNone
        descriptor:descriptor decision:decision parseError:nil
        requiredSourceKey:sourceKey policyEnforced:YES shadowDenied:NO];
}

NSArray *CydiaUIRestorationRouteURLs(
    NSArray *savedRoutes,
    NSString *defaultRoute,
    CydiaUIRouteSourceLookup sourceLookup) {
    CydiaUIRouteContext *context([CydiaUIRouteContext trustedNativeContext]);
    NSURL *defaultURL([NSURL URLWithString:defaultRoute]);
    CydiaUIRouteDispatchResult *defaultResult(CydiaUIDispatchRouteURL(
        defaultURL, context, sourceLookup));
    if (![defaultResult isAllowed] || !IsRestorableDescriptor([defaultResult descriptor]))
        return @[];

    NSMutableArray *routes([NSMutableArray array]);
    BOOL validRoot(NO);
    if ([savedRoutes count] != 0 && [[savedRoutes objectAtIndex:0] isKindOfClass:[NSString class]]) {
        NSString *savedRoot([savedRoutes objectAtIndex:0]);
        CydiaUIRouteDispatchResult *rootResult(CydiaUIDispatchRouteURL(
            [NSURL URLWithString:savedRoot], context, sourceLookup));
        validRoot = [rootResult isAllowed] &&
            IsRestorableDescriptor([rootResult descriptor]) &&
            RestorableRootsMatch([rootResult descriptor], [defaultResult descriptor]);
        if (validRoot)
            [routes addObject:[[rootResult descriptor] originalURL]];
    }

    if (!validRoot)
        return @[[[defaultResult descriptor] originalURL]];

    for (NSUInteger index(1); index != [savedRoutes count]; ++index) {
        id value([savedRoutes objectAtIndex:index]);
        if (![value isKindOfClass:[NSString class]])
            continue;
        CydiaUIRouteDispatchResult *result(CydiaUIDispatchRouteURL(
            [NSURL URLWithString:value], context, sourceLookup));
        if ([result isAllowed] && IsRestorableDescriptor([result descriptor]))
            [routes addObject:[[result descriptor] originalURL]];
    }
    return routes;
}
