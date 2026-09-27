/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageDepictionPolicy.h"

#import <Foundation/Foundation.h>

#include <cstdlib>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    fprintf(stderr, "[PackageDepictionPolicyTests][FAIL] %s\n", [message UTF8String]);
    std::exit(1);
}

NSURL *URL(NSString *value) {
    return [NSURL URLWithString:value];
}

void ExpectDecision(CydiaPackageDepictionPolicy *policy,
                    NSString *value,
                    BOOL mainFrame,
                    BOOL initial,
                    CydiaPackageDepictionNavigationIntent intent,
                    CydiaPackageDepictionNavigationDisposition expected,
                    NSString *message) {
    Expect([policy decisionForURL:URL(value) mainFrame:mainFrame
                    initialRequest:initial intent:intent] == expected, message);
}

} // namespace


int main(void) {
    @autoreleasepool {
        NSArray *invalid(@[
            @"", @"relative/path", @"file:///etc/passwd", @"javascript:alert(1)",
            @"data:text/html,hello", @"about:blank", @"ftp://repo.example/page",
            @"https:///missing-host", @"https://user:secret@repo.example/page",
            @"https://repo.example:bad/depiction", @"https://repo.example:/depiction",
            @"https://repo.example:0/depiction", @"https://repo.example:65536/depiction",
            @"https://repo%20.example/depiction", @"https://repo%09.example/depiction",
            @"https://repo%0A.example/depiction",
        ]);
        for (NSString *value in invalid) {
            Expect([[CydiaPackageDepictionPolicy alloc] initWithURLString:value] == nil,
                   [NSString stringWithFormat:@"invalid initial URL rejected: %@", value]);
        }

        CydiaPackageDepictionPolicy *policy([[CydiaPackageDepictionPolicy alloc]
            initWithURLString:@"https://Repo.Example:443/depiction?id=1#top"]);
        Expect(policy != nil, @"credential-free HTTPS depiction accepted");
        Expect([[[policy initialURL] absoluteString]
            isEqualToString:@"https://Repo.Example:443/depiction?id=1#top"],
            @"initial URL is copied without losing path, query, or fragment");
        Expect([[CydiaPackageDepictionPolicy alloc]
            initWithURLString:@"http://repo.example/depiction"] != nil,
            @"legacy HTTP repository depiction remains supported");

        ExpectDecision(policy, @"https://Repo.Example:443/depiction?id=1#top", YES, YES,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionLoadInIsland,
            @"exact initial main document loads inside island");
        ExpectDecision(policy, @"https://repo.example/depiction?id=1#engine-normalized", YES, YES,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionLoadInIsland,
            @"host case, default port, and document fragment normalization retain initial load");
        ExpectDecision(policy, @"https://repo.example/other", YES, YES,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"initial callback cannot substitute a same-origin resource");
        ExpectDecision(policy, @"https://repo.example/depiction?id=1#top", NO, YES,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"initial load is main-frame only");

        ExpectDecision(policy, @"https://repo.example/redirected", YES, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionLoadInIsland,
            @"same-origin automatic redirect remains in island");
        ExpectDecision(policy, @"https://repo.example:444/redirected", YES, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"nondefault-port redirect cannot change main origin");
        ExpectDecision(policy, @"http://repo.example/redirected", YES, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"scheme downgrade cannot change main origin");
        ExpectDecision(policy, @"https://other.example/redirected", YES, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"cross-origin automatic main navigation is rejected");
        ExpectDecision(policy, @"https://cdn.example:0/frame", NO, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"invalid child port is rejected");
        ExpectDecision(policy, @"https://cdn%09.example/frame", NO, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"control-bearing child host is rejected");

        ExpectDecision(policy, @"https://cdn.example/frame", NO, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionLoadInIsland,
            @"credential-free repository child frame may render without authority");
        ExpectDecision(policy, @"https://user:secret@cdn.example/frame", NO, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"credential-bearing child frame is rejected");
        ExpectDecision(policy, @"javascript:alert(1)", NO, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"script navigation is never executed by the island");

        NSArray *handoff(@[
            @"https://repo.example/more", @"http://other.example/guide",
            @"cydia://package/example:iphoneos-arm64", @"apptapp://package/example",
            @"mailto:maintainer@example.com", @"itms-apps://example/app",
        ]);
        for (NSString *value in handoff) {
            ExpectDecision(policy, value, YES, NO,
                CydiaPackageDepictionNavigationIntentUserActivated,
                CydiaPackageDepictionNavigationDispositionHandOff,
                [NSString stringWithFormat:@"user link hands off to typed URL policy: %@", value]);
        }
        for (NSString *value in @[@"file:///etc/passwd", @"javascript:alert(1)",
                                   @"data:text/plain,hello", @"tel:+15551212",
                                   @"mailto:?subject=empty"]) {
            ExpectDecision(policy, value, YES, NO,
                CydiaPackageDepictionNavigationIntentUserActivated,
                CydiaPackageDepictionNavigationDispositionReject,
                [NSString stringWithFormat:@"unsafe/unreviewed handoff rejected: %@", value]);
        }
        ExpectDecision(policy, @"cydia://package/example", YES, NO,
            CydiaPackageDepictionNavigationIntentAutomatic,
            CydiaPackageDepictionNavigationDispositionReject,
            @"programmatic package route is not treated as a user action");

        Expect([policy allowsResponseURL:URL(@"https://repo.example/final") mainFrame:YES],
            @"same-origin main response allowed");
        Expect(![policy allowsResponseURL:URL(@"https://other.example/final") mainFrame:YES],
            @"cross-origin main response rejected after redirects");
        Expect([policy allowsResponseURL:URL(@"https://cdn.example/frame") mainFrame:NO],
            @"unprivileged HTTPS child response allowed");
        Expect(![policy allowsResponseURL:URL(@"file:///tmp/frame") mainFrame:NO],
            @"local child response rejected");
        Expect(![policy allowsResponseURL:URL(@"https://cdn.example:65536/frame") mainFrame:NO],
            @"out-of-range child response port rejected");

        puts("[PackageDepictionPolicyTests][ ok ] depiction URL and handoff policy");
    }
    return 0;
}
