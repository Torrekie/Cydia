/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_SourceVerificationRequestPolicy_H
#define Cydia_SourceVerificationRequestPolicy_H

#import <Foundation/Foundation.h>

/* Apply identity headers to an initial repository verification request.  The
 * returned request is an independent copy; controlled headers already present
 * on the input are removed before trusted values are applied. */
FOUNDATION_EXPORT NSURLRequest *CydiaSourceVerificationInitialRequest(
    NSURLRequest *request,
    NSString *machine,
    NSString *uniqueIdentifier);

/* Redirects deliberately lose all source-verification identity, including
 * redirects which remain on the same origin.  A later redirect must not regain
 * headers merely because its destination would have qualified initially. */
FOUNDATION_EXPORT NSURLRequest *CydiaSourceVerificationRedirectRequest(
    NSURLRequest *request);

/* NSURLConnection may invoke its redirect delegate for the initial request
 * with a nil redirect response.  This per-connection tracker preserves only
 * that first, exact-URL callback and treats every other proposal as a redirect
 * which must lose identity. */
@interface CydiaSourceVerificationRedirectTracker : NSObject {
@private
    NSURL *_initialURL;
    BOOL _handledCallback;
}

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

- (instancetype) initWithInitialURL:(NSURL *)initialURL
    NS_DESIGNATED_INITIALIZER;
- (NSURLRequest *) requestForProposedRequest:(NSURLRequest *)request
                           redirectResponse:(NSURLResponse *)response;

@end

#endif // Cydia_SourceVerificationRequestPolicy_H
