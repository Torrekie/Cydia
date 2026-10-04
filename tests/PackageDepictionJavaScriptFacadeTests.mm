#include "Cydia/PackageDepictionJavaScriptFacade.h"

#include <cstdlib>
#include <iostream>

namespace {

void Expect(BOOL condition, const char *message) {
    if (condition)
        return;
    std::cerr << "[verify-depiction-facade][FAIL] " << message << std::endl;
    std::exit(1);
}

} // namespace

int main() {
    @autoreleasepool {
        NSURL *origin([NSURL URLWithString:@"https://repo.example/depiction/com.demo"]);
        NSDictionary *snapshot(@{
            @"package": @{
                @"values": @{
                    @"id": @"com.demo",
                    @"aptId": @"com.demo:iphoneos-arm64",
                    @"dpkgId": @"com.demo:1.2.3",
                    @"architecture": @"iphoneos-arm64",
                    @"depiction": @"https://repo.example/depiction/com.demo",
                    @"icon": @"cydia://package-icon/com.demo",
                    @"longDescription": @"A long bounded package fixture",
                    @"longSection": @"Utilities",
                    @"name": @"Demo",
                    @"section": @"Utilities",
                    @"shortSection": @"Utilities",
                    @"shortDescription": @"A bounded package fixture",
                    @"simpleSection": @"Utilities",
                    @"homepage": @"https://repo.example/packages/com.demo",
                    @"applications": @[
                        @[ @"com.demo.app", @"Demo App", @"file:///Applications/Demo.app/icon.png" ]
                    ],
                    @"baseId": @"com.demo",
                    @"essential": @YES,
                    @"installed": @"1.0",
                    @"latest": @"1.2.3",
                    @"md5sum": @"0123456789abcdef0123456789abcdef",
                    @"mode": @"INSTALL",
                    @"multiArch": @"same",
                    @"purposes": @[ @"utility" ],
                    @"selection": @"install",
                    @"size": @1234,
                    @"state": @"Installed",
                    @"support": @"https://repo.example/support/com.demo",
                    @"tags": @[ @"purpose::utility" ],
                    @"upgraded": @1700000000,
                    @"warnings": @[ @"Package warning" ],
                },
                @"fields": @{ @"Version": @"1.2.3" },
                @"record": @"Package: com.demo\nVersion: 1.2.3\n",
                @"tags": @[ @"purpose::utility" ],
                @"author": @{ @"name": @"Demo Author", @"address": @"author@example.test" },
                @"maintainer": @{ @"name": @"Demo Maintainer", @"address": @"maintainer@example.test" },
                @"relations": @[
                    @{ @"relationship": @"Depends", @"clauses": @[
                        @{ @"package": @"com.dependency", @"version": @{
                            @"operator": @">=", @"value": @"1.0" } }
                    ] }
                ],
            },
            @"source": @{
                @"values": @{ @"key": @"deb:https://repo.example/:./" },
                @"record": @{ @"Origin": @"Demo Repo" },
            },
            @"preferredLanguages": @[ @"zh-Hans", @"en-US" ],
            @"localeIdentifier": @"zh_CN",
            @"supports": @[ @"depiction", @"window.cydia", @"ios12" ],
        });

        NSString *script([CydiaPackageDepictionJavaScriptFacade
            scriptForSnapshot:snapshot origin:origin packageIdentity:@"com.demo"
            generation:7 bindingToken:@"binding-7"]);
        Expect(script != nil && [script length] > 1000, "generated facade script");
        NSArray *required(@[
            @"getPackageById", @"getField", @"getRecord", @"hasTag",
            @"getLocaleIdentifier", @"getPreferredLanguages", @"localize",
            @"format", @"supports", @"isReachable", @"cydiaDepictionBridge",
            @"sourceKeys", @"project", @"baseuri", @"trusted", @"nested",
            @"hasTags",
            @"id", @"name", @"architecture", @"aptId", @"dpkgId", @"section",
            @"shortDescription", @"homepage",
            @"applications", @"baseId", @"essential", @"installed", @"latest",
            @"md5sum", @"mode", @"multiArch", @"purposes", @"selection", @"size",
            @"state", @"support", @"tags", @"upgraded", @"warnings",
            @"author", @"maintainer", @"depiction", @"icon", @"longDescription",
            @"longSection", @"shortSection", @"simpleSection", @"relations", @"operator", @"relationship",
            @"clauses", @"package", @"version", @"address", @"name"
        ]);
        for (NSString *token in required)
            Expect([script rangeOfString:token].location != NSNotFound,
                   [[NSString stringWithFormat:@"facade contains %@", token] UTF8String]);
        NSArray *serializedValues(@[
            @"com.demo.app", @"Demo App",
            @"0123456789abcdef0123456789abcdef", @"Installed", @"install",
            @"1700000000", @"Package warning"
        ]);
        for (NSString *value in serializedValues)
            Expect([script rangeOfString:value].location != NSNotFound,
                   [[NSString stringWithFormat:@"facade retains fixture value %@", value] UTF8String]);
        NSArray *forbidden(@[
            @"getInstalledPackages", @"getAllSources", @"installPackages",
            @"setMetadataValue", @"UIApplication", @"openURL", @"WebScriptObject",
            @"X-Unique-ID", @"serial", @"ecid"
        ]);
        for (NSString *token in forbidden)
            Expect([script rangeOfString:token].location == NSNotFound,
                   [[NSString stringWithFormat:@"facade excludes %@", token] UTF8String]);

        Expect([CydiaPackageDepictionJavaScriptFacade
            allowlistedReachabilityURL:[NSURL URLWithString:@"https://repo.example/icon/x.png"]
            origin:origin], "same-origin reachability");
        Expect(![CydiaPackageDepictionJavaScriptFacade
            allowlistedReachabilityURL:[NSURL URLWithString:@"https://other.example/x"]
            origin:origin], "foreign-origin reachability denied");
        Expect(![CydiaPackageDepictionJavaScriptFacade
            allowlistedReachabilityURL:[NSURL URLWithString:@"http://repo.example/x"]
            origin:origin], "scheme downgrade denied");
        Expect(![CydiaPackageDepictionJavaScriptFacade
            allowlistedReachabilityURL:[NSURL URLWithString:@"https://repo.example:444/x"]
            origin:origin], "foreign port denied");
        Expect(![CydiaPackageDepictionJavaScriptFacade
            allowlistedReachabilityURL:[NSURL URLWithString:@"https://user:pass@repo.example/x"]
            origin:origin], "credential URL denied");

        CydiaPackageDepictionJavaScriptFacade *facade(
            [[CydiaPackageDepictionJavaScriptFacade alloc]
                initWithSnapshot:snapshot origin:origin packageIdentity:@"com.demo"]);
        Expect(facade != nil && ![facade isRevoked] && [facade generation] == 1,
               "initial live facade");
        WKWebViewConfiguration *configuration([[WKWebViewConfiguration alloc] init]);
        [facade installOnConfiguration:configuration];
        [facade rotateForReloadOnConfiguration:configuration];
        Expect(![facade isRevoked] && [facade generation] == 2,
               "reload rotates generation");
        [facade revokeFromConfiguration:configuration];
        Expect([facade isRevoked] && [facade generation] == 3,
               "revocation invalidates old generation");
    }
    std::cout << "[verify-depiction-facade][ ok ] bounded script, reachability and lifecycle"
              << std::endl;
    return 0;
}
