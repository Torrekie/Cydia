/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyBridgePolicy.h"

#include <cstdlib>
#include <iostream>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    std::cerr << "[verify-legacy-bridge-policy][FAIL] " << [message UTF8String] << std::endl;
    std::exit(1);
}

CydiaLegacyBridgeMemberKind MemberKind(NSString *name) {
    NSDictionary *kinds(@{
        @"method": @(CydiaLegacyBridgeMemberKindMethod),
        @"attribute": @(CydiaLegacyBridgeMemberKindAttribute),
        @"global": @(CydiaLegacyBridgeMemberKindGlobal),
        @"dynamic-method": @(CydiaLegacyBridgeMemberKindDynamicMethod),
        @"key-policy": @(CydiaLegacyBridgeMemberKindKeyPolicy),
    });
    NSNumber *value([kinds objectForKey:name]);
    Expect(value != nil, [NSString stringWithFormat:@"known member kind %@", name]);
    return (CydiaLegacyBridgeMemberKind) [value unsignedIntegerValue];
}

CydiaLegacyBridgeAccessRequirement Requirement(NSString *name) {
    NSDictionary *requirements(@{
        @"deny": @(CydiaLegacyBridgeAccessRequirementDenied),
        @"allow": @(CydiaLegacyBridgeAccessRequirementAllowed),
        @"gesture": @(CydiaLegacyBridgeAccessRequirementUserGesture),
        @"current-package": @(CydiaLegacyBridgeAccessRequirementCurrentPackage),
        @"current-source": @(CydiaLegacyBridgeAccessRequirementCurrentSource),
        @"allowlisted": @(CydiaLegacyBridgeAccessRequirementAllowlistedOrigin),
        @"retired": @(CydiaLegacyBridgeAccessRequirementRetired),
    });
    NSNumber *value([requirements objectForKey:name]);
    Expect(value != nil, [NSString stringWithFormat:@"known requirement %@", name]);
    return (CydiaLegacyBridgeAccessRequirement) [value unsignedIntegerValue];
}

CydiaLegacyBridgeRequest *Request(CydiaLegacyBridgeMember *member,
                                  CydiaUIRouteContext *context,
                                  NSURL *callingOrigin,
                                  NSString *packageIdentity,
                                  NSURL *targetOrigin) {
    return [[CydiaLegacyBridgeRequest alloc]
        initWithScope:[member scope]
        memberKind:[member kind]
        memberName:[member name]
        context:context
        callingOrigin:callingOrigin
        packageIdentity:packageIdentity
        targetOrigin:targetOrigin];
}

NSString *MemberKey(CydiaLegacyBridgeMember *member) {
    return [NSString stringWithFormat:@"%@|%@|%@", [member scope],
        CydiaLegacyBridgeMemberKindName([member kind]), [member name]];
}

BOOL IsDepictionSafeFamily(CydiaLegacyBridgeOperationFamily family) {
    return family == CydiaLegacyBridgeOperationFamilyRendering ||
        family == CydiaLegacyBridgeOperationFamilyPackageRead ||
        family == CydiaLegacyBridgeOperationFamilySourceRead;
}

void VerifyCallerMatrix(CydiaLegacyBridgeMember *member,
                        CydiaUIRouteContext *trusted,
                        CydiaUIRouteContext *trustedWithoutGesture,
                        CydiaUIRouteContext *depiction,
                        CydiaUIRouteContext *native,
                        CydiaUIRouteContext *external,
                        CydiaUIRouteContext *untrusted,
                        NSURL *trustedOrigin,
                        NSURL *depictionOrigin) {
    NSString *key(MemberKey(member));
    CydiaLegacyBridgeAuthorization *trustedResult(CydiaLegacyBridgeAuthorize(
        Request(member, trusted, trustedOrigin,
            @"example:iphoneos-arm64", depictionOrigin)));
    if ([member trustedLegacyRequirement] == CydiaLegacyBridgeAccessRequirementRetired) {
        Expect(![trustedResult isAllowed] &&
               [trustedResult denialReason] == CydiaLegacyBridgeDenialReasonRetiredSurface,
               [NSString stringWithFormat:@"retired trusted surface %@", key]);
    } else {
        Expect([trustedResult isAllowed] &&
               [trustedResult disposition] ==
                    CydiaLegacyBridgeAuthorizationDispositionTrustedLegacyCompatibility &&
               [trustedResult member] == member,
               [NSString stringWithFormat:@"trusted compatibility %@", key]);
    }

    CydiaLegacyBridgeAuthorization *automaticTrusted(CydiaLegacyBridgeAuthorize(
        Request(member, trustedWithoutGesture, trustedOrigin,
            @"example:iphoneos-arm64", depictionOrigin)));
    if ([member trustedLegacyRequirement] == CydiaLegacyBridgeAccessRequirementUserGesture) {
        Expect(![automaticTrusted isAllowed] &&
               [automaticTrusted denialReason] == CydiaLegacyBridgeDenialReasonUserGesture,
               [NSString stringWithFormat:@"gesture required %@", key]);
    } else if ([member trustedLegacyRequirement] == CydiaLegacyBridgeAccessRequirementRetired) {
        Expect(![automaticTrusted isAllowed] &&
               [automaticTrusted denialReason] == CydiaLegacyBridgeDenialReasonRetiredSurface,
               [NSString stringWithFormat:@"retired automatic surface %@", key]);
    } else {
        Expect([automaticTrusted isAllowed],
               [NSString stringWithFormat:@"trusted automatic compatibility %@", key]);
    }

    CydiaLegacyBridgeAuthorization *depictionResult(CydiaLegacyBridgeAuthorize(
        Request(member, depiction, depictionOrigin,
            @"example:iphoneos-arm64", depictionOrigin)));
    CydiaLegacyBridgeAccessRequirement depictionRequirement(
        [member repositoryDepictionRequirement]);
    if (depictionRequirement == CydiaLegacyBridgeAccessRequirementDenied) {
        Expect(![depictionResult isAllowed],
               [NSString stringWithFormat:@"depiction denies %@", key]);
    } else if (depictionRequirement == CydiaLegacyBridgeAccessRequirementRetired) {
        Expect(![depictionResult isAllowed] &&
               [depictionResult denialReason] == CydiaLegacyBridgeDenialReasonRetiredSurface,
               [NSString stringWithFormat:@"depiction retired surface %@", key]);
    } else {
        Expect([depictionResult isAllowed] && [depictionResult isDepictionReadOnly] &&
               [depictionResult disposition] ==
                    CydiaLegacyBridgeAuthorizationDispositionDepictionReadOnly,
               [NSString stringWithFormat:@"depiction read-only %@", key]);
        Expect(IsDepictionSafeFamily([member family]),
               [NSString stringWithFormat:@"depiction safe family %@", key]);
    }

    for (CydiaUIRouteContext *deniedContext in @[native, external, untrusted]) {
        CydiaLegacyBridgeAuthorization *denied(CydiaLegacyBridgeAuthorize(
            Request(member, deniedContext, depictionOrigin,
                @"example:iphoneos-arm64", depictionOrigin)));
        Expect(![denied isAllowed] &&
               [denied denialReason] == CydiaLegacyBridgeDenialReasonCaller,
               [NSString stringWithFormat:@"non-legacy caller denied %@", key]);
    }
}

void VerifyMethodFixture(NSString *path,
                         NSMutableSet *fixtureKeys,
                         NSArray *contexts) {
    NSError *error(nil);
    NSString *fixture([NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:&error]);
    Expect(fixture != nil && error == nil, @"load legacy method fixture");

    for (NSString *line in [fixture componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]]) {
        if ([line length] == 0 || [line hasPrefix:@"#"])
            continue;
        NSArray *fields([line componentsSeparatedByString:@"\t"]);
        Expect([fields count] == 6, @"legacy method fixture has six columns");
        NSString *scope([fields objectAtIndex:0]);
        NSString *kindName([fields objectAtIndex:1]);
        NSString *name([fields objectAtIndex:2]);
        NSString *family([fields objectAtIndex:3]);
        NSString *trustedRule([fields objectAtIndex:4]);
        NSString *depictionRule([fields objectAtIndex:5]);

        CydiaLegacyBridgeMemberKind kind(MemberKind(kindName));
        CydiaLegacyBridgeMember *member(CydiaLegacyBridgeMemberForName(scope, kind, name));
        Expect(member != nil, [NSString stringWithFormat:@"method policy %@.%@", scope, name]);
        NSString *key(MemberKey(member));
        Expect(![fixtureKeys containsObject:key], [NSString stringWithFormat:@"unique %@", key]);
        [fixtureKeys addObject:key];
        Expect([[member sourceForm] isEqualToString:@"selector-mapping"],
               [NSString stringWithFormat:@"selector source %@", key]);
        Expect([CydiaLegacyBridgeOperationFamilyName([member family]) isEqualToString:family],
               [NSString stringWithFormat:@"method family %@", key]);
        Expect([member trustedLegacyRequirement] == Requirement(trustedRule) &&
               [member repositoryDepictionRequirement] == Requirement(depictionRule),
               [NSString stringWithFormat:@"method requirements %@", key]);
        VerifyCallerMatrix(member,
            [contexts objectAtIndex:0], [contexts objectAtIndex:1],
            [contexts objectAtIndex:2], [contexts objectAtIndex:3],
            [contexts objectAtIndex:4], [contexts objectAtIndex:5],
            [contexts objectAtIndex:6], [contexts objectAtIndex:7]);
    }
}

void ExpectedPropertyPolicy(NSString *scope,
                            CydiaLegacyBridgeMemberKind kind,
                            CydiaLegacyBridgeOperationFamily *family,
                            CydiaLegacyBridgeAccessRequirement *trusted,
                            CydiaLegacyBridgeAccessRequirement *depiction) {
    *trusted = CydiaLegacyBridgeAccessRequirementAllowed;
    *depiction = CydiaLegacyBridgeAccessRequirementDenied;
    if (kind == CydiaLegacyBridgeMemberKindKeyPolicy ||
        [scope isEqualToString:@"CydiaProgressData"] ||
        [scope isEqualToString:@"CydiaProgressEvent"]) {
        *family = CydiaLegacyBridgeOperationFamilyRetired;
        *trusted = CydiaLegacyBridgeAccessRequirementRetired;
        *depiction = CydiaLegacyBridgeAccessRequirementRetired;
    } else if ([scope isEqualToString:@"CyteObject"] ||
               [scope isEqualToString:@"CydiaObject"]) {
        *family = CydiaLegacyBridgeOperationFamilySensitive;
    } else if ([scope isEqualToString:@"Source"]) {
        *family = CydiaLegacyBridgeOperationFamilySourceRead;
        *depiction = CydiaLegacyBridgeAccessRequirementCurrentSource;
    } else if ([scope isEqualToString:@"Package"] ||
               [scope isEqualToString:@"CydiaOperation"] ||
               [scope isEqualToString:@"CydiaClause"] ||
               [scope isEqualToString:@"CydiaRelation"] ||
               [scope isEqualToString:@"MIMEAddress"]) {
        *family = CydiaLegacyBridgeOperationFamilyPackageRead;
        *depiction = CydiaLegacyBridgeAccessRequirementCurrentPackage;
    } else if ([scope isEqualToString:@"Window"]) {
        *family = CydiaLegacyBridgeOperationFamilyChrome;
    } else if ([scope isEqualToString:@"NSDictionary"]) {
        *family = CydiaLegacyBridgeOperationFamilyGlobalRead;
    } else {
        Expect(NO, [NSString stringWithFormat:@"classified property scope %@", scope]);
    }
}

void VerifyPropertyFixture(NSString *path,
                           NSMutableSet *fixtureKeys,
                           NSArray *contexts) {
    NSError *error(nil);
    NSString *fixture([NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:&error]);
    Expect(fixture != nil && error == nil, @"load legacy property fixture");

    for (NSString *line in [fixture componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]]) {
        if ([line length] == 0 || [line hasPrefix:@"#"])
            continue;
        NSArray *fields([line componentsSeparatedByString:@"\t"]);
        Expect([fields count] == 4, @"legacy property fixture has four columns");
        NSString *scope([fields objectAtIndex:0]);
        CydiaLegacyBridgeMemberKind kind(MemberKind([fields objectAtIndex:1]));
        NSString *name([fields objectAtIndex:2]);
        NSString *sourceForm([fields objectAtIndex:3]);
        CydiaLegacyBridgeMember *member(CydiaLegacyBridgeMemberForName(scope, kind, name));
        Expect(member != nil, [NSString stringWithFormat:@"property policy %@.%@", scope, name]);
        NSString *key(MemberKey(member));
        Expect(![fixtureKeys containsObject:key], [NSString stringWithFormat:@"unique %@", key]);
        [fixtureKeys addObject:key];
        Expect([[member sourceForm] isEqualToString:sourceForm],
               [NSString stringWithFormat:@"property source %@", key]);

        CydiaLegacyBridgeOperationFamily expectedFamily;
        CydiaLegacyBridgeAccessRequirement expectedTrusted;
        CydiaLegacyBridgeAccessRequirement expectedDepiction;
        ExpectedPropertyPolicy(scope, kind, &expectedFamily,
            &expectedTrusted, &expectedDepiction);
        Expect([member family] == expectedFamily &&
               [member trustedLegacyRequirement] == expectedTrusted &&
               [member repositoryDepictionRequirement] == expectedDepiction,
               [NSString stringWithFormat:@"property classification %@", key]);
        VerifyCallerMatrix(member,
            [contexts objectAtIndex:0], [contexts objectAtIndex:1],
            [contexts objectAtIndex:2], [contexts objectAtIndex:3],
            [contexts objectAtIndex:4], [contexts objectAtIndex:5],
            [contexts objectAtIndex:6], [contexts objectAtIndex:7]);
    }
}

} // namespace

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Expect(argc == 3, @"method and property fixture paths are required");

        NSURL *trustedOrigin([NSURL URLWithString:@"https://cydia.saurik.com/ui/"]);
        NSURL *depictionOrigin([NSURL URLWithString:@"https://repo.example/depiction"]);
        CydiaUIRouteContext *trusted([CydiaUIRouteContext
            trustedLegacyPageContextWithOrigin:trustedOrigin mainFrame:YES userGesture:YES]);
        CydiaUIRouteContext *trustedWithoutGesture([CydiaUIRouteContext
            trustedLegacyPageContextWithOrigin:trustedOrigin mainFrame:YES userGesture:NO]);
        CydiaUIRouteContext *depiction([CydiaUIRouteContext
            repositoryDepictionContextWithOrigin:depictionOrigin
            packageIdentity:@"example:iphoneos-arm64" mainFrame:YES userGesture:YES]);
        CydiaUIRouteContext *native([CydiaUIRouteContext trustedNativeContext]);
        CydiaUIRouteContext *external([CydiaUIRouteContext externalURLContext]);
        CydiaUIRouteContext *untrusted([CydiaUIRouteContext
            untrustedWebPageContextWithOrigin:depictionOrigin mainFrame:YES userGesture:YES]);
        Expect(trusted != nil && trustedWithoutGesture != nil && depiction != nil,
               @"validated bridge contexts");

        NSArray *contexts(@[trusted, trustedWithoutGesture, depiction,
            native, external, untrusted, trustedOrigin, depictionOrigin]);
        NSMutableSet *fixtureKeys([NSMutableSet set]);
        VerifyMethodFixture([NSString stringWithUTF8String:argv[1]], fixtureKeys, contexts);
        VerifyPropertyFixture([NSString stringWithUTF8String:argv[2]], fixtureKeys, contexts);

        NSArray *members(CydiaLegacyBridgeMembers());
        Expect([members count] == [fixtureKeys count],
               @"runtime member count matches both inventories");
        NSMutableSet *policyKeys([NSMutableSet set]);
        for (CydiaLegacyBridgeMember *member in members) {
            NSString *key(MemberKey(member));
            Expect(![policyKeys containsObject:key],
                   [NSString stringWithFormat:@"unique runtime %@", key]);
            [policyKeys addObject:key];
        }
        Expect([policyKeys isEqualToSet:fixtureKeys],
               @"method and property fixtures exactly match runtime policy");

        CydiaLegacyBridgeMember *format(CydiaLegacyBridgeMemberForName(
            @"CyteObject", CydiaLegacyBridgeMemberKindMethod, @"format"));
        CydiaLegacyBridgeMember *packageRead(CydiaLegacyBridgeMemberForName(
            @"Package", CydiaLegacyBridgeMemberKindMethod, @"getField"));
        CydiaLegacyBridgeMember *packageAttribute(CydiaLegacyBridgeMemberForName(
            @"Package", CydiaLegacyBridgeMemberKindAttribute, @"name"));
        CydiaLegacyBridgeMember *sourceRead(CydiaLegacyBridgeMemberForName(
            @"Source", CydiaLegacyBridgeMemberKindAttribute, @"label"));
        CydiaLegacyBridgeMember *reachability(CydiaLegacyBridgeMemberForName(
            @"CyteObject", CydiaLegacyBridgeMemberKindMethod, @"isReachable"));
        CydiaLegacyBridgeMember *mutation(CydiaLegacyBridgeMemberForName(
            @"CydiaObject", CydiaLegacyBridgeMemberKindMethod, @"installPackages"));
        CydiaLegacyBridgeMember *windowGlobal(CydiaLegacyBridgeMemberForName(
            @"Window", CydiaLegacyBridgeMemberKindGlobal, @"cydia"));
        CydiaLegacyBridgeMember *retiredProgress(CydiaLegacyBridgeMemberForName(
            @"CydiaProgressData", CydiaLegacyBridgeMemberKindAttribute, @"events"));
        Expect(format != nil && packageRead != nil && packageAttribute != nil &&
               sourceRead != nil && reachability != nil && mutation != nil &&
               windowGlobal != nil && retiredProgress != nil,
               @"representative bridge members exist");

        Expect(![CydiaLegacyBridgeAuthorize(nil) isAllowed] &&
               [CydiaLegacyBridgeAuthorize(nil) denialReason] ==
                    CydiaLegacyBridgeDenialReasonMalformedRequest,
               @"nil request fails closed");
        CydiaLegacyBridgeRequest *unknown([[CydiaLegacyBridgeRequest alloc]
            initWithScope:@"CydiaObject" memberKind:CydiaLegacyBridgeMemberKindMethod
            memberName:@"notAnAPI" context:trusted callingOrigin:trustedOrigin
            packageIdentity:nil targetOrigin:nil]);
        Expect(![CydiaLegacyBridgeAuthorize(unknown) isAllowed] &&
               [CydiaLegacyBridgeAuthorize(unknown) denialReason] ==
                    CydiaLegacyBridgeDenialReasonUnknownMember,
               @"unknown name fails closed");
        CydiaLegacyBridgeRequest *missingContext([[CydiaLegacyBridgeRequest alloc]
            initWithScope:@"CyteObject" memberKind:CydiaLegacyBridgeMemberKindMethod
            memberName:@"format" context:nil callingOrigin:trustedOrigin
            packageIdentity:nil targetOrigin:nil]);
        Expect(![CydiaLegacyBridgeAuthorize(missingContext) isAllowed] &&
               [CydiaLegacyBridgeAuthorize(missingContext) denialReason] ==
                    CydiaLegacyBridgeDenialReasonMissingContext,
               @"nil context fails closed");

        NSArray *badTrustedOrigins(@[
            [NSNull null],
            [NSURL URLWithString:@"https://user:password@cydia.saurik.com/ui/"],
            [NSURL URLWithString:@"http://cydia.saurik.com/ui/"],
            [NSURL URLWithString:@"https://repo.example/ui/"],
            [NSURL URLWithString:@"relative-origin"],
            [NSURL URLWithString:@"https://cydia.saurik.com:70000/ui/"],
            [NSURL URLWithString:[NSString stringWithFormat:@"file://evil%@/trusted-local.html",
                [[NSBundle mainBundle] bundlePath]]],
        ]);
        for (id value in badTrustedOrigins) {
            NSURL *origin(value == [NSNull null] ? nil : value);
            CydiaLegacyBridgeAuthorization *result(CydiaLegacyBridgeAuthorize(
                Request(format, trusted, origin, nil, nil)));
            Expect(![result isAllowed] &&
                   [result denialReason] == CydiaLegacyBridgeDenialReasonOrigin,
                   @"malformed, credential-bearing, and non-first-party origins fail closed");
        }

        NSURL *bundledOrigin([NSURL fileURLWithPath:
            [[[NSBundle mainBundle] bundlePath]
                stringByAppendingPathComponent:@"trusted-local.html"]]);
        CydiaUIRouteContext *bundledTrusted([CydiaUIRouteContext
            trustedLegacyPageContextWithOrigin:bundledOrigin mainFrame:YES userGesture:YES]);
        Expect(bundledTrusted != nil &&
               [CydiaLegacyBridgeAuthorize(
                    Request(format, bundledTrusted, bundledOrigin, nil, nil)) isAllowed],
               @"reviewed bundled first-party pages retain compatibility");

        CydiaUIRouteContext *trustedSubframe([CydiaUIRouteContext
            trustedLegacyPageContextWithOrigin:trustedOrigin mainFrame:NO userGesture:YES]);
        Expect([CydiaLegacyBridgeAuthorize(
                    Request(format, trustedSubframe, trustedOrigin, nil, nil)) isAllowed] &&
               [CydiaLegacyBridgeAuthorize(
                    Request(windowGlobal, trustedSubframe, trustedOrigin, nil, nil)) isAllowed],
               @"same-origin trusted legacy subframes retain current compatibility");
        CydiaUIRouteContext *depictionSubframe([CydiaUIRouteContext
            repositoryDepictionContextWithOrigin:depictionOrigin
            packageIdentity:@"example:iphoneos-arm64" mainFrame:NO userGesture:YES]);
        CydiaLegacyBridgeAuthorization *subframeDenied(CydiaLegacyBridgeAuthorize(
            Request(format, depictionSubframe, depictionOrigin, nil, nil)));
        Expect(![subframeDenied isAllowed] &&
               [subframeDenied denialReason] == CydiaLegacyBridgeDenialReasonMainFrame,
               @"repository depiction subframes receive no bridge");

        NSURL *otherOrigin([NSURL URLWithString:@"https://other.example/page"]);
        CydiaLegacyBridgeAuthorization *crossOrigin(CydiaLegacyBridgeAuthorize(
            Request(format, depiction, otherOrigin, nil, nil)));
        Expect(![crossOrigin isAllowed] &&
               [crossOrigin denialReason] == CydiaLegacyBridgeDenialReasonOrigin,
               @"depiction redirects cannot retain bridge authority cross-origin");
        NSURL *credentialOrigin([NSURL URLWithString:@"https://user:password@repo.example/page"]);
        Expect(![CydiaLegacyBridgeAuthorize(
                    Request(format, depiction, credentialOrigin, nil, nil)) isAllowed],
               @"credential-bearing depiction caller fails closed");

        NSArray *badPackageIdentities(@[
            [NSNull null], @"other:iphoneos-arm64", @"../example", @"example/path"
        ]);
        for (id value in badPackageIdentities) {
            NSString *identity(value == [NSNull null] ? nil : value);
            for (CydiaLegacyBridgeMember *member in
                    @[packageRead, packageAttribute, sourceRead]) {
                CydiaLegacyBridgeAuthorization *result(CydiaLegacyBridgeAuthorize(
                    Request(member, depiction, depictionOrigin, identity, nil)));
                Expect(![result isAllowed] &&
                       [result denialReason] == CydiaLegacyBridgeDenialReasonPackageIdentity,
                       @"package and source reads remain bound to current depiction");
            }
        }

        NSArray *badTargets(@[
            [NSNull null],
            [NSURL URLWithString:@"https://other.example/"],
            [NSURL URLWithString:@"http://repo.example/"],
            [NSURL URLWithString:@"https://user:password@repo.example/"],
            [NSURL fileURLWithPath:@"/etc/passwd"],
        ]);
        for (id value in badTargets) {
            NSURL *target(value == [NSNull null] ? nil : value);
            CydiaLegacyBridgeAuthorization *result(CydiaLegacyBridgeAuthorize(
                Request(reachability, depiction, depictionOrigin, nil, target)));
            Expect(![result isAllowed] &&
                   [result denialReason] == CydiaLegacyBridgeDenialReasonTargetOrigin,
                   @"depiction reachability remains same-origin and credential-free");
        }

        Expect(![CydiaLegacyBridgeAuthorize(Request(mutation, depiction,
                    depictionOrigin, @"example:iphoneos-arm64", depictionOrigin)) isAllowed],
               @"depiction cannot mutate");
        CydiaLegacyBridgeAuthorization *retired(CydiaLegacyBridgeAuthorize(
            Request(retiredProgress, trusted, trustedOrigin, nil, nil)));
        Expect(![retired isAllowed] &&
               [retired denialReason] == CydiaLegacyBridgeDenialReasonRetiredSurface,
               @"native Progress WebScript attributes remain retired debt");
        CydiaLegacyBridgeMember *wildcard(CydiaLegacyBridgeMemberForName(
            @"CyteObject", CydiaLegacyBridgeMemberKindKeyPolicy, @"*"));
        Expect(wildcard != nil && ![CydiaLegacyBridgeAuthorize(
                    Request(wildcard, trusted, trustedOrigin, nil, nil)) isAllowed] &&
               CydiaLegacyBridgeMemberForName(@"CyteObject",
                    CydiaLegacyBridgeMemberKindAttribute, @"unknownProperty") == nil,
               @"legacy wildcard is inventoried debt, never an authorization fallback");
        Expect(CydiaLegacyBridgeMemberForName(nil,
                    CydiaLegacyBridgeMemberKindMethod, @"format") == nil &&
               CydiaLegacyBridgeMemberForName(@"CyteObject",
                    CydiaLegacyBridgeMemberKindMethod, nil) == nil,
               @"malformed lookup fails closed");

        std::cout << "[verify-legacy-bridge-policy][ ok ] "
                  << [members count]
                  << " legacy methods/properties are origin-bound and caller-scoped"
                  << std::endl;
    }
    return 0;
}
