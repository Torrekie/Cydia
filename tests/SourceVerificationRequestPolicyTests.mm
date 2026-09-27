/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/SourceVerificationRequestPolicy.h"

#include <cstdlib>
#include <iostream>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    std::cerr << "[verify-source-request-policy][FAIL] "
              << [message UTF8String] << std::endl;
    std::exit(1);
}

NSMutableURLRequest *Request(NSString *url) {
    NSMutableURLRequest *request([NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:17]);
    [request setHTTPMethod:@"HEAD"];
    [request setValue:@"preserved" forHTTPHeaderField:@"X-Test"];
    return request;
}

NSString *Header(NSURLRequest *request, NSString *name) {
    return [request valueForHTTPHeaderField:name];
}

void ExpectInitialIdentity(NSString *url, BOOL cydiaIdentity) {
    NSMutableURLRequest *input(Request(url));
    NSURLRequest *output(CydiaSourceVerificationInitialRequest(
        input, @"iPhone15,2", @"device-id"));

    Expect([Header(output, @"X-Machine") isEqualToString:@"iPhone15,2"],
        [NSString stringWithFormat:@"machine identity is present for %@", url]);
    Expect([Header(output, @"X-Unique-ID") isEqualToString:@"device-id"],
        [NSString stringWithFormat:@"unique identity is present for %@", url]);
    Expect((Header(output, @"X-Cydia-Id") != nil) == cydiaIdentity,
        [NSString stringWithFormat:@"Cydia identity policy matches %@", url]);
    Expect([Header(output, @"X-Test") isEqualToString:@"preserved"],
        @"non-identity headers survive initial policy");
    Expect([[output HTTPMethod] isEqualToString:@"HEAD"] &&
           [output cachePolicy] == NSURLRequestReloadIgnoringLocalCacheData &&
           [output timeoutInterval] == 17,
        @"initial policy preserves request behavior");
    Expect(output != input, @"initial policy returns an independent request");
}

void VerifyInitialNetworkPolicy(void) {
    ExpectInitialIdentity(@"https://repo.example/Packages.xz", YES);
    ExpectInitialIdentity(@"https://repo.example:443/Packages.xz", YES);
    ExpectInitialIdentity(@"HTTPS://repo.example/Packages.xz?probe=1", YES);
    ExpectInitialIdentity(@"https://repo.example:8443/Packages.xz", NO);
    ExpectInitialIdentity(@"http://repo.example/Packages.xz", NO);

    ExpectInitialIdentity(@"https://user@repo.example/Packages.xz", NO);
    ExpectInitialIdentity(@"https://user:password@repo.example/Packages.xz", NO);
    ExpectInitialIdentity(@"https://@repo.example/Packages.xz", NO);

    /* file:/// remains a supported VerifySource input.  The headers are not
     * transmitted by the file protocol, but retaining them preserves the
     * native pre-policy request semantics. */
    ExpectInitialIdentity(@"file:///var/mobile/repo/Packages.xz", NO);
}

void VerifyInvalidURLsFailClosed(void) {
    NSArray *invalidURLs(@[
        @"ftp://repo.example/Packages.xz",
        @"cydia://sources",
        @"https:///missing-host",
        @"relative/Packages.xz",
    ]);

    for (NSString *url in invalidURLs) {
        NSMutableURLRequest *input(Request(url));
        [input setValue:@"spoofed-machine" forHTTPHeaderField:@"x-machine"];
        [input setValue:@"spoofed-unique" forHTTPHeaderField:@"X-UNIQUE-ID"];
        [input setValue:@"spoofed-cydia" forHTTPHeaderField:@"x-CyDiA-iD"];
        NSURLRequest *output(CydiaSourceVerificationInitialRequest(
            input, @"iPhone15,2", @"device-id"));
        Expect(Header(output, @"X-Machine") == nil &&
               Header(output, @"X-Unique-ID") == nil &&
               Header(output, @"X-Cydia-Id") == nil,
            [NSString stringWithFormat:@"invalid URL has no identity: %@", url]);
        Expect([Header(output, @"X-Test") isEqualToString:@"preserved"],
            @"invalid URL retains unrelated headers");
    }

    Expect(CydiaSourceVerificationInitialRequest(nil, @"machine", @"id") == nil,
        @"nil initial request remains nil");
}

void VerifyControlledValuesReplaceSpoofedHeaders(void) {
    NSMutableURLRequest *input(Request(@"https://repo.example/Packages.xz"));
    [input setValue:@"spoofed-machine" forHTTPHeaderField:@"x-machine"];
    [input setValue:@"spoofed-unique" forHTTPHeaderField:@"X-UNIQUE-id"];
    [input setValue:@"spoofed-cydia" forHTTPHeaderField:@"x-cydia-ID"];

    NSURLRequest *output(CydiaSourceVerificationInitialRequest(
        input, @"trusted-machine", @"trusted-id"));
    Expect([Header(output, @"X-Machine") isEqualToString:@"trusted-machine"] &&
           [Header(output, @"X-Unique-ID") isEqualToString:@"trusted-id"] &&
           [Header(output, @"X-Cydia-Id") isEqualToString:@"trusted-id"],
        @"controlled initial values replace spoofed header casing");
    Expect([Header(input, @"X-Machine") isEqualToString:@"spoofed-machine"],
        @"input request is not mutated");

    NSURLRequest *missing(CydiaSourceVerificationInitialRequest(input, nil, nil));
    Expect(Header(missing, @"X-Machine") == nil &&
           Header(missing, @"X-Unique-ID") == nil &&
           Header(missing, @"X-Cydia-Id") == nil,
        @"missing trusted values remove spoofed identity");

    NSURLRequest *uniqueOnly(CydiaSourceVerificationInitialRequest(
        Request(@"https://repo.example/Packages.xz"), nil, @"trusted-id"));
    Expect(Header(uniqueOnly, @"X-Machine") == nil &&
           [Header(uniqueOnly, @"X-Unique-ID") isEqualToString:@"trusted-id"] &&
           [Header(uniqueOnly, @"X-Cydia-Id") isEqualToString:@"trusted-id"],
        @"Cydia identity follows the trusted unique identifier");
}

void VerifyRedirectsAlwaysLoseIdentity(void) {
    NSArray *redirectDestinations(@[
        @"https://repo.example/Packages.xz",
        @"https://mirror.example/Packages.xz",
        @"http://repo.example/Packages.xz",
        @"https://repo.example:443/Packages.xz",
    ]);

    for (NSString *url in redirectDestinations) {
        NSMutableURLRequest *redirect(Request(url));
        [redirect setValue:@"machine" forHTTPHeaderField:@"X-Machine"];
        [redirect setValue:@"unique" forHTTPHeaderField:@"X-Unique-ID"];
        [redirect setValue:@"cydia" forHTTPHeaderField:@"X-Cydia-Id"];

        NSURLRequest *sanitized(CydiaSourceVerificationRedirectRequest(redirect));
        Expect(Header(sanitized, @"X-Machine") == nil &&
               Header(sanitized, @"X-Unique-ID") == nil &&
               Header(sanitized, @"X-Cydia-Id") == nil,
            [NSString stringWithFormat:@"redirect identity is stripped for %@", url]);
        Expect([Header(sanitized, @"X-Test") isEqualToString:@"preserved"],
            @"redirect keeps unrelated headers");

        NSURLRequest *next(CydiaSourceVerificationRedirectRequest(sanitized));
        Expect(Header(next, @"X-Machine") == nil &&
               Header(next, @"X-Unique-ID") == nil &&
               Header(next, @"X-Cydia-Id") == nil,
            @"a later redirect never regains identity");
    }

    Expect(CydiaSourceVerificationRedirectRequest(nil) == nil,
        @"nil redirect request remains nil");
}

void ExpectNoIdentity(NSURLRequest *request, NSString *message) {
    Expect(Header(request, @"X-Machine") == nil &&
           Header(request, @"X-Unique-ID") == nil &&
           Header(request, @"X-Cydia-Id") == nil,
        message);
}

NSURLRequest *IdentifiedRequest(NSString *url) {
    return CydiaSourceVerificationInitialRequest(
        Request(url), @"iPhone15,2", @"device-id");
}

NSURLResponse *RedirectResponse(NSString *url) {
    return [[NSURLResponse alloc]
        initWithURL:[NSURL URLWithString:url]
        MIMEType:nil
        expectedContentLength:0
        textEncodingName:nil];
}

void VerifyRedirectTrackerCallbackSemantics(void) {
    NSString *initialURL(@"https://repo.example/Packages.xz");
    NSURLRequest *initial(IdentifiedRequest(initialURL));
    CydiaSourceVerificationRedirectTracker *tracker(
        [[CydiaSourceVerificationRedirectTracker alloc]
            initWithInitialURL:[initial URL]]);

    NSURLRequest *preserved([tracker requestForProposedRequest:initial
                                             redirectResponse:nil]);
    Expect(preserved == initial && Header(preserved, @"X-Cydia-Id") != nil,
        @"first matching nil-response callback preserves initial identity once");

    NSURLRequest *second([tracker requestForProposedRequest:initial
                                          redirectResponse:nil]);
    ExpectNoIdentity(second,
        @"second matching nil-response callback is sanitized");

    NSURLRequest *changed(IdentifiedRequest(
        @"https://mirror.example/Packages.xz"));
    CydiaSourceVerificationRedirectTracker *changedTracker(
        [[CydiaSourceVerificationRedirectTracker alloc]
            initWithInitialURL:[initial URL]]);
    NSURLRequest *changedResult([changedTracker
        requestForProposedRequest:changed redirectResponse:nil]);
    ExpectNoIdentity(changedResult,
        @"nil-response URL change is treated as a redirect");
    NSURLRequest *changedThenInitial([changedTracker
        requestForProposedRequest:initial redirectResponse:nil]);
    ExpectNoIdentity(changedThenInitial,
        @"a rejected first callback cannot later restore initial identity");

    CydiaSourceVerificationRedirectTracker *normalTracker(
        [[CydiaSourceVerificationRedirectTracker alloc]
            initWithInitialURL:[initial URL]]);
    NSURLRequest *normal([normalTracker requestForProposedRequest:initial
        redirectResponse:RedirectResponse(initialURL)]);
    ExpectNoIdentity(normal,
        @"non-nil redirect response sanitizes even an unchanged URL");
}

void VerifyControllerTrackingContract(NSString *sourcePath) {
    NSError *error(nil);
    NSString *source([NSString stringWithContentsOfFile:sourcePath
        encoding:NSUTF8StringEncoding error:&error]);
    Expect(source != nil,
        [NSString stringWithFormat:@"controller source is readable: %@", error]);

    NSRange deferred([source rangeOfString:@"startImmediately:NO"]);
    NSRange tracked([source rangeOfString:
        @"[source_verification_trackers_ setObject:tracker forKey:connection]"]);
    NSRange assigned([source rangeOfString:
        @"trivial_bz2_ = [self _requestHRef"]);
    NSRange started([source rangeOfString:@"[trivial_bz2_ start]"]);
    Expect(deferred.location != NSNotFound &&
           tracked.location != NSNotFound &&
           assigned.location != NSNotFound &&
           started.location != NSNotFound &&
           deferred.location < tracked.location &&
           tracked.location < assigned.location &&
           assigned.location < started.location,
        @"controller records, assigns, then starts each deferred connection");
    Expect([source rangeOfString:@"[trivial_gz_ start]"].location != NSNotFound &&
           [source rangeOfString:@"[trivial_xz_ start]"].location != NSNotFound,
        @"controller starts every tracked source verification request");

    Expect([source rangeOfString:
               @"[source_verification_trackers_ objectForKey:connection]"].location !=
               NSNotFound &&
           [source rangeOfString:
               @"requestForProposedRequest:request redirectResponse:response"].location !=
               NSNotFound,
        @"redirect delegate resolves and applies the per-connection tracker");
    Expect([source rangeOfString:
               @"[source_verification_trackers_ removeObjectForKey:connection]"].location !=
               NSNotFound &&
           [source rangeOfString:
               @"[source_verification_trackers_ removeAllObjects]"].location !=
               NSNotFound,
        @"completion and deallocation discard connection tracking state");
}

} // namespace

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Expect(argc == 2, @"controller source path argument is required");
        VerifyInitialNetworkPolicy();
        VerifyInvalidURLsFailClosed();
        VerifyControlledValuesReplaceSpoofedHeaders();
        VerifyRedirectsAlwaysLoseIdentity();
        VerifyRedirectTrackerCallbackSemantics();
        VerifyControllerTrackingContract([NSString stringWithUTF8String:argv[1]]);
    }
    std::cout << "[verify-source-request-policy][ ok ] initial identity and redirect containment" << std::endl;
    return 0;
}
