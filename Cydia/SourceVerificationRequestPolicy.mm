/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/SourceVerificationRequestPolicy.h"

namespace {

NSArray *IdentityHeaderNames(void) {
    return @[ @"X-Machine", @"X-Unique-ID", @"X-Cydia-Id" ];
}

NSMutableURLRequest *RequestByRemovingIdentityHeaders(NSURLRequest *request) {
    if (request == nil)
        return nil;

    NSMutableURLRequest *copy([request mutableCopy]);
    NSArray *protectedNames(IdentityHeaderNames());
    for (NSString *field in [[copy allHTTPHeaderFields] allKeys]) {
        for (NSString *protectedName in protectedNames) {
            if ([field caseInsensitiveCompare:protectedName] == NSOrderedSame) {
                [copy setValue:nil forHTTPHeaderField:field];
                break;
            }
        }
    }

    /* Foundation normally treats header names case-insensitively.  Removing
     * the canonical spellings as well keeps this fail-closed for alternate
     * NSURLRequest implementations. */
    for (NSString *field in protectedNames)
        [copy setValue:nil forHTTPHeaderField:field];
    return copy;
}

BOOL IsValidRepositoryURL(NSURL *url) {
    if (url == nil)
        return NO;

    NSURLComponents *components([NSURLComponents
        componentsWithURL:url resolvingAgainstBaseURL:YES]);
    NSString *scheme([[components scheme] lowercaseString]);
    if ([scheme isEqualToString:@"file"])
        return [url isFileURL] && [[[components URL] path] length] != 0;
    if (![scheme isEqualToString:@"http"] &&
        ![scheme isEqualToString:@"https"])
        return NO;
    return [[components host] length] != 0;
}

BOOL AllowsCydiaIdentity(NSURL *url) {
    if (!IsValidRepositoryURL(url))
        return NO;

    NSURLComponents *components([NSURLComponents
        componentsWithURL:url resolvingAgainstBaseURL:YES]);
    if (![[[components scheme] lowercaseString] isEqualToString:@"https"])
        return NO;
    if ([components percentEncodedUser] != nil ||
        [components percentEncodedPassword] != nil)
        return NO;

    NSNumber *port([components port]);
    return port == nil || [port unsignedIntegerValue] == 443;
}

} // namespace

NSURLRequest *CydiaSourceVerificationInitialRequest(
    NSURLRequest *request,
    NSString *machine,
    NSString *uniqueIdentifier) {
    NSMutableURLRequest *copy(RequestByRemovingIdentityHeaders(request));
    if (!IsValidRepositoryURL([copy URL]))
        return copy;

    if (machine != nil)
        [copy setValue:machine forHTTPHeaderField:@"X-Machine"];
    if (uniqueIdentifier != nil) {
        [copy setValue:uniqueIdentifier forHTTPHeaderField:@"X-Unique-ID"];
        if (AllowsCydiaIdentity([copy URL]))
            [copy setValue:uniqueIdentifier forHTTPHeaderField:@"X-Cydia-Id"];
    }
    return copy;
}

NSURLRequest *CydiaSourceVerificationRedirectRequest(NSURLRequest *request) {
    return RequestByRemovingIdentityHeaders(request);
}

@implementation CydiaSourceVerificationRedirectTracker

- (instancetype) initWithInitialURL:(NSURL *)initialURL {
    if ((self = [super init]) != nil)
        _initialURL = [initialURL copy];
    return self;
}

- (NSURLRequest *) requestForProposedRequest:(NSURLRequest *)request
                           redirectResponse:(NSURLResponse *)response {
    BOOL preserveInitial(!_handledCallback && response == nil &&
        [_initialURL isEqual:[request URL]]);
    _handledCallback = YES;
    if (preserveInitial)
        return request;
    return CydiaSourceVerificationRedirectRequest(request);
}

@end
