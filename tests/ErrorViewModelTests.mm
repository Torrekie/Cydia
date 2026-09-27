/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Cydia/ErrorViewModel.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"[ErrorViewModelTests][FAIL] %@", message);
        exit(1);
    }
}

static void RequireAbsent(NSString *text, NSString *needle) {
    Require([text rangeOfString:needle options:NSCaseInsensitiveSearch].location ==
        NSNotFound, [NSString stringWithFormat:@"diagnostic leaked %@", needle]);
}

int main(void) {
    @autoreleasepool {
        NSURL *URL([NSURL URLWithString:
            @"https://user:secret@example.com/private/index?token=abc123#frag"]);
        NSMutableString *description([NSMutableString stringWithString:
            @"Could not load https://user:secret@example.com/private/index?token=abc123#frag\n\tplease retry\x01"]);
        NSError *error([NSError errorWithDomain:NSURLErrorDomain
            code:NSURLErrorNotConnectedToInternet userInfo:@{
                NSLocalizedDescriptionKey: description,
                NSURLErrorFailingURLStringErrorKey: URL.absoluteString,
            }]);
        CydiaErrorViewModel *model([[CydiaErrorViewModel alloc]
            initWithError:error destinationURL:URL]);

        Require([model.destinationDisplayName isEqualToString:@"example.com"],
            @"destination display name is host-only");
        Require([model.summary containsString:@"example.com"],
            @"summary retains a safe destination name");
        for (NSString *secret in @[@"user", @"secret", @"private", @"token",
                                   @"abc123", @"frag", @"https://"])
            RequireAbsent(model.summary, secret);
        Require([model.summary rangeOfCharacterFromSet:
            [NSCharacterSet controlCharacterSet]].location == NSNotFound,
            @"summary contains control characters");
        Require([model.details isEqualToString:
            @"NSURLErrorDomain (-1009)\nexample.com"],
            @"details changed their bounded domain/code/host schema");
        Require(model.hasDetails, @"technical details are missing");

        [description setString:@"mutated after snapshot"];
        RequireAbsent(model.summary, @"mutated");
        Require([model.summary containsString:@"please retry"],
            @"summary does not own its source text");

        NSError *fileError([NSError errorWithDomain:@"FixtureDomain" code:23
            userInfo:@{NSLocalizedDescriptionKey:
                @"file:///private/var/mobile/Library/secret.plist failed"}]);
        CydiaErrorViewModel *fileModel([[CydiaErrorViewModel alloc]
            initWithError:fileError destinationURL:
                [NSURL fileURLWithPath:@"/private/var/mobile/Library/secret.plist"]]);
        Require([fileModel.destinationDisplayName isEqualToString:@"file"],
            @"file destination exposes more than its scheme");
        RequireAbsent(fileModel.summary, @"private");
        RequireAbsent(fileModel.summary, @"secret.plist");

        NSMutableString *longText([NSMutableString string]);
        for (NSUInteger i(0); i != 700; ++i)
            [longText appendString:@"x"];
        CydiaErrorViewModel *longModel([[CydiaErrorViewModel alloc]
            initWithError:[NSError errorWithDomain:@"Long" code:1 userInfo:@{
                NSLocalizedDescriptionKey: longText,
            }] destinationURL:nil]);
        Require([longModel.summary length] <= 513,
            @"summary length is not bounded");

        NSLog(@"[ErrorViewModelTests][ ok ] sanitized immutable native diagnostics");
    }
    return 0;
}
