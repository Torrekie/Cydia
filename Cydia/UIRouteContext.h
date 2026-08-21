/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_UIRouteContext_H
#define Cydia_UIRouteContext_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, CydiaUIRouteCaller) {
    CydiaUIRouteCallerTrustedNative,
    CydiaUIRouteCallerExternalURL,
    CydiaUIRouteCallerTrustedLegacyPage,
    CydiaUIRouteCallerRepositoryDepiction,
};

typedef NS_ENUM(NSUInteger, CydiaUIRouteKind) {
    CydiaUIRouteKindHome,
    CydiaUIRouteKindSources,
    CydiaUIRouteKindSourceAdd,
    CydiaUIRouteKindSource,
    CydiaUIRouteKindSections,
    CydiaUIRouteKindSection,
    CydiaUIRouteKindSearch,
    CydiaUIRouteKindChanges,
    CydiaUIRouteKindInstalled,
    CydiaUIRouteKindPackage,
    CydiaUIRouteKindPackageSettings,
    CydiaUIRouteKindPackageFiles,
    CydiaUIRouteKindLaunchApplication,
    CydiaUIRouteKindExternalOpen,
};

typedef NS_ENUM(NSUInteger, CydiaUIRouteDisposition) {
    CydiaUIRouteDispositionRejected,
    CydiaUIRouteDispositionNativeController,
    CydiaUIRouteDispositionNativeCommand,
    CydiaUIRouteDispositionExternalOpen,
};

typedef NS_ENUM(NSUInteger, CydiaUIRouteDenialReason) {
    CydiaUIRouteDenialReasonNone,
    CydiaUIRouteDenialReasonMalformed,
    CydiaUIRouteDenialReasonCaller,
    CydiaUIRouteDenialReasonScheme,
    CydiaUIRouteDenialReasonUserGesture,
};

FOUNDATION_EXPORT NSString * const CydiaUIRouteErrorDomain;

@interface CydiaUIRouteContext : NSObject <NSCopying>

@property (nonatomic, readonly) CydiaUIRouteCaller caller;
@property (nonatomic, readonly, copy) NSURL *initiatingOrigin;
@property (nonatomic, readonly, copy) NSString *depictionPackageIdentity;
@property (nonatomic, readonly, getter=isMainFrame) BOOL mainFrame;
@property (nonatomic, readonly, getter=hasUserGesture) BOOL userGesture;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

+ (instancetype) trustedNativeContext;
+ (instancetype) externalURLContext;
/* Returns nil unless origin is a reviewed bundled page or the fixed
   first-party HTTPS compatibility origin. */
+ (instancetype) trustedLegacyPageContextWithOrigin:(NSURL *)origin
                                           mainFrame:(BOOL)mainFrame
                                         userGesture:(BOOL)userGesture;
/* Returns nil for non-HTTP(S), credential-bearing, or malformed identities. */
+ (instancetype) repositoryDepictionContextWithOrigin:(NSURL *)origin
                                       packageIdentity:(NSString *)packageIdentity
                                             mainFrame:(BOOL)mainFrame
                                           userGesture:(BOOL)userGesture;

/* Redirects, subframes, and popups retain the initiating authority. */
- (instancetype) contextForRedirectWithOrigin:(NSURL *)origin
                                    mainFrame:(BOOL)mainFrame
                                  userGesture:(BOOL)userGesture;

@end

@interface CydiaUIRouteDescriptor : NSObject

@property (nonatomic, readonly) CydiaUIRouteKind kind;
@property (nonatomic, readonly, copy) NSURL *originalURL;
@property (nonatomic, readonly, copy) NSArray *arguments;
@property (nonatomic, readonly, copy) NSURL *externalURL;

@end


@interface CydiaUIRouteDecision : NSObject

@property (nonatomic, readonly, strong) CydiaUIRouteDescriptor *descriptor;
@property (nonatomic, readonly) CydiaUIRouteDisposition disposition;
@property (nonatomic, readonly) CydiaUIRouteDenialReason denialReason;
@property (nonatomic, readonly, getter=isAllowed) BOOL allowed;
@property (nonatomic, readonly) BOOL requiresConfirmation;

@end


FOUNDATION_EXPORT CydiaUIRouteDescriptor *CydiaUIParseRouteURL(NSURL *url,
                                                               NSError **error);
FOUNDATION_EXPORT CydiaUIRouteDecision *CydiaUIEvaluateRoute(CydiaUIRouteDescriptor *descriptor,
                                                             CydiaUIRouteContext *context);

#endif // Cydia_UIRouteContext_H
