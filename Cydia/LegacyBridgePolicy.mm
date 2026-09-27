/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyBridgePolicy.h"

#include <objc/runtime.h>

namespace {

BOOL IsString(id value) {
    return [value isKindOfClass:[NSString class]];
}

BOOL IsURL(id value) {
    return [value isKindOfClass:[NSURL class]];
}

BOOL HasCredentials(NSURL *url) {
    return [[url user] length] != 0 || [[url password] length] != 0;
}

BOOL HasValidPort(NSURL *url) {
    NSNumber *port([url port]);
    if (port == nil)
        return YES;
    NSInteger value([port integerValue]);
    return value > 0 && value <= 65535;
}

BOOL IsWebOrigin(NSURL *origin) {
    if (!IsURL(origin) || [[origin absoluteString] length] == 0 || HasCredentials(origin))
        return NO;
    NSString *scheme([[origin scheme] lowercaseString]);
    return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
        [[origin host] length] != 0 && HasValidPort(origin);
}

BOOL IsBundleFileOrigin(NSURL *origin) {
    if (!IsURL(origin) || ![origin isFileURL] || HasCredentials(origin))
        return NO;
    NSString *host([[origin host] lowercaseString]);
    if ([host length] != 0 && ![host isEqualToString:@"localhost"])
        return NO;
    NSString *bundle([[[NSBundle mainBundle] bundlePath] stringByStandardizingPath]);
    NSString *path([[origin path] stringByStandardizingPath]);
    return [bundle length] != 0 && [path length] != 0 &&
        ([path isEqualToString:bundle] ||
         [path hasPrefix:[bundle stringByAppendingString:@"/"]]);
}

BOOL IsTrustedLegacyOrigin(NSURL *origin) {
    if (IsBundleFileOrigin(origin))
        return YES;
    if (!IsWebOrigin(origin))
        return NO;
    NSString *scheme([[origin scheme] lowercaseString]);
    NSString *host([[origin host] lowercaseString]);
    NSNumber *port([origin port]);
    return [scheme isEqualToString:@"https"] &&
        [host isEqualToString:@"cydia.saurik.com"] &&
        (port == nil || [port integerValue] == 443);
}

NSInteger EffectivePort(NSURL *url) {
    NSNumber *port([url port]);
    if (port != nil)
        return [port integerValue];
    return [[[url scheme] lowercaseString] isEqualToString:@"https"] ? 443 : 80;
}

BOOL SameSecurityOrigin(NSURL *left, NSURL *right) {
    if (!IsURL(left) || !IsURL(right))
        return NO;
    if ([left isFileURL] || [right isFileURL])
        return IsBundleFileOrigin(left) && IsBundleFileOrigin(right);
    if (!IsWebOrigin(left) || !IsWebOrigin(right))
        return NO;
    return [[[left scheme] lowercaseString] isEqualToString:[[right scheme] lowercaseString]] &&
        [[[left host] lowercaseString] isEqualToString:[[right host] lowercaseString]] &&
        EffectivePort(left) == EffectivePort(right);
}

BOOL IsPackageIdentity(NSString *identity) {
    if (!IsString(identity) || [identity length] == 0 ||
        [identity isEqualToString:@"."] || [identity isEqualToString:@".."])
        return NO;
    return [identity rangeOfString:@"/"].location == NSNotFound &&
        [identity rangeOfString:@"\\"].location == NSNotFound &&
        [identity rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

BOOL IsDepictionReadOnlyFamily(CydiaLegacyBridgeOperationFamily family) {
    return family == CydiaLegacyBridgeOperationFamilyRendering ||
        family == CydiaLegacyBridgeOperationFamilyPackageRead ||
        family == CydiaLegacyBridgeOperationFamilySourceRead;
}

} // namespace


@interface CydiaLegacyBridgeMember ()
- (instancetype) initWithScope:(NSString *)scope
                           kind:(CydiaLegacyBridgeMemberKind)kind
                           name:(NSString *)name
                     sourceForm:(NSString *)sourceForm
                         family:(CydiaLegacyBridgeOperationFamily)family
             trustedRequirement:(CydiaLegacyBridgeAccessRequirement)trustedRequirement
           depictionRequirement:(CydiaLegacyBridgeAccessRequirement)depictionRequirement;
@end

@implementation CydiaLegacyBridgeMember

- (instancetype) initWithScope:(NSString *)scope
                           kind:(CydiaLegacyBridgeMemberKind)kind
                           name:(NSString *)name
                     sourceForm:(NSString *)sourceForm
                         family:(CydiaLegacyBridgeOperationFamily)family
             trustedRequirement:(CydiaLegacyBridgeAccessRequirement)trustedRequirement
           depictionRequirement:(CydiaLegacyBridgeAccessRequirement)depictionRequirement {
    if ((self = [super init]) != nil) {
        _scope = [scope copy];
        _kind = kind;
        _name = [name copy];
        _sourceForm = [sourceForm copy];
        _family = family;
        _trustedLegacyRequirement = trustedRequirement;
        _repositoryDepictionRequirement = depictionRequirement;
    }
    return self;
}

@end


@implementation CydiaLegacyBridgeRequest

- (instancetype) initWithScope:(NSString *)scope
                    memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                    memberName:(NSString *)memberName
                       context:(CydiaUIRouteContext *)context
                 callingOrigin:(NSURL *)callingOrigin
               packageIdentity:(NSString *)packageIdentity
                  targetOrigin:(NSURL *)targetOrigin {
    return [self initWithScope:scope memberKind:memberKind memberName:memberName
        context:context callingOrigin:callingOrigin packageIdentity:packageIdentity
        targetOrigin:targetOrigin inProcessCapability:nil];
}

- (instancetype) initWithScope:(NSString *)scope
                    memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                    memberName:(NSString *)memberName
                       context:(CydiaUIRouteContext *)context
                 callingOrigin:(NSURL *)callingOrigin
               packageIdentity:(NSString *)packageIdentity
                  targetOrigin:(NSURL *)targetOrigin
          inProcessCapability:(CydiaLegacyUICompatibilityNativeCapability *)capability {
    if ((self = [super init]) != nil) {
        _scope = [scope copy];
        _memberKind = memberKind;
        _memberName = [memberName copy];
        _context = context;
        _callingOrigin = [callingOrigin copy];
        _packageIdentity = [packageIdentity copy];
        _targetOrigin = [targetOrigin copy];
        _inProcessCapability = capability;
    }
    return self;
}

@end


@interface CydiaLegacyBridgeAuthorization ()
- (instancetype) initWithMember:(CydiaLegacyBridgeMember *)member
                    disposition:(CydiaLegacyBridgeAuthorizationDisposition)disposition
                   denialReason:(CydiaLegacyBridgeDenialReason)denialReason;
@end


@implementation CydiaLegacyBridgeAuthorization

- (instancetype) initWithMember:(CydiaLegacyBridgeMember *)member
                    disposition:(CydiaLegacyBridgeAuthorizationDisposition)disposition
                   denialReason:(CydiaLegacyBridgeDenialReason)denialReason {
    if ((self = [super init]) != nil) {
        _member = member;
        _disposition = disposition;
        _denialReason = denialReason;
    }
    return self;
}

- (BOOL) isAllowed {
    return _disposition != CydiaLegacyBridgeAuthorizationDispositionDenied;
}

- (BOOL) isDepictionReadOnly {
    return _disposition == CydiaLegacyBridgeAuthorizationDispositionDepictionReadOnly;
}

@end


#define CYDIA_LEGACY_BRIDGE_STRINGIFY_(value) @#value
#define CYDIA_LEGACY_BRIDGE_STRINGIFY(value) CYDIA_LEGACY_BRIDGE_STRINGIFY_(value)
#define CYDIA_LEGACY_BRIDGE_FAMILY_sensitive CydiaLegacyBridgeOperationFamilySensitive
#define CYDIA_LEGACY_BRIDGE_FAMILY_mutation CydiaLegacyBridgeOperationFamilyMutation
#define CYDIA_LEGACY_BRIDGE_FAMILY_global_read CydiaLegacyBridgeOperationFamilyGlobalRead
#define CYDIA_LEGACY_BRIDGE_FAMILY_package_read CydiaLegacyBridgeOperationFamilyPackageRead
#define CYDIA_LEGACY_BRIDGE_FAMILY_source_read CydiaLegacyBridgeOperationFamilySourceRead
#define CYDIA_LEGACY_BRIDGE_FAMILY_session CydiaLegacyBridgeOperationFamilySession
#define CYDIA_LEGACY_BRIDGE_FAMILY_chrome CydiaLegacyBridgeOperationFamilyChrome
#define CYDIA_LEGACY_BRIDGE_FAMILY_clipboard CydiaLegacyBridgeOperationFamilyClipboard
#define CYDIA_LEGACY_BRIDGE_FAMILY_rendering CydiaLegacyBridgeOperationFamilyRendering
#define CYDIA_LEGACY_BRIDGE_FAMILY_retired CydiaLegacyBridgeOperationFamilyRetired
#define CYDIA_LEGACY_BRIDGE_KIND_method CydiaLegacyBridgeMemberKindMethod
#define CYDIA_LEGACY_BRIDGE_KIND_attribute CydiaLegacyBridgeMemberKindAttribute
#define CYDIA_LEGACY_BRIDGE_KIND_global CydiaLegacyBridgeMemberKindGlobal
#define CYDIA_LEGACY_BRIDGE_KIND_dynamic_method CydiaLegacyBridgeMemberKindDynamicMethod
#define CYDIA_LEGACY_BRIDGE_KIND_key_policy CydiaLegacyBridgeMemberKindKeyPolicy
#define CYDIA_LEGACY_BRIDGE_SOURCE_selector_mapping @"selector-mapping"
#define CYDIA_LEGACY_BRIDGE_SOURCE_attribute_keys @"attribute-keys"
#define CYDIA_LEGACY_BRIDGE_SOURCE_wildcard_unexcluded @"wildcard-unexcluded"
#define CYDIA_LEGACY_BRIDGE_SOURCE_window_injection @"window-injection"
#define CYDIA_LEGACY_BRIDGE_SOURCE_undefined_method @"undefined-method"
#define CYDIA_LEGACY_BRIDGE_ACCESS_deny CydiaLegacyBridgeAccessRequirementDenied
#define CYDIA_LEGACY_BRIDGE_ACCESS_allow CydiaLegacyBridgeAccessRequirementAllowed
#define CYDIA_LEGACY_BRIDGE_ACCESS_gesture CydiaLegacyBridgeAccessRequirementUserGesture
#define CYDIA_LEGACY_BRIDGE_ACCESS_current_package CydiaLegacyBridgeAccessRequirementCurrentPackage
#define CYDIA_LEGACY_BRIDGE_ACCESS_current_source CydiaLegacyBridgeAccessRequirementCurrentSource
#define CYDIA_LEGACY_BRIDGE_ACCESS_allowlisted CydiaLegacyBridgeAccessRequirementAllowlistedOrigin
#define CYDIA_LEGACY_BRIDGE_ACCESS_retired CydiaLegacyBridgeAccessRequirementRetired

NSArray<CydiaLegacyBridgeMember *> *CydiaLegacyBridgeMembers(void) {
    static NSArray<CydiaLegacyBridgeMember *> *members;
    @synchronized([CydiaLegacyBridgeMember class]) {
        if (members == nil) {
#define CYDIA_LEGACY_BRIDGE_MEMBER(scope_token, kind_token, member_token, source_token, family_token, trusted_token, depiction_token) \
            [[CydiaLegacyBridgeMember alloc] \
                initWithScope:CYDIA_LEGACY_BRIDGE_STRINGIFY(scope_token) \
                kind:CYDIA_LEGACY_BRIDGE_KIND_##kind_token \
                name:CYDIA_LEGACY_BRIDGE_STRINGIFY(member_token) \
                sourceForm:CYDIA_LEGACY_BRIDGE_SOURCE_##source_token \
                family:CYDIA_LEGACY_BRIDGE_FAMILY_##family_token \
                trustedRequirement:CYDIA_LEGACY_BRIDGE_ACCESS_##trusted_token \
                depictionRequirement:CYDIA_LEGACY_BRIDGE_ACCESS_##depiction_token],
#define CYDIA_LEGACY_BRIDGE_OPERATION(scope_token, operation_token, family_token, trusted_token, depiction_token) \
            CYDIA_LEGACY_BRIDGE_MEMBER(scope_token, method, operation_token, selector_mapping, family_token, trusted_token, depiction_token)
#define CYDIA_LEGACY_BRIDGE_PROPERTY(scope_token, kind_token, member_token, source_token, family_token, trusted_token, depiction_token) \
            CYDIA_LEGACY_BRIDGE_MEMBER(scope_token, kind_token, member_token, source_token, family_token, trusted_token, depiction_token)
            members = @[
#include "Cydia/LegacyBridgeOperations.def"
#include "Cydia/LegacyBridgeProperties.def"
            ];
#undef CYDIA_LEGACY_BRIDGE_PROPERTY
#undef CYDIA_LEGACY_BRIDGE_OPERATION
#undef CYDIA_LEGACY_BRIDGE_MEMBER
        }
    }
    return members;
}

CydiaLegacyBridgeMember *CydiaLegacyBridgeMemberForName(NSString *scope,
                                                         CydiaLegacyBridgeMemberKind kind,
                                                         NSString *name) {
    if (!IsString(scope) || !IsString(name) || [scope length] == 0 || [name length] == 0)
        return nil;
    for (CydiaLegacyBridgeMember *member in CydiaLegacyBridgeMembers())
        if ([member kind] == kind && [[member scope] isEqualToString:scope] &&
            [[member name] isEqualToString:name])
            return member;
    return nil;
}

NSString *CydiaLegacyBridgeMemberKindName(CydiaLegacyBridgeMemberKind kind) {
    switch (kind) {
        case CydiaLegacyBridgeMemberKindMethod: return @"method";
        case CydiaLegacyBridgeMemberKindAttribute: return @"attribute";
        case CydiaLegacyBridgeMemberKindGlobal: return @"global";
        case CydiaLegacyBridgeMemberKindDynamicMethod: return @"dynamic-method";
        case CydiaLegacyBridgeMemberKindKeyPolicy: return @"key-policy";
    }
    return nil;
}

NSString *CydiaLegacyBridgeOperationFamilyName(CydiaLegacyBridgeOperationFamily family) {
    switch (family) {
        case CydiaLegacyBridgeOperationFamilySensitive: return @"sensitive";
        case CydiaLegacyBridgeOperationFamilyMutation: return @"mutation";
        case CydiaLegacyBridgeOperationFamilyGlobalRead: return @"global-read";
        case CydiaLegacyBridgeOperationFamilyPackageRead: return @"package-read";
        case CydiaLegacyBridgeOperationFamilySourceRead: return @"source-read";
        case CydiaLegacyBridgeOperationFamilySession: return @"session";
        case CydiaLegacyBridgeOperationFamilyChrome: return @"chrome";
        case CydiaLegacyBridgeOperationFamilyClipboard: return @"clipboard";
        case CydiaLegacyBridgeOperationFamilyRendering: return @"rendering";
        case CydiaLegacyBridgeOperationFamilyRetired: return @"retired";
    }
    return nil;
}

NSString *CydiaLegacyBridgeAccessRequirementName(CydiaLegacyBridgeAccessRequirement requirement) {
    switch (requirement) {
        case CydiaLegacyBridgeAccessRequirementDenied: return @"deny";
        case CydiaLegacyBridgeAccessRequirementAllowed: return @"allow";
        case CydiaLegacyBridgeAccessRequirementUserGesture: return @"gesture";
        case CydiaLegacyBridgeAccessRequirementCurrentPackage: return @"current-package";
        case CydiaLegacyBridgeAccessRequirementCurrentSource: return @"current-source";
        case CydiaLegacyBridgeAccessRequirementAllowlistedOrigin: return @"allowlisted";
        case CydiaLegacyBridgeAccessRequirementRetired: return @"retired";
    }
    return nil;
}

namespace {

CydiaLegacyBridgeAuthorization *Authorization(CydiaLegacyBridgeMember *member,
    CydiaLegacyBridgeAuthorizationDisposition disposition,
    CydiaLegacyBridgeDenialReason denialReason) {
    return [[CydiaLegacyBridgeAuthorization alloc] initWithMember:member
        disposition:disposition denialReason:denialReason];
}

CydiaLegacyBridgeAuthorization *Denied(CydiaLegacyBridgeMember *member,
                                       CydiaLegacyBridgeDenialReason reason) {
    return Authorization(member, CydiaLegacyBridgeAuthorizationDispositionDenied, reason);
}

BOOL IsValidInProcessCapability(id capability) {
    if (capability == nil)
        return NO;
    Class capabilityClass(NSClassFromString(
        @"CydiaLegacyUICompatibilityNativeCapability"));
    SEL validator(NSSelectorFromString(@"_isValidForLegacyBridge"));
    if (capabilityClass == Nil || object_getClass(capability) != capabilityClass ||
        ![capability respondsToSelector:validator])
        return NO;
    NSMethodSignature *signature([capability methodSignatureForSelector:validator]);
    if (signature == nil || [signature numberOfArguments] != 2)
        return NO;
    const char *returnType([signature methodReturnType]);
    if (returnType == NULL ||
        (returnType[0] != 'B' && returnType[0] != 'c' && returnType[0] != 'C') ||
        [signature methodReturnLength] > sizeof(BOOL))
        return NO;
    NSInvocation *invocation([NSInvocation invocationWithMethodSignature:signature]);
    [invocation setTarget:capability];
    [invocation setSelector:validator];
    @try {
        [invocation invoke];
        BOOL result(NO);
        [invocation getReturnValue:&result];
        return result;
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
}

} // namespace

CydiaLegacyBridgeAuthorization *CydiaLegacyBridgeAuthorize(CydiaLegacyBridgeRequest *request) {
    if (object_getClass(request) != [CydiaLegacyBridgeRequest class])
        return Denied(nil, CydiaLegacyBridgeDenialReasonMalformedRequest);

    CydiaLegacyBridgeMember *member(CydiaLegacyBridgeMemberForName(
        [request scope], [request memberKind], [request memberName]));
    if (member == nil)
        return Denied(nil, CydiaLegacyBridgeDenialReasonUnknownMember);

    CydiaUIRouteContext *context([request context]);
    if (object_getClass(context) != [CydiaUIRouteContext class])
        return Denied(member, CydiaLegacyBridgeDenialReasonMissingContext);

    NSURL *initiatingOrigin([context initiatingOrigin]);
    NSURL *callingOrigin([request callingOrigin]);

    switch ([context caller]) {
        case CydiaUIRouteCallerTrustedInProcess: {
            /* In-process compatibility has no web origin.  The context and
             * request must carry the exact same live app-issued token;
             * a forged enum/context or a revoked token fails closed. */
            id contextCapability([context inProcessCapability]);
            if (![context isMainFrame] || [context initiatingOrigin] != nil ||
                [request callingOrigin] != nil ||
                [request targetOrigin] != nil ||
                contextCapability == nil ||
                [request inProcessCapability] != contextCapability ||
                !IsValidInProcessCapability(contextCapability))
                return Denied(member, CydiaLegacyBridgeDenialReasonCaller);
            if ([request packageIdentity] != nil &&
                !IsPackageIdentity([request packageIdentity]))
                return Denied(member, CydiaLegacyBridgeDenialReasonPackageIdentity);

            CydiaLegacyBridgeOperationFamily family([member family]);
            if (family == CydiaLegacyBridgeOperationFamilySensitive ||
                family == CydiaLegacyBridgeOperationFamilyChrome ||
                family == CydiaLegacyBridgeOperationFamilyClipboard ||
                family == CydiaLegacyBridgeOperationFamilyRetired)
                return Denied(member, CydiaLegacyBridgeDenialReasonCaller);
            /* Session writes and all unreviewed session/chrome helpers stay
             * unavailable; a future provider can add a narrowly typed read. */
            if (family == CydiaLegacyBridgeOperationFamilySession &&
                ![[member name] isEqualToString:@"getSessionValue"])
                return Denied(member, CydiaLegacyBridgeDenialReasonCaller);

            CydiaLegacyBridgeAccessRequirement requirement(
                [member trustedLegacyRequirement]);
            if (requirement == CydiaLegacyBridgeAccessRequirementRetired ||
                requirement == CydiaLegacyBridgeAccessRequirementDenied)
                return Denied(member, CydiaLegacyBridgeDenialReasonCaller);
            if (requirement == CydiaLegacyBridgeAccessRequirementUserGesture &&
                ![context hasUserGesture])
                return Denied(member, CydiaLegacyBridgeDenialReasonUserGesture);
            return Authorization(member,
                CydiaLegacyBridgeAuthorizationDispositionTrustedLegacyCompatibility,
                CydiaLegacyBridgeDenialReasonNone);
        }

        case CydiaUIRouteCallerTrustedLegacyPage: {
            if (!IsTrustedLegacyOrigin(initiatingOrigin) ||
                !IsTrustedLegacyOrigin(callingOrigin) ||
                !SameSecurityOrigin(initiatingOrigin, callingOrigin))
                return Denied(member, CydiaLegacyBridgeDenialReasonOrigin);

            CydiaLegacyBridgeAccessRequirement requirement(
                [member trustedLegacyRequirement]);
            if (requirement == CydiaLegacyBridgeAccessRequirementRetired)
                return Denied(member, CydiaLegacyBridgeDenialReasonRetiredSurface);
            if (requirement == CydiaLegacyBridgeAccessRequirementDenied)
                return Denied(member, CydiaLegacyBridgeDenialReasonCaller);
            if (requirement == CydiaLegacyBridgeAccessRequirementUserGesture &&
                ![context hasUserGesture])
                return Denied(member, CydiaLegacyBridgeDenialReasonUserGesture);
            return Authorization(member,
                CydiaLegacyBridgeAuthorizationDispositionTrustedLegacyCompatibility,
                CydiaLegacyBridgeDenialReasonNone);
        }

        case CydiaUIRouteCallerRepositoryDepiction: {
            if (![context isMainFrame])
                return Denied(member, CydiaLegacyBridgeDenialReasonMainFrame);
            if (!IsWebOrigin(initiatingOrigin) || !IsWebOrigin(callingOrigin) ||
                !SameSecurityOrigin(initiatingOrigin, callingOrigin))
                return Denied(member, CydiaLegacyBridgeDenialReasonOrigin);
            if (!IsPackageIdentity([context depictionPackageIdentity]))
                return Denied(member, CydiaLegacyBridgeDenialReasonPackageIdentity);
            if ([member repositoryDepictionRequirement] ==
                    CydiaLegacyBridgeAccessRequirementRetired)
                return Denied(member, CydiaLegacyBridgeDenialReasonRetiredSurface);
            if (!IsDepictionReadOnlyFamily([member family]))
                return Denied(member, CydiaLegacyBridgeDenialReasonCaller);

            switch ([member repositoryDepictionRequirement]) {
                case CydiaLegacyBridgeAccessRequirementAllowed:
                    break;
                case CydiaLegacyBridgeAccessRequirementCurrentPackage:
                case CydiaLegacyBridgeAccessRequirementCurrentSource:
                    if (!IsPackageIdentity([request packageIdentity]) ||
                        ![[request packageIdentity] isEqualToString:
                            [context depictionPackageIdentity]])
                        return Denied(member,
                            CydiaLegacyBridgeDenialReasonPackageIdentity);
                    break;
                case CydiaLegacyBridgeAccessRequirementAllowlistedOrigin:
                    if (!IsWebOrigin([request targetOrigin]) ||
                        !SameSecurityOrigin(callingOrigin, [request targetOrigin]))
                        return Denied(member,
                            CydiaLegacyBridgeDenialReasonTargetOrigin);
                    break;
                case CydiaLegacyBridgeAccessRequirementUserGesture:
                    if (![context hasUserGesture])
                        return Denied(member,
                            CydiaLegacyBridgeDenialReasonUserGesture);
                    break;
                case CydiaLegacyBridgeAccessRequirementDenied:
                    return Denied(member, CydiaLegacyBridgeDenialReasonCaller);
                case CydiaLegacyBridgeAccessRequirementRetired:
                    return Denied(member, CydiaLegacyBridgeDenialReasonRetiredSurface);
            }

            return Authorization(member,
                CydiaLegacyBridgeAuthorizationDispositionDepictionReadOnly,
                CydiaLegacyBridgeDenialReasonNone);
        }

        case CydiaUIRouteCallerTrustedNative:
        case CydiaUIRouteCallerExternalURL:
        case CydiaUIRouteCallerUntrustedWebPage:
            return Denied(member, CydiaLegacyBridgeDenialReasonCaller);
    }

    return Denied(member, CydiaLegacyBridgeDenialReasonCaller);
}

#undef CYDIA_LEGACY_BRIDGE_ACCESS_retired
#undef CYDIA_LEGACY_BRIDGE_ACCESS_allowlisted
#undef CYDIA_LEGACY_BRIDGE_ACCESS_current_source
#undef CYDIA_LEGACY_BRIDGE_ACCESS_current_package
#undef CYDIA_LEGACY_BRIDGE_ACCESS_gesture
#undef CYDIA_LEGACY_BRIDGE_ACCESS_allow
#undef CYDIA_LEGACY_BRIDGE_ACCESS_deny
#undef CYDIA_LEGACY_BRIDGE_KIND_key_policy
#undef CYDIA_LEGACY_BRIDGE_KIND_dynamic_method
#undef CYDIA_LEGACY_BRIDGE_KIND_global
#undef CYDIA_LEGACY_BRIDGE_KIND_attribute
#undef CYDIA_LEGACY_BRIDGE_KIND_method
#undef CYDIA_LEGACY_BRIDGE_SOURCE_undefined_method
#undef CYDIA_LEGACY_BRIDGE_SOURCE_window_injection
#undef CYDIA_LEGACY_BRIDGE_SOURCE_wildcard_unexcluded
#undef CYDIA_LEGACY_BRIDGE_SOURCE_attribute_keys
#undef CYDIA_LEGACY_BRIDGE_SOURCE_selector_mapping
#undef CYDIA_LEGACY_BRIDGE_FAMILY_retired
#undef CYDIA_LEGACY_BRIDGE_FAMILY_rendering
#undef CYDIA_LEGACY_BRIDGE_FAMILY_clipboard
#undef CYDIA_LEGACY_BRIDGE_FAMILY_chrome
#undef CYDIA_LEGACY_BRIDGE_FAMILY_session
#undef CYDIA_LEGACY_BRIDGE_FAMILY_source_read
#undef CYDIA_LEGACY_BRIDGE_FAMILY_package_read
#undef CYDIA_LEGACY_BRIDGE_FAMILY_global_read
#undef CYDIA_LEGACY_BRIDGE_FAMILY_mutation
#undef CYDIA_LEGACY_BRIDGE_FAMILY_sensitive
#undef CYDIA_LEGACY_BRIDGE_STRINGIFY
#undef CYDIA_LEGACY_BRIDGE_STRINGIFY_
