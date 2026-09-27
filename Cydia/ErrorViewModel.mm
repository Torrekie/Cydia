/* Cydia Refurbished native error presentation.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Cydia/ErrorViewModel.h"

namespace {

static NSString *DestinationDisplayName(NSURL *URL) {
    NSString *host(URL.host);
    if ([host length] != 0)
        return host;
    NSString *scheme(URL.scheme);
    return [scheme length] == 0 ? @"" : [scheme lowercaseString];
}

static NSString *ReplaceIgnoringCase(NSString *text, NSString *value,
                                     NSString *replacement) {
    if ([value length] == 0)
        return text;
    return [text stringByReplacingOccurrencesOfString:value
        withString:replacement options:NSCaseInsensitiveSearch
        range:NSMakeRange(0, [text length])];
}

static NSString *SanitizedText(NSString *text, NSURL *URL,
                               NSString *destination, NSUInteger maximum) {
    NSString *result([text isKindOfClass:[NSString class]] ? [text copy] : @"");
    NSString *replacement([destination length] == 0 ? @"destination" : destination);

    NSString *absolute(URL.absoluteString);
    result = ReplaceIgnoringCase(result, absolute, replacement);
    result = ReplaceIgnoringCase(result, [absolute stringByRemovingPercentEncoding],
                                 replacement);
    for (NSString *sensitive in @[
            URL.user ?: @"", URL.password ?: @"", URL.query ?: @"",
            URL.fragment ?: @""])
        result = ReplaceIgnoringCase(result, sensitive, @"…");

    static NSRegularExpression *URLExpression;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        URLExpression = [NSRegularExpression
            regularExpressionWithPattern:@"(?i)(?:https?|file)://[^\\s<>\\\"']+"
            options:0 error:nil];
    });
    result = [URLExpression stringByReplacingMatchesInString:result options:0
        range:NSMakeRange(0, [result length]) withTemplate:replacement];

    NSCharacterSet *spacing([NSCharacterSet whitespaceAndNewlineCharacterSet]);
    NSCharacterSet *controls([NSCharacterSet controlCharacterSet]);
    NSMutableString *collapsed([NSMutableString string]);
    BOOL pendingSpace(NO);
    for (NSUInteger index(0); index != [result length]; ++index) {
        unichar character([result characterAtIndex:index]);
        if ([spacing characterIsMember:character] ||
            [controls characterIsMember:character]) {
            pendingSpace = [collapsed length] != 0;
            continue;
        }
        if (pendingSpace) {
            [collapsed appendString:@" "];
            pendingSpace = NO;
        }
        [collapsed appendFormat:@"%C", character];
    }

    if ([collapsed length] > maximum) {
        NSRange range([collapsed rangeOfComposedCharacterSequencesForRange:
            NSMakeRange(0, maximum)]);
        return [[collapsed substringWithRange:range]
            stringByAppendingString:@"…"];
    }
    return [collapsed copy];
}

} // namespace


@interface CydiaErrorViewModel ()
@property(nonatomic, copy, readwrite) NSString *summary;
@property(nonatomic, copy, readwrite) NSString *details;
@property(nonatomic, copy, readwrite) NSString *destinationDisplayName;
@property(nonatomic, readwrite) BOOL hasDetails;
@end


@implementation CydiaErrorViewModel

- (instancetype)initWithError:(NSError *)error destinationURL:(NSURL *)URL {
    if ((self = [super init]) != nil) {
        _destinationDisplayName = [DestinationDisplayName(URL) copy];
        NSString *summary(SanitizedText(error.localizedDescription, URL,
            _destinationDisplayName, 512));
        if ([summary length] == 0)
            summary = SanitizedText(error.domain, nil, @"", 128);
        _summary = [summary length] == 0 ? @"Error" : [summary copy];

        NSString *domain(SanitizedText(error.domain, nil, @"", 128));
        if ([domain length] == 0)
            domain = @"Error";
        NSString *destinationLine([_destinationDisplayName length] == 0 ? @"" :
            [@"\n" stringByAppendingString:_destinationDisplayName]);
        _details = [[NSString stringWithFormat:@"%@ (%ld)%@", domain,
            (long)error.code, destinationLine] copy];
        _hasDetails = [_details length] != 0;
    }
    return self;
}

@end
