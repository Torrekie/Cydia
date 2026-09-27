/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/UIRouteContext.h"
#include "Cydia/ExternalURLPolicy.h"

#include <objc/runtime.h>

NSString * const CydiaUIRouteErrorDomain = @"dev.torrekie.cydia.ui-route";

namespace {

enum CydiaUIRouteErrorCode {
    CydiaUIRouteErrorMalformed = 1,
    CydiaUIRouteErrorUnsupported = 2,
};

NSError *RouteError(CydiaUIRouteErrorCode code, NSString *description) {
    return [NSError errorWithDomain:CydiaUIRouteErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description ?: @"Invalid Cydia route",
    }];
}

BOOL IsDecodedArgument(NSString *argument) {
    if ([argument length] == 0)
        return NO;
    if ([argument isEqualToString:@"."] || [argument isEqualToString:@".."])
        return NO;
    return [argument rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

NSString *DecodeArgument(NSString *argument) {
    NSString *decoded([argument stringByRemovingPercentEncoding]);
    return decoded != nil && IsDecodedArgument(decoded) ? decoded : nil;
}

BOOL IsRestrictedIdentifier(NSString *argument) {
    if ([argument isEqualToString:@"."] || [argument isEqualToString:@".."])
        return NO;
    return [argument rangeOfString:@"/"].location == NSNotFound &&
        [argument rangeOfString:@"\\"].location == NSNotFound;
}

BOOL IsExternalSchemeAllowed(NSURL *url) {
    return [[CydiaExternalURLPolicy alloc] initWithURL:url] != nil;
}

BOOL IsTrustedLegacyOrigin(NSURL *origin) {
    if ([origin isFileURL]) {
        NSString *bundle([[[NSBundle mainBundle] bundlePath] stringByStandardizingPath]);
        NSString *path([[origin path] stringByStandardizingPath]);
        return [path isEqualToString:bundle] ||
            [path hasPrefix:[bundle stringByAppendingString:@"/"]];
    }

    if (!CydiaExternalURLIsValidWebURL(origin))
        return NO;

    NSString *scheme([[origin scheme] lowercaseString]);
    NSString *host([[origin host] lowercaseString]);
    NSNumber *port([origin port]);
    return [scheme isEqualToString:@"https"] &&
        [host isEqualToString:@"cydia.saurik.com"] &&
        (port == nil || [port integerValue] == 443);
}

BOOL IsRepositoryDepictionOrigin(NSURL *origin) {
    return CydiaExternalURLIsValidWebURL(origin);
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

    NSMethodSignature *methodSignature([capability methodSignatureForSelector:validator]);
    if (methodSignature == nil || [methodSignature numberOfArguments] != 2)
        return NO;
    const char *returnType([methodSignature methodReturnType]);
    if (returnType == NULL ||
        (returnType[0] != 'B' && returnType[0] != 'c' && returnType[0] != 'C') ||
        [methodSignature methodReturnLength] > sizeof(BOOL))
        return NO;
    NSInvocation *invocation([NSInvocation invocationWithMethodSignature:methodSignature]);
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

CydiaUIRouteDisposition DispositionForKind(CydiaUIRouteKind kind) {
    switch (kind) {
        case CydiaUIRouteKindSourceAdd:
        case CydiaUIRouteKindLaunchApplication:
            return CydiaUIRouteDispositionNativeCommand;
        case CydiaUIRouteKindExternalOpen:
            return CydiaUIRouteDispositionExternalOpen;
        default:
            return CydiaUIRouteDispositionNativeController;
    }
}

BOOL CallerAllowsKind(CydiaUIRouteCaller caller, CydiaUIRouteKind kind) {
    switch (caller) {
        case CydiaUIRouteCallerTrustedNative:
            return YES;

        case CydiaUIRouteCallerTrustedInProcess:
            return YES;

        case CydiaUIRouteCallerExternalURL:
            return kind == CydiaUIRouteKindPackage ||
                kind == CydiaUIRouteKindSource ||
                kind == CydiaUIRouteKindSourceAdd ||
                kind == CydiaUIRouteKindExternalOpen;

        case CydiaUIRouteCallerTrustedLegacyPage:
            return kind != CydiaUIRouteKindLaunchApplication;

        case CydiaUIRouteCallerRepositoryDepiction:
        case CydiaUIRouteCallerUntrustedWebPage:
            return kind == CydiaUIRouteKindPackage ||
                kind == CydiaUIRouteKindExternalOpen;
    }

    return NO;
}

} // namespace


@interface CydiaUIRouteContext ()
- (instancetype) initWithCaller:(CydiaUIRouteCaller)caller
                 navigationKind:(CydiaUIRouteNavigationKind)navigationKind
                          origin:(NSURL *)origin
                 packageIdentity:(NSString *)packageIdentity
              inProcessCapability:(CydiaLegacyUICompatibilityNativeCapability *)capability
                       mainFrame:(BOOL)mainFrame
                     userGesture:(BOOL)userGesture;
@end

@implementation CydiaUIRouteContext

- (instancetype) initWithCaller:(CydiaUIRouteCaller)caller
                 navigationKind:(CydiaUIRouteNavigationKind)navigationKind
                          origin:(NSURL *)origin
                 packageIdentity:(NSString *)packageIdentity
              inProcessCapability:(CydiaLegacyUICompatibilityNativeCapability *)capability
                       mainFrame:(BOOL)mainFrame
                     userGesture:(BOOL)userGesture {
    if ((self = [super init]) != nil) {
        _caller = caller;
        _navigationKind = navigationKind;
        _initiatingOrigin = [origin copy];
        _depictionPackageIdentity = [packageIdentity copy];
        _inProcessCapability = capability;
        _mainFrame = mainFrame;
        _userGesture = userGesture;
    }
    return self;
}

+ (instancetype) trustedNativeContext {
    return [[self alloc] initWithCaller:CydiaUIRouteCallerTrustedNative
                         navigationKind:CydiaUIRouteNavigationKindDirect
                                 origin:nil packageIdentity:nil
                      inProcessCapability:nil
                              mainFrame:YES userGesture:YES];
}

+ (instancetype) externalURLContext {
    return [[self alloc] initWithCaller:CydiaUIRouteCallerExternalURL
                         navigationKind:CydiaUIRouteNavigationKindDirect
                                 origin:nil packageIdentity:nil
                      inProcessCapability:nil
                              mainFrame:YES userGesture:YES];
}

+ (instancetype) trustedInProcessContextWithCapability:
    (CydiaLegacyUICompatibilityNativeCapability *)capability {
    if (!IsValidInProcessCapability(capability))
        return nil;
    return [[self alloc] initWithCaller:CydiaUIRouteCallerTrustedInProcess
                         navigationKind:CydiaUIRouteNavigationKindDirect
                                 origin:nil packageIdentity:nil
                      inProcessCapability:capability
                              mainFrame:YES userGesture:YES];
}

+ (instancetype) trustedLegacyPageContextWithOrigin:(NSURL *)origin
                                           mainFrame:(BOOL)mainFrame
                                         userGesture:(BOOL)userGesture {
    if (!IsTrustedLegacyOrigin(origin))
        return nil;
    return [[self alloc] initWithCaller:CydiaUIRouteCallerTrustedLegacyPage
                         navigationKind:CydiaUIRouteNavigationKindDirect
                                 origin:origin packageIdentity:nil
                      inProcessCapability:nil
                              mainFrame:mainFrame userGesture:userGesture];
}

+ (instancetype) repositoryDepictionContextWithOrigin:(NSURL *)origin
                                       packageIdentity:(NSString *)packageIdentity
                                             mainFrame:(BOOL)mainFrame
                                           userGesture:(BOOL)userGesture {
    if (!IsRepositoryDepictionOrigin(origin) ||
        !IsDecodedArgument(packageIdentity) ||
        !IsRestrictedIdentifier(packageIdentity))
        return nil;
    return [[self alloc] initWithCaller:CydiaUIRouteCallerRepositoryDepiction
                         navigationKind:CydiaUIRouteNavigationKindDirect
                                 origin:origin packageIdentity:packageIdentity
                      inProcessCapability:nil
                              mainFrame:mainFrame userGesture:userGesture];
}

- (instancetype) contextForWebNavigationKind:(CydiaUIRouteNavigationKind)navigationKind
                                        origin:(NSURL *)origin
                                     mainFrame:(BOOL)mainFrame
                                   userGesture:(BOOL)userGesture {
    CydiaUIRouteCaller caller(_caller);
    NSURL *initiatingOrigin(_initiatingOrigin ?: origin);
    NSString *packageIdentity(_depictionPackageIdentity);

    /* Native and OS-entry authority describes who opened the controller, not
     * the HTML now making a decision. A trusted legacy page must also lose its
     * temporary authority when the initiating frame is not allowlisted. */
    if (caller == CydiaUIRouteCallerTrustedNative ||
        caller == CydiaUIRouteCallerTrustedInProcess) {
        caller = IsTrustedLegacyOrigin(origin) ?
            CydiaUIRouteCallerTrustedLegacyPage :
            CydiaUIRouteCallerUntrustedWebPage;
        initiatingOrigin = origin;
        packageIdentity = nil;
    } else if (caller == CydiaUIRouteCallerExternalURL) {
        caller = CydiaUIRouteCallerUntrustedWebPage;
        initiatingOrigin = origin ?: initiatingOrigin;
        packageIdentity = nil;
    } else if (caller == CydiaUIRouteCallerTrustedLegacyPage &&
               !IsTrustedLegacyOrigin(origin)) {
        caller = CydiaUIRouteCallerUntrustedWebPage;
        initiatingOrigin = origin ?: initiatingOrigin;
        packageIdentity = nil;
    }

    /* A redirect is part of one navigation lineage and cannot regain a lost
     * gesture. A popup is a distinct interaction: a later verified tap must
     * not stay false merely because the current document arrived
     * automatically. This is metadata-only while legacy web callers remain
     * in shadow mode. */
    BOOL effectiveGesture(navigationKind == CydiaUIRouteNavigationKindPopup ?
        userGesture : _userGesture && userGesture);

    return [[[self class] alloc] initWithCaller:caller
                                 navigationKind:navigationKind
                                         origin:initiatingOrigin
                                packageIdentity:packageIdentity
                             inProcessCapability:nil
                                      mainFrame:mainFrame
                                    userGesture:effectiveGesture];
}

+ (instancetype) untrustedWebPageContextWithOrigin:(NSURL *)origin
                                         mainFrame:(BOOL)mainFrame
                                       userGesture:(BOOL)userGesture {
    return [[self alloc] initWithCaller:CydiaUIRouteCallerUntrustedWebPage
                         navigationKind:CydiaUIRouteNavigationKindDirect
                                 origin:origin packageIdentity:nil
                      inProcessCapability:nil
                              mainFrame:mainFrame userGesture:userGesture];
}

- (instancetype) contextForRedirectWithOrigin:(NSURL *)origin
                                    mainFrame:(BOOL)mainFrame
                                  userGesture:(BOOL)userGesture {
    return [self contextForWebNavigationKind:CydiaUIRouteNavigationKindRedirect
                                       origin:origin mainFrame:mainFrame
                                  userGesture:userGesture];
}

- (instancetype) contextForPopupWithOrigin:(NSURL *)origin
                                  mainFrame:(BOOL)mainFrame
                                userGesture:(BOOL)userGesture {
    return [self contextForWebNavigationKind:CydiaUIRouteNavigationKindPopup
                                       origin:origin mainFrame:mainFrame
                                  userGesture:userGesture];
}

- (id) copyWithZone:(NSZone *)zone {
    (void) zone;
    return self;
}

@end


@interface CydiaUIRouteDescriptor ()
- (instancetype) initWithKind:(CydiaUIRouteKind)kind
                           URL:(NSURL *)url
                     arguments:(NSArray *)arguments
                   externalURL:(NSURL *)externalURL;
@end

@implementation CydiaUIRouteDescriptor

- (instancetype) initWithKind:(CydiaUIRouteKind)kind
                           URL:(NSURL *)url
                     arguments:(NSArray *)arguments
                   externalURL:(NSURL *)externalURL {
    if ((self = [super init]) != nil) {
        _kind = kind;
        _originalURL = [url copy];
        _arguments = [arguments copy] ?: @[];
        _externalURL = [externalURL copy];
    }
    return self;
}

@end


@interface CydiaUIRouteDecision ()
- (instancetype) initWithDescriptor:(CydiaUIRouteDescriptor *)descriptor
                         disposition:(CydiaUIRouteDisposition)disposition
                        denialReason:(CydiaUIRouteDenialReason)denialReason
                requiresConfirmation:(BOOL)requiresConfirmation;
@end

@implementation CydiaUIRouteDecision

- (instancetype) initWithDescriptor:(CydiaUIRouteDescriptor *)descriptor
                         disposition:(CydiaUIRouteDisposition)disposition
                        denialReason:(CydiaUIRouteDenialReason)denialReason
                requiresConfirmation:(BOOL)requiresConfirmation {
    if ((self = [super init]) != nil) {
        _descriptor = descriptor;
        _disposition = disposition;
        _denialReason = denialReason;
        _requiresConfirmation = requiresConfirmation;
    }
    return self;
}

- (BOOL) isAllowed {
    return _disposition != CydiaUIRouteDispositionRejected;
}

@end


CydiaUIRouteDescriptor *CydiaUIParseRouteURL(NSURL *url, NSError **error) {
    if (url == nil || [[url absoluteString] length] == 0) {
        if (error != NULL)
            *error = RouteError(CydiaUIRouteErrorMalformed, @"The route URL is empty");
        return nil;
    }

    NSString *scheme([[url scheme] lowercaseString]);
    NSString *absolute([url absoluteString]);
    const NSUInteger prefixLength([scheme length] + [@"://" length]);
    if ([scheme length] == 0 || [absolute length] <= prefixLength ||
        ![[absolute substringWithRange:NSMakeRange([scheme length], 3)] isEqualToString:@"://"]) {
        if (error != NULL)
            *error = RouteError(CydiaUIRouteErrorMalformed, @"The route must use scheme://path form");
        return nil;
    }

    NSString *path([absolute substringFromIndex:prefixLength]);
    NSArray *rawComponents([path componentsSeparatedByString:@"/"]);
    if ([rawComponents count] == 0 || [[rawComponents objectAtIndex:0] length] == 0) {
        if (error != NULL)
            *error = RouteError(CydiaUIRouteErrorMalformed, @"The route has no command");
        return nil;
    }

    NSString *base([[rawComponents objectAtIndex:0] lowercaseString]);
    if ([scheme isEqualToString:@"apptapp"]) {
        if ([rawComponents count] != 2 || ![base isEqualToString:@"package"]) {
            if (error != NULL)
                *error = RouteError(CydiaUIRouteErrorUnsupported, @"Unsupported apptapp route");
            return nil;
        }
        NSString *identity(DecodeArgument([rawComponents objectAtIndex:1]));
        if (identity == nil || !IsRestrictedIdentifier(identity)) {
            if (error != NULL)
                *error = RouteError(CydiaUIRouteErrorMalformed, @"Invalid package identity");
            return nil;
        }
        return [[CydiaUIRouteDescriptor alloc] initWithKind:CydiaUIRouteKindPackage
                                                        URL:url arguments:@[identity]
                                                externalURL:nil];
    }

    if (![scheme isEqualToString:@"cydia"]) {
        if (error != NULL)
            *error = RouteError(CydiaUIRouteErrorUnsupported, @"Unsupported route scheme");
        return nil;
    }

    if ([base isEqualToString:@"url"]) {
        const NSUInteger offset(prefixLength + [@"url/" length]);
        if ([absolute length] <= offset) {
            if (error != NULL)
                *error = RouteError(CydiaUIRouteErrorMalformed, @"The external URL is empty");
            return nil;
        }
        NSString *encoded([absolute substringFromIndex:offset]);
        NSURL *external([NSURL URLWithString:encoded]);
        if ([[external scheme] length] == 0) {
            NSString *destination([encoded stringByRemovingPercentEncoding]);
            external = [destination length] == 0 ? nil : [NSURL URLWithString:destination];
        }
        if (external == nil) {
            if (error != NULL)
                *error = RouteError(CydiaUIRouteErrorMalformed, @"The external URL is invalid");
            return nil;
        }
        return [[CydiaUIRouteDescriptor alloc] initWithKind:CydiaUIRouteKindExternalOpen
                                                        URL:url arguments:@[]
                                                externalURL:external];
    }

    NSMutableArray *arguments([NSMutableArray arrayWithCapacity:[rawComponents count] - 1]);
    for (NSUInteger index(1); index != [rawComponents count]; ++index) {
        NSString *argument(DecodeArgument([rawComponents objectAtIndex:index]));
        if (argument == nil) {
            if (error != NULL)
                *error = RouteError(CydiaUIRouteErrorMalformed, @"A route argument is invalid");
            return nil;
        }
        [arguments addObject:argument];
    }

    CydiaUIRouteKind kind;
    const NSUInteger count([rawComponents count]);
    if (count == 1 && [base isEqualToString:@"home"])
        kind = CydiaUIRouteKindHome;
    else if (count == 1 && [base isEqualToString:@"sources"])
        kind = CydiaUIRouteKindSources;
    else if (count == 2 && [base isEqualToString:@"sources"] &&
             [[arguments objectAtIndex:0] isEqualToString:@"add"])
        kind = CydiaUIRouteKindSourceAdd;
    else if (count == 2 && [base isEqualToString:@"sources"])
        kind = CydiaUIRouteKindSource;
    else if (count == 1 && [base isEqualToString:@"sections"])
        kind = CydiaUIRouteKindSections;
    else if ((count == 2 || count == 3) && [base isEqualToString:@"sections"])
        kind = CydiaUIRouteKindSection;
    else if ((count == 1 || count == 2) && [base isEqualToString:@"search"])
        kind = CydiaUIRouteKindSearch;
    else if (count == 1 && [base isEqualToString:@"changes"])
        kind = CydiaUIRouteKindChanges;
    else if (count == 1 && [base isEqualToString:@"installed"])
        kind = CydiaUIRouteKindInstalled;
    else if (count == 2 && [base isEqualToString:@"package"])
        kind = CydiaUIRouteKindPackage;
    else if (count == 3 && [base isEqualToString:@"package"] &&
             [[arguments objectAtIndex:1] isEqualToString:@"settings"])
        kind = CydiaUIRouteKindPackageSettings;
    else if (count == 3 && [base isEqualToString:@"package"] &&
             [[arguments objectAtIndex:1] isEqualToString:@"files"])
        kind = CydiaUIRouteKindPackageFiles;
    else if (count == 2 && [base isEqualToString:@"launch"])
        kind = CydiaUIRouteKindLaunchApplication;
    else {
        if (error != NULL)
            *error = RouteError(CydiaUIRouteErrorUnsupported, @"Unsupported Cydia route");
        return nil;
    }

    if ((kind == CydiaUIRouteKindPackage ||
         kind == CydiaUIRouteKindPackageSettings ||
         kind == CydiaUIRouteKindPackageFiles ||
         kind == CydiaUIRouteKindLaunchApplication) &&
        !IsRestrictedIdentifier([arguments objectAtIndex:0])) {
        if (error != NULL)
            *error = RouteError(CydiaUIRouteErrorMalformed, @"Invalid route identifier");
        return nil;
    }

    return [[CydiaUIRouteDescriptor alloc] initWithKind:kind URL:url
                                              arguments:arguments externalURL:nil];
}

CydiaUIRouteDecision *CydiaUIEvaluateRoute(CydiaUIRouteDescriptor *descriptor,
                                            CydiaUIRouteContext *context) {
    if (descriptor == nil || context == nil)
        return [[CydiaUIRouteDecision alloc]
            initWithDescriptor:descriptor
            disposition:CydiaUIRouteDispositionRejected
            denialReason:CydiaUIRouteDenialReasonMalformed
            requiresConfirmation:NO];

    /* Context authority is factory-issued.  Objective-C subclasses can
     * override caller/origin accessors, so no route caller may cross this
     * boundary through a derived context object. */
    if (object_getClass(context) != [CydiaUIRouteContext class])
        return [[CydiaUIRouteDecision alloc]
            initWithDescriptor:descriptor
            disposition:CydiaUIRouteDispositionRejected
            denialReason:CydiaUIRouteDenialReasonCaller
            requiresConfirmation:NO];

    if ([context caller] == CydiaUIRouteCallerTrustedInProcess &&
        (![context isMainFrame] || [context initiatingOrigin] != nil ||
         [context depictionPackageIdentity] != nil ||
         !IsValidInProcessCapability([context inProcessCapability])))
        return [[CydiaUIRouteDecision alloc]
            initWithDescriptor:descriptor
            disposition:CydiaUIRouteDispositionRejected
            denialReason:CydiaUIRouteDenialReasonCaller
            requiresConfirmation:NO];

    if (!CallerAllowsKind([context caller], [descriptor kind]))
        return [[CydiaUIRouteDecision alloc]
            initWithDescriptor:descriptor
            disposition:CydiaUIRouteDispositionRejected
            denialReason:CydiaUIRouteDenialReasonCaller
            requiresConfirmation:NO];

    if ([descriptor kind] == CydiaUIRouteKindExternalOpen) {
        if (!IsExternalSchemeAllowed([descriptor externalURL]))
            return [[CydiaUIRouteDecision alloc]
                initWithDescriptor:descriptor
                disposition:CydiaUIRouteDispositionRejected
                denialReason:CydiaUIRouteDenialReasonScheme
                requiresConfirmation:NO];
        if (([context caller] == CydiaUIRouteCallerRepositoryDepiction ||
             [context caller] == CydiaUIRouteCallerUntrustedWebPage) &&
            ![context hasUserGesture])
            return [[CydiaUIRouteDecision alloc]
                initWithDescriptor:descriptor
                disposition:CydiaUIRouteDispositionRejected
                denialReason:CydiaUIRouteDenialReasonUserGesture
                requiresConfirmation:NO];
    }

    return [[CydiaUIRouteDecision alloc]
        initWithDescriptor:descriptor
        disposition:DispositionForKind([descriptor kind])
        denialReason:CydiaUIRouteDenialReasonNone
        requiresConfirmation:([descriptor kind] == CydiaUIRouteKindSourceAdd &&
                              [context caller] == CydiaUIRouteCallerExternalURL)];
}
