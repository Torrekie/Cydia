/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/UIRouteContext.h"

#include <cstdlib>
#include <iostream>

namespace {

void Expect(BOOL condition, const char *message) {
    if (condition)
        return;
    std::cerr << "[verify-ui-routes][FAIL] " << message << std::endl;
    std::exit(1);
}

CydiaUIRouteDescriptor *Parse(NSString *value) {
    NSError *error(nil);
    CydiaUIRouteDescriptor *descriptor(CydiaUIParseRouteURL([NSURL URLWithString:value], &error));
    Expect(descriptor != nil && error == nil, [[NSString stringWithFormat:@"parse %@", value] UTF8String]);
    return descriptor;
}

void ExpectRejected(NSString *value) {
    NSError *error(nil);
    Expect(CydiaUIParseRouteURL([NSURL URLWithString:value], &error) == nil && error != nil,
           [[NSString stringWithFormat:@"reject %@", value] UTF8String]);
}

CydiaUIRouteKind KindForName(NSString *name) {
    NSDictionary *kinds(@{
        @"home": @(CydiaUIRouteKindHome),
        @"sources": @(CydiaUIRouteKindSources),
        @"source-add": @(CydiaUIRouteKindSourceAdd),
        @"source": @(CydiaUIRouteKindSource),
        @"sections": @(CydiaUIRouteKindSections),
        @"section": @(CydiaUIRouteKindSection),
        @"search": @(CydiaUIRouteKindSearch),
        @"changes": @(CydiaUIRouteKindChanges),
        @"installed": @(CydiaUIRouteKindInstalled),
        @"package": @(CydiaUIRouteKindPackage),
        @"package-settings": @(CydiaUIRouteKindPackageSettings),
        @"package-files": @(CydiaUIRouteKindPackageFiles),
        @"launch": @(CydiaUIRouteKindLaunchApplication),
        @"external-open": @(CydiaUIRouteKindExternalOpen),
    });
    NSNumber *kind([kinds objectForKey:name]);
    Expect(kind != nil, [[NSString stringWithFormat:@"unknown fixture kind %@", name] UTF8String]);
    return (CydiaUIRouteKind) [kind unsignedIntegerValue];
}

void CheckExpected(NSString *route, NSString *expected,
                   CydiaUIRouteContext *context,
                   CydiaUIRouteContext *noGestureContext) {
    CydiaUIRouteDecision *decision(CydiaUIEvaluateRoute(Parse(route), context));
    if ([expected isEqualToString:@"deny"])
        Expect(![decision isAllowed], [[NSString stringWithFormat:@"deny %@", route] UTF8String]);
    else if ([expected isEqualToString:@"allow"] ||
             [expected isEqualToString:@"temporary"])
        Expect([decision isAllowed] && ![decision requiresConfirmation],
               [[NSString stringWithFormat:@"allow %@", route] UTF8String]);
    else if ([expected isEqualToString:@"confirm"])
        Expect([decision isAllowed] && [decision requiresConfirmation],
               [[NSString stringWithFormat:@"confirm %@", route] UTF8String]);
    else if ([expected isEqualToString:@"gesture"]) {
        Expect([decision isAllowed], [[NSString stringWithFormat:@"gesture allows %@", route] UTF8String]);
        CydiaUIRouteDecision *automatic(CydiaUIEvaluateRoute(Parse(route), noGestureContext));
        Expect(![automatic isAllowed] &&
               [automatic denialReason] == CydiaUIRouteDenialReasonUserGesture,
               [[NSString stringWithFormat:@"automatic navigation denies %@", route] UTF8String]);
    } else
        Expect(NO, [[NSString stringWithFormat:@"unknown fixture policy %@", expected] UTF8String]);
}

void VerifyRouteFixture(NSString *path,
                        CydiaUIRouteContext *native,
                        CydiaUIRouteContext *external,
                        CydiaUIRouteContext *legacy,
                        CydiaUIRouteContext *depiction,
                        CydiaUIRouteContext *depictionWithoutGesture) {
    NSError *error(nil);
    NSString *fixture([NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:&error]);
    Expect(fixture != nil && error == nil, "load route fixture");

    NSMutableSet *seenRoutes([NSMutableSet set]);
    NSMutableSet *seenKinds([NSMutableSet set]);
    NSArray *lines([fixture componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]]);
    for (NSString *line in lines) {
        if ([line length] == 0 || [line hasPrefix:@"#"])
            continue;
        NSArray *fields([line componentsSeparatedByString:@"\t"]);
        Expect([fields count] == 6, "route fixture has six columns");
        NSString *route([fields objectAtIndex:0]);
        NSString *kindName([fields objectAtIndex:1]);
        Expect(![seenRoutes containsObject:route], "route fixture has no duplicate routes");
        [seenRoutes addObject:route];
        [seenKinds addObject:kindName];

        CydiaUIRouteDescriptor *descriptor(Parse(route));
        Expect([descriptor kind] == KindForName(kindName),
               [[NSString stringWithFormat:@"fixture kind %@", route] UTF8String]);
        CheckExpected(route, [fields objectAtIndex:2], native, nil);
        CheckExpected(route, [fields objectAtIndex:3], external, nil);
        CheckExpected(route, [fields objectAtIndex:4], legacy, nil);
        CheckExpected(route, [fields objectAtIndex:5], depiction,
                      depictionWithoutGesture);
    }

    Expect([seenKinds count] == 14, "route fixture covers every route kind");
}

} // namespace

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Expect(argc == 2, "route fixture path is required");
        CydiaUIRouteContext *native([CydiaUIRouteContext trustedNativeContext]);
        CydiaUIRouteContext *external([CydiaUIRouteContext externalURLContext]);
        CydiaUIRouteContext *legacy([CydiaUIRouteContext
            trustedLegacyPageContextWithOrigin:[NSURL URLWithString:@"https://cydia.saurik.com/ui/"]
            mainFrame:YES userGesture:YES]);
        CydiaUIRouteContext *depiction([CydiaUIRouteContext
            repositoryDepictionContextWithOrigin:[NSURL URLWithString:@"https://repo.example/depiction"]
            packageIdentity:@"example:iphoneos-arm64" mainFrame:YES userGesture:YES]);
        CydiaUIRouteContext *depictionWithoutGesture([CydiaUIRouteContext
            repositoryDepictionContextWithOrigin:[NSURL URLWithString:@"https://repo.example/depiction"]
            packageIdentity:@"example:iphoneos-arm64" mainFrame:YES userGesture:NO]);
        Expect(legacy != nil && depiction != nil, "validated route contexts");
        Expect([CydiaUIRouteContext
            trustedLegacyPageContextWithOrigin:[NSURL URLWithString:@"https://repo.example/page"]
            mainFrame:YES userGesture:YES] == nil,
            "repository host cannot mint trusted legacy authority");
        Expect([CydiaUIRouteContext
            repositoryDepictionContextWithOrigin:[NSURL fileURLWithPath:@"/etc/passwd"]
            packageIdentity:@"example" mainFrame:YES userGesture:YES] == nil,
            "local file cannot mint depiction authority");

        VerifyRouteFixture([NSString stringWithUTF8String:argv[1]], native,
            external, legacy, depiction, depictionWithoutGesture);
        Expect(CydiaUIEvaluateRoute(Parse(@"cydia://home"), nil).allowed == NO,
               "nil caller context fails closed");

        CydiaUIRouteContext *redirect([depiction
            contextForRedirectWithOrigin:[NSURL URLWithString:@"https://other.example/"]
            mainFrame:NO userGesture:NO]);
        Expect([redirect caller] == CydiaUIRouteCallerRepositoryDepiction,
               "redirect retains caller authority");
        Expect([[redirect initiatingOrigin] isEqual:[depiction initiatingOrigin]],
               "redirect retains initiating origin");
        Expect(![redirect hasUserGesture], "redirect cannot create a user gesture");
        CydiaUIRouteDecision *automatic(CydiaUIEvaluateRoute(
            Parse(@"cydia://url/https://example.com/automatic"), redirect));
        Expect(![automatic isAllowed] &&
               [automatic denialReason] == CydiaUIRouteDenialReasonUserGesture,
               "automatic depiction navigation denied");

        CydiaUIRouteDescriptor *rawExternal(Parse(@"cydia://url/https://example.com/a%20b"));
        Expect([[[rawExternal externalURL] absoluteString] isEqualToString:@"https://example.com/a%20b"],
               "raw escaped external URL is preserved");
        Expect([Parse(@"cydia://package/example:iphoneos-arm64").arguments.firstObject
                    isEqualToString:@"example:iphoneos-arm64"],
               "qualified package identity preserved");
        Expect([Parse(@"cydia://sources/deb%3Ahttps%3A%2F%2Frepo.example%2F%3A.%2F").arguments.firstObject
                    isEqualToString:@"deb:https://repo.example/:./"],
               "opaque source key preserves encoded separators");
        Expect([Parse(@"cydia://sections/deb%3Ahttps%3A%2F%2Frepo.example%2F%3A.%2F/Utilities").arguments.firstObject
                    isEqualToString:@"deb:https://repo.example/:./"],
               "saved source section preserves encoded separators");

        ExpectRejected(@"apptapp://package");
        ExpectRejected(@"apptapp://package/");
        ExpectRejected(@"cydia://package");
        ExpectRejected(@"cydia://package/example/unknown");
        ExpectRejected(@"cydia://package/example%2Ftraversal");
        ExpectRejected(@"cydia://sections/..");
        ExpectRejected(@"cydia://url/");
        ExpectRejected(@"https://example.com/");

        NSArray *unsafe(@[
            @"cydia://url/file:///etc/passwd",
            @"cydia://url/javascript:alert(1)",
            @"cydia://url/data:text/plain,test",
            @"cydia://url/https://user:password@example.com/",
            @"cydia://url/custom://device-command",
        ]);
        for (NSString *route in unsafe) {
            CydiaUIRouteDecision *decision(CydiaUIEvaluateRoute(Parse(route), native));
            Expect(![decision isAllowed] &&
                   [decision denialReason] == CydiaUIRouteDenialReasonScheme,
                   [[NSString stringWithFormat:@"unsafe route %@", route] UTF8String]);
        }

        CydiaUIRouteDecision *sourcePrompt(CydiaUIEvaluateRoute(Parse(@"cydia://sources/add"), external));
        Expect([sourcePrompt isAllowed] && [sourcePrompt requiresConfirmation],
               "external source add requires confirmation");
    }

    std::cout << "[verify-ui-routes][ ok ] caller authority and route parsing" << std::endl;
    return 0;
}
