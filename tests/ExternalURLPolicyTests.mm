/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ExternalURLPolicy.h"

#include <cstdlib>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    fprintf(stderr, "[ExternalURLPolicyTests][FAIL] %s\n", [message UTF8String]);
    std::exit(1);
}

NSURL *URL(NSString *value) {
    return [NSURL URLWithString:value];
}

void ExpectWebValidity(NSString *value, BOOL expected) {
    Expect(CydiaExternalURLIsValidWebURL(URL(value)) == expected,
        [NSString stringWithFormat:@"web URL validity %@ (%@)", value,
            expected ? @"allowed" : @"rejected"]);
}

void ExpectKind(NSString *value, CydiaExternalURLPresentationKind kind,
                BOOL confirmation) {
    CydiaExternalURLPolicy *policy([[CydiaExternalURLPolicy alloc]
        initWithURL:URL(value)]);
    Expect(policy != nil, [NSString stringWithFormat:@"accepted %@", value]);
    Expect([policy presentationKind] == kind,
        [NSString stringWithFormat:@"presentation kind %@", value]);
    Expect([policy requiresConfirmation] == confirmation,
        [NSString stringWithFormat:@"confirmation %@", value]);
    Expect([[[policy destinationURL] absoluteString] isEqualToString:value],
        [NSString stringWithFormat:@"destination preserved %@", value]);
}

} // namespace


int main(void) {
    @autoreleasepool {
        NSArray *invalid(@[
            @"", @"relative/path", @"file:///etc/passwd",
            @"javascript:alert(1)", @"data:text/plain,hello",
            @"custom://device-command", @"https:///missing-host",
            @"https://user:secret@example.com/", @"https://example.com:bad/",
            @"https://example.com:/", @"https://example.com:0/",
            @"https://example.com:65536/", @"https://exa%20mple.com/",
            @"https://exa%09mple.com/", @"https://exa%0Ample.com/",
            @"mailto:", @"mailto:?subject=empty", @"mailto:%20", @"itms:",
            @"itms-apps://",
        ]);
        for (NSString *value in invalid) {
            Expect([[CydiaExternalURLPolicy alloc] initWithURL:URL(value)] == nil,
                [NSString stringWithFormat:@"rejected %@", value]);
            Expect(CydiaExternalURLRouteURL(URL(value)) == nil,
                [NSString stringWithFormat:@"invalid route wrapper %@", value]);
            ExpectWebValidity(value, NO);
        }
        Expect([[CydiaExternalURLPolicy alloc] initWithURL:nil] == nil,
            @"nil URL rejected");
        ExpectWebValidity(@"https://example.com/guide", YES);
        ExpectWebValidity(@"http://127.0.0.1:65535/guide", YES);

        ExpectKind(@"https://example.com/guide?x=1#top",
            CydiaExternalURLPresentationKindSafari, NO);
        ExpectKind(@"http://127.0.0.1:8001/guide",
            CydiaExternalURLPresentationKindSafari, NO);
        ExpectKind(@"mailto:maintainer@example.com?subject=Package",
            CydiaExternalURLPresentationKindSystem, NO);
        for (NSString *value in @[
            @"itms://itunes.apple.com/app/id1",
            @"itmss://itunes.apple.com/app/id1",
            @"itms-apps://itunes.apple.com/app/id1",
            @"itms-appss://itunes.apple.com/app/id1",
            @"https://itunes.apple.com/app/id1",
            @"http://itunes.apple.com/app/id1",
        ])
            ExpectKind(value, CydiaExternalURLPresentationKindAppStore, YES);
        ExpectKind(@"https://itunes.apple.com:444/app/id1",
            CydiaExternalURLPresentationKindSafari, NO);

        NSURL *destination(URL(@"https://example.com/a%20b?q=x/y#fragment"));
        NSURL *route(CydiaExternalURLRouteURL(destination));
        Expect(route != nil && [[[route scheme] lowercaseString] isEqualToString:@"cydia"],
            @"valid destination receives cydia wrapper");
        NSString *prefix(@"cydia://url/");
        NSString *absolute([route absoluteString]);
        Expect([absolute hasPrefix:prefix], @"wrapper has canonical command");
        NSString *encoded([absolute substringFromIndex:[prefix length]]);
        Expect([[encoded stringByRemovingPercentEncoding]
            isEqualToString:[destination absoluteString]],
            @"wrapper round-trips escapes, query, and fragment exactly once");

        puts("[ExternalURLPolicyTests][ ok ] external URL validation and presentation");
    }
    return 0;
}
