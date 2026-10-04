/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageDescriptionFormatting.h"

#include <cstdlib>

namespace {
void Expect(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "[PackageDescriptionFormattingTests][FAIL] %s\n", message);
        std::exit(1);
    }
}

void ExpectText(NSString *raw, NSString *fallback, NSString *expected,
                const char *message) {
    NSString *actual(CydiaPackageDescriptionForDisplay(raw, fallback));
    Expect(actual == expected || [actual isEqualToString:expected], message);
}

void ExpectBoundedUnicode(NSString *text, const char *message) {
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSUInteger count(0);
        for (NSUInteger index(0); index < [line length]; ++count)
            index = NSMaxRange([line rangeOfComposedCharacterSequenceAtIndex:index]);
        Expect(count <= 80, message);
    }
}
} // namespace

int main() {
    @autoreleasepool {
        ExpectText(@"Summary\n First prose line\n continues here.\n .\n Second paragraph.",
            @"Summary", @"First prose line continues here.\n\nSecond paragraph.",
            "control continuation prose reflows and dot separates paragraphs");
        ExpectText(@"Summary\n Prose.\n  code one\n    nested code\n  code two\n Next prose\n continues.",
            @"Summary", @"Prose.\n code one\n   nested code\n code two\nNext prose continues.",
            "one continuation space removed while relative indentation and code lines survive");
        ExpectText(@"Summary\n .\n .\n Paragraph\n .", @"Summary",
            @"\n\nParagraph\n", "explicit blank lines are not collapsed");
        ExpectText(@"Summary\r\n First line\r\n second.", @"Summary",
            @"First line second.", "CRLF descriptions are normalized");
        ExpectText(@"Summary", @"Short fallback", @"Short fallback",
            "summary-only descriptions use short description fallback");
        ExpectText(@"Summary\n .", nil, @"Summary",
            "blank-only long text uses the raw summary when needed");
        ExpectText(@"Summary\n    \n .", @"Short fallback", @"Short fallback",
            "whitespace-only continuation is not a long description");
        ExpectText(nil, @"Short only", @"Short only", "missing raw field falls back");
        ExpectText(nil, nil, nil, "missing descriptions stay absent");

        NSMutableString *words([NSMutableString stringWithString:@"Summary\n "]);
        for (NSUInteger count(0); count != 30; ++count)
            [words appendString:@"readable "];
        NSString *wrapped(CydiaPackageDescriptionForDisplay(words, nil));
        ExpectBoundedUnicode(wrapped, "prose is capped at 80 composed characters");
        Expect([[wrapped stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
            isEqualToString:CydiaPackageDescriptionFormattingDetail::Prose(
                [words substringFromIndex:9])],
            "prose wraps at word boundaries without losing words");

        NSString *grapheme(@"e\u0301👩🏽‍💻");
        NSMutableString *unicode([NSMutableString stringWithString:@"Summary\n "]);
        for (NSUInteger count(0); count != 90; ++count)
            [unicode appendString:grapheme];
        wrapped = CydiaPackageDescriptionForDisplay(unicode, nil);
        ExpectBoundedUnicode(wrapped, "long Unicode words wrap safely");
        Expect([[wrapped stringByReplacingOccurrencesOfString:@"\n" withString:@""]
            isEqualToString:[unicode substringFromIndex:9]],
            "Unicode hard wrapping preserves every grapheme");
        for (NSString *line in [wrapped componentsSeparatedByString:@"\n"])
            Expect([line hasPrefix:@"e\u0301"] && [line hasSuffix:@"👩🏽‍💻"],
                "combining marks and joined emoji are not split");

        NSMutableString *preformatted([NSMutableString stringWithString:@"Summary\n  "]);
        for (NSUInteger count(0); count != 81; ++count)
            [preformatted appendString:@"中"];
        wrapped = CydiaPackageDescriptionForDisplay(preformatted, nil);
        ExpectBoundedUnicode(wrapped, "preformatted long lines hard wrap safely");
        Expect([[wrapped stringByReplacingOccurrencesOfString:@"\n" withString:@""]
            isEqualToString:[preformatted substringFromIndex:9]],
            "preformatted wrapping does not trim indentation");

        NSMutableString *raw([NSMutableString stringWithString:@"Summary\n  code\n .\n Text."]);
        NSString *original([raw copy]);
        (void)CydiaPackageDescriptionForDisplay(raw, @"Summary");
        Expect([raw isEqualToString:original], "raw input used by depiction APIs is unchanged");
        puts("[PackageDescriptionFormattingTests][ ok ] Debian Description display formatting");
    }
    return 0;
}
