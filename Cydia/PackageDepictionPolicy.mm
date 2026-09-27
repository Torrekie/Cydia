/* Cydia Refurbished package depiction navigation boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageDepictionPolicy.h"
#include "Cydia/ExternalURLPolicy.h"

namespace {

BOOL HasCredentials(NSURL *URL) {
    return [[URL user] length] != 0 || [[URL password] length] != 0;
}

BOOL IsWebDocumentURL(NSURL *URL) {
    return CydiaExternalURLIsValidWebURL(URL);
}

NSInteger EffectivePort(NSURL *URL) {
    NSNumber *port([URL port]);
    if (port != nil)
        return [port integerValue];
    return [[[URL scheme] lowercaseString] isEqualToString:@"https"] ? 443 : 80;
}

BOOL SameOrigin(NSURL *first, NSURL *second) {
    if (!IsWebDocumentURL(first) || !IsWebDocumentURL(second))
        return NO;
    return [[[first scheme] lowercaseString] isEqualToString:[[second scheme] lowercaseString]] &&
        [[[first host] lowercaseString] isEqualToString:[[second host] lowercaseString]] &&
        EffectivePort(first) == EffectivePort(second);
}

BOOL SameInitialResource(NSURL *first, NSURL *second) {
    if (!SameOrigin(first, second))
        return NO;
    NSURLComponents *firstComponents([NSURLComponents
        componentsWithURL:first resolvingAgainstBaseURL:NO]);
    NSURLComponents *secondComponents([NSURLComponents
        componentsWithURL:second resolvingAgainstBaseURL:NO]);
    NSString *firstPath([firstComponents percentEncodedPath]);
    NSString *secondPath([secondComponents percentEncodedPath]);
    if ([firstPath length] == 0)
        firstPath = @"/";
    if ([secondPath length] == 0)
        secondPath = @"/";
    return [firstPath isEqualToString:secondPath] &&
        (([firstComponents percentEncodedQuery] == nil &&
          [secondComponents percentEncodedQuery] == nil) ||
         [[firstComponents percentEncodedQuery]
             isEqualToString:[secondComponents percentEncodedQuery]]);
}

BOOL IsHandoffURL(NSURL *URL) {
    if (![URL isKindOfClass:[NSURL class]] || [[URL absoluteString] length] == 0 ||
        [URL baseURL] != nil || HasCredentials(URL))
        return NO;
    if (IsWebDocumentURL(URL))
        return YES;

    NSString *scheme([[URL scheme] lowercaseString]);
    if ([scheme isEqualToString:@"cydia"] || [scheme isEqualToString:@"apptapp"])
        return YES;
    return [[CydiaExternalURLPolicy alloc] initWithURL:URL] != nil;
}

} // namespace


@implementation CydiaPackageDepictionPolicy

- (instancetype)initWithURLString:(NSString *)URLString {
    if (![URLString isKindOfClass:[NSString class]] || [URLString length] == 0)
        return nil;
    NSURL *URL([NSURL URLWithString:URLString]);
    if (!IsWebDocumentURL(URL))
        return nil;
    if ((self = [super init]) != nil)
        _initialURL = [URL copy];
    return self;
}

- (CydiaPackageDepictionNavigationDisposition)decisionForURL:(NSURL *)URL
                                                   mainFrame:(BOOL)mainFrame
                                              initialRequest:(BOOL)initialRequest
                                                      intent:(CydiaPackageDepictionNavigationIntent)intent {
    if (initialRequest) {
        return mainFrame && intent == CydiaPackageDepictionNavigationIntentAutomatic &&
            SameInitialResource(_initialURL, URL) ?
            CydiaPackageDepictionNavigationDispositionLoadInIsland :
            CydiaPackageDepictionNavigationDispositionReject;
    }

    if (intent == CydiaPackageDepictionNavigationIntentUserActivated) {
        return IsHandoffURL(URL) ? CydiaPackageDepictionNavigationDispositionHandOff :
                                  CydiaPackageDepictionNavigationDispositionReject;
    }

    if (!IsWebDocumentURL(URL))
        return CydiaPackageDepictionNavigationDispositionReject;
    if (!mainFrame || SameOrigin(_initialURL, URL))
        return CydiaPackageDepictionNavigationDispositionLoadInIsland;
    return CydiaPackageDepictionNavigationDispositionReject;
}

- (BOOL)allowsResponseURL:(NSURL *)URL mainFrame:(BOOL)mainFrame {
    if (!IsWebDocumentURL(URL))
        return NO;
    return !mainFrame || SameOrigin(_initialURL, URL);
}

@end
