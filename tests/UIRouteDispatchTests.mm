/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/UIRouteDispatch.h"

#include <cstdlib>
#include <iostream>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    std::cerr << "[verify-ui-route-dispatch][FAIL] " << [message UTF8String] << std::endl;
    std::exit(1);
}

CydiaUIRouteContext *ContextForName(NSString *name) {
    if ([name isEqualToString:@"trusted-native"])
        return [CydiaUIRouteContext trustedNativeContext];
    if ([name isEqualToString:@"external-url"])
        return [CydiaUIRouteContext externalURLContext];
    if ([name isEqualToString:@"trusted-legacy"])
        return [CydiaUIRouteContext
            trustedLegacyPageContextWithOrigin:[NSURL URLWithString:@"https://cydia.saurik.com/ui/"]
            mainFrame:YES userGesture:YES];
    if ([name isEqualToString:@"repository-depiction"])
        return [CydiaUIRouteContext
            repositoryDepictionContextWithOrigin:[NSURL URLWithString:@"https://repo.example/depiction"]
            packageIdentity:@"example:iphoneos-arm64" mainFrame:YES userGesture:YES];
    if ([name isEqualToString:@"untrusted-web"])
        return [CydiaUIRouteContext
            untrustedWebPageContextWithOrigin:[NSURL URLWithString:@"https://untrusted.example/page"]
            mainFrame:YES userGesture:NO];
    Expect(NO, [NSString stringWithFormat:@"unknown caller %@", name]);
    return nil;
}

NSString *KindName(CydiaUIRouteDescriptor *descriptor) {
    if (descriptor == nil)
        return @"-";
    switch ([descriptor kind]) {
        case CydiaUIRouteKindHome: return @"home";
        case CydiaUIRouteKindFAQ: return @"faq";
        case CydiaUIRouteKindUpgradingGuide: return @"upgrading-guide";
        case CydiaUIRouteKindApplicationExtensions: return @"application-extensions";
        case CydiaUIRouteKindMoreSources: return @"more-sources";
        case CydiaUIRouteKindCopyingFiles: return @"copying-files";
        case CydiaUIRouteKindHomeGuide: return @"home-guide";
        case CydiaUIRouteKindSources: return @"sources";
        case CydiaUIRouteKindSourceAdd: return @"source-add";
        case CydiaUIRouteKindSource: return @"source";
        case CydiaUIRouteKindSections: return @"sections";
        case CydiaUIRouteKindSection: return @"section";
        case CydiaUIRouteKindSearch: return @"search";
        case CydiaUIRouteKindChanges: return @"changes";
        case CydiaUIRouteKindInstalled: return @"installed";
        case CydiaUIRouteKindPackage: return @"package";
        case CydiaUIRouteKindPackageSettings: return @"package-settings";
        case CydiaUIRouteKindPackageFiles: return @"package-files";
        case CydiaUIRouteKindPackageSupport: return @"package-support";
        case CydiaUIRouteKindLaunchApplication: return @"launch";
        case CydiaUIRouteKindExternalOpen: return @"external-open";
    }
}

NSString *OutcomeName(CydiaUIRouteDispatchResult *result) {
    switch ([result outcome]) {
        case CydiaUIRouteDispatchOutcomeUnhandled: return @"unhandled";
        case CydiaUIRouteDispatchOutcomeRejected: return @"reject";
        case CydiaUIRouteDispatchOutcomeAllowed: return @"allow";
    }
}

BOOL FixtureBoolean(NSString *value) {
    Expect([value isEqualToString:@"yes"] || [value isEqualToString:@"no"],
        [NSString stringWithFormat:@"invalid fixture boolean %@", value]);
    return [value isEqualToString:@"yes"];
}

void VerifyDispatchFixture(NSString *path) {
    NSError *error(nil);
    NSString *fixture([NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:&error]);
    Expect(fixture != nil && error == nil, @"load route-dispatch fixture");

    NSMutableSet *seen([NSMutableSet set]);
    for (NSString *line in [fixture componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]]) {
        if ([line length] == 0 || [line hasPrefix:@"#"])
            continue;
        NSArray *fields([line componentsSeparatedByString:@"\t"]);
        Expect([fields count] == 10, @"route-dispatch fixture has ten columns");
        NSString *route([fields objectAtIndex:0]);
        NSString *caller([fields objectAtIndex:1]);
        NSString *identity([NSString stringWithFormat:@"%@\t%@\t%@", route, caller,
            [fields objectAtIndex:2]]);
        Expect(![seen containsObject:identity], @"route-dispatch fixture rows are unique");
        [seen addObject:identity];

        BOOL sourceKnown(FixtureBoolean([fields objectAtIndex:2]));
        CydiaUIRouteDispatchResult *result(CydiaUIDispatchRouteURL(
            [NSURL URLWithString:route], ContextForName(caller),
            ^BOOL(NSString *sourceKey) {
                Expect([sourceKey length] != 0, @"source lookup receives a key");
                return sourceKnown;
            }));
        Expect([OutcomeName(result) isEqualToString:[fields objectAtIndex:3]],
            [NSString stringWithFormat:@"outcome %@", identity]);
        Expect([result isPolicyEnforced] == FixtureBoolean([fields objectAtIndex:4]),
            [NSString stringWithFormat:@"policy enforcement %@", identity]);
        Expect([result isShadowDenied] == FixtureBoolean([fields objectAtIndex:5]),
            [NSString stringWithFormat:@"shadow result %@", identity]);
        Expect([KindName([result descriptor]) isEqualToString:[fields objectAtIndex:6]],
            [NSString stringWithFormat:@"kind %@", identity]);

        NSString *required([result requiredSourceKey] ?: @"-");
        Expect([required isEqualToString:[fields objectAtIndex:7]],
            [NSString stringWithFormat:@"source key %@", identity]);
        NSString *external([[[result descriptor] externalURL] absoluteString] ?: @"-");
        Expect([external isEqualToString:[fields objectAtIndex:8]],
            [NSString stringWithFormat:@"external URL %@", identity]);
        BOOL confirmation([[result decision] requiresConfirmation]);
        Expect(confirmation == FixtureBoolean([fields objectAtIndex:9]),
            [NSString stringWithFormat:@"confirmation %@", identity]);
        Expect([result isHandled] == ![[fields objectAtIndex:3] isEqualToString:@"unhandled"],
            [NSString stringWithFormat:@"handled result %@", identity]);
        Expect([result isPolicyEnforced] && ![result isShadowDenied],
            @"every typed dispatch result is enforced");
    }
    Expect([seen count] >= 19, @"route-dispatch fixture covers enforcement boundaries");
}

void VerifyWebEnforcementBoundary(void) {
    CydiaUIRouteDispatchResult *trustedLegacy(CydiaUIDispatchRouteURL(
        [NSURL URLWithString:@"cydia://launch/com.example.app"],
        ContextForName(@"trusted-legacy"), ^BOOL(NSString *) { return YES; }));
    Expect(![trustedLegacy isAllowed] && [trustedLegacy isPolicyEnforced] &&
        ![trustedLegacy isShadowDenied],
        @"trusted legacy launch denial is terminal");
    Expect([[trustedLegacy decision] denialReason] == CydiaUIRouteDenialReasonCaller,
        @"trusted legacy result retains its caller denial");

    CydiaUIRouteDispatchResult *trustedLaunch(CydiaUIDispatchRouteURL(
        [NSURL URLWithString:@"cydia://launch/com.example.app"],
        ContextForName(@"trusted-native"), ^BOOL(NSString *) { return YES; }));
    Expect([trustedLaunch isAllowed] && [trustedLaunch isHandled] &&
        [[trustedLaunch decision] disposition] == CydiaUIRouteDispositionNativeCommand,
        @"an allowed launch is a handled native command even without a controller");

    CydiaUIRouteDispatchResult *untrustedGesture(CydiaUIDispatchRouteURL(
        [NSURL URLWithString:@"cydia://url/https://example.com/automatic"],
        ContextForName(@"untrusted-web"), ^BOOL(NSString *) { return YES; }));
    Expect(![untrustedGesture isAllowed] &&
        [untrustedGesture isPolicyEnforced] &&
        ![untrustedGesture isShadowDenied],
        @"untrusted user-gesture denial is terminal");
    Expect([[untrustedGesture decision] denialReason] == CydiaUIRouteDenialReasonUserGesture,
        @"untrusted result retains its user-gesture denial");

    CydiaUIRouteDispatchResult *unknownSource(CydiaUIDispatchRouteURL(
        [NSURL URLWithString:@"cydia://sources/missing"],
        ContextForName(@"external-url"), ^BOOL(NSString *) { return NO; }));
    Expect(![unknownSource isAllowed] && ![unknownSource isShadowDenied] &&
        [unknownSource isPolicyEnforced] &&
        [unknownSource denialReason] == CydiaUIRouteDispatchDenialReasonUnknownSource,
        @"allowed source route still fails closed when its key is unknown");

    CydiaUIRouteDispatchResult *repositoryPackage(CydiaUIDispatchRouteURL(
        [NSURL URLWithString:@"cydia://package/example:iphoneos-arm64"],
        ContextForName(@"repository-depiction"), ^BOOL(NSString *) { return YES; }));
    Expect([repositoryPackage isAllowed] &&
        [repositoryPackage isPolicyEnforced] &&
        ![repositoryPackage isShadowDenied],
        @"repository depiction retains its read-only package route");

    CydiaUIRouteDispatchResult *repositoryForeign(CydiaUIDispatchRouteURL(
        [NSURL URLWithString:@"cydia://package/other:iphoneos-arm64"],
        ContextForName(@"repository-depiction"), ^BOOL(NSString *) { return YES; }));
    Expect([repositoryForeign isAllowed] && [repositoryForeign isPolicyEnforced] &&
        ![repositoryForeign isShadowDenied],
        @"repository depiction permits a distinct package after a main-frame gesture");
}

NSArray *AbsoluteStrings(NSArray *urls) {
    NSMutableArray *strings([NSMutableArray arrayWithCapacity:[urls count]]);
    for (NSURL *url in urls)
        [strings addObject:[url absoluteString]];
    return strings;
}

void VerifyRestoration(void) {
    NSString *knownSource(@"deb:https://repo.example/:./");
    CydiaUIRouteSourceLookup lookup = ^BOOL(NSString *sourceKey) {
        return [sourceKey isEqualToString:knownSource];
    };

    NSArray *valid(CydiaUIRestorationRouteURLs(@[
        @"cydia://home",
        @"cydia://package/example:iphoneos-arm64",
        @"cydia://url/https%3A%2F%2Fexample.com%2Fguide",
    ], @"cydia://home", lookup));
    Expect([AbsoluteStrings(valid) isEqual:@[
        @"cydia://home",
        @"cydia://package/example:iphoneos-arm64",
    ]], @"saved stack preserves controllers but never replays external actions");

    NSArray *invalidRoot(CydiaUIRestorationRouteURLs(@[
        @"cydia://home-invalid",
        @"cydia://package/should-not-become-root",
    ], @"cydia://home", lookup));
    Expect([AbsoluteStrings(invalidRoot) isEqual:@[@"cydia://home"]],
        @"invalid saved root falls back without promoting a child");

    NSArray *wrongRootKind(CydiaUIRestorationRouteURLs(@[
        @"cydia://sources/example:source",
        @"cydia://package/should-not-become-root",
    ], @"cydia://sources", lookup));
    Expect([AbsoluteStrings(wrongRootKind) isEqual:@[@"cydia://sources"]],
        @"source detail cannot masquerade as the Sources tab root");

    NSArray *staleChildren(CydiaUIRestorationRouteURLs(@[
        @"cydia://sources",
        @"cydia://sources/missing-source",
        @"cydia://sources/add",
        @"cydia://launch/com.example.app",
        @"cydia://package/example:iphoneos-arm64",
    ], @"cydia://sources", lookup));
    Expect([AbsoluteStrings(staleChildren) isEqual:@[
        @"cydia://sources",
        @"cydia://package/example:iphoneos-arm64",
    ]], @"restoration omits stale sources and command routes");

    NSArray *search(CydiaUIRestorationRouteURLs(@[
        @"cydia://search/owner%2Frepository",
    ], @"cydia://search", lookup));
    Expect([AbsoluteStrings(search) isEqual:@[
        @"cydia://search/owner%2Frepository",
    ]], @"search root retains its escaped query");

    NSArray *missing(CydiaUIRestorationRouteURLs(nil, @"cydia://installed", lookup));
    Expect([AbsoluteStrings(missing) isEqual:@[@"cydia://installed"]],
        @"missing saved stack uses its standard root");
}

} // namespace

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Expect(argc == 2, @"route-dispatch fixture path is required");
        VerifyDispatchFixture([NSString stringWithUTF8String:argv[1]]);
        VerifyWebEnforcementBoundary();
        VerifyRestoration();
    }
    std::cout << "[verify-ui-route-dispatch][ ok ] typed enforcement and restoration" << std::endl;
    return 0;
}
