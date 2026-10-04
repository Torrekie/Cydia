/* Native-only Debian Description presentation.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef CYDIA_PACKAGE_DESCRIPTION_FORMATTING_H
#define CYDIA_PACKAGE_DESCRIPTION_FORMATTING_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

namespace CydiaPackageDescriptionFormattingDetail {

/* UIKit may wrap sooner. Keep authored/preformatted text within a readable
 * upper bound without breaking surrogate pairs, combining marks, or emoji. */
static inline NSArray<NSString *> *WrappedLines(NSString *text, BOOL prose) {
    NSMutableArray<NSString *> *lines([NSMutableArray array]);
    NSUInteger start(0);
    while (start < [text length]) {
        NSUInteger end(start);
        for (NSUInteger count(0); count != 80 && end < [text length]; ++count)
            end = NSMaxRange([text rangeOfComposedCharacterSequenceAtIndex:end]);
        NSUInteger next(end);
        if (prose && end < [text length]) {
            if ([text characterAtIndex:end] != ' ') {
                NSRange space([text rangeOfString:@" " options:NSBackwardsSearch
                    range:NSMakeRange(start, end - start)]);
                if (space.location != NSNotFound)
                    end = space.location;
            }
            next = end;
            while (next < [text length] && [text characterAtIndex:next] == ' ')
                ++next;
        }
        [lines addObject:[text substringWithRange:NSMakeRange(start, end - start)]];
        start = next;
    }
    return lines;
}

static inline NSString *Prose(NSString *text) {
    NSArray<NSString *> *words([text componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    NSMutableArray<NSString *> *nonempty([NSMutableArray array]);
    for (NSString *word in words)
        if ([word length] != 0)
            [nonempty addObject:word];
    return [nonempty componentsJoinedByString:@" "];
}

static inline void FlushProse(NSMutableString *paragraph,
                              NSMutableArray<NSString *> *output) {
    if ([paragraph length] != 0) {
        [output addObjectsFromArray:WrappedLines(paragraph, YES)];
        [paragraph setString:@""];
    }
}

} // namespace CydiaPackageDescriptionFormattingDetail

/* Pass the raw Description FIELD VALUE, including its first-line synopsis and
 * control continuation indentation, not Package.longDescription (which strips
 * indentation). This creates display text only: never replace the raw record
 * or legacy depiction API description with its result.
 * Debian Policy 5.6.13: single-space prose, extra-space verbatim text, and a
 * single-space/full-stop blank line. Foundation APIs used here predate iOS 12.
 */
static inline NSString * _Nullable CydiaPackageDescriptionForDisplay(
    NSString * _Nullable rawDescription, NSString * _Nullable shortDescription) {
    using namespace CydiaPackageDescriptionFormattingDetail;
    NSString *normalized([rawDescription stringByReplacingOccurrencesOfString:@"\r\n"
        withString:@"\n"]);
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray<NSString *> *rawLines([normalized componentsSeparatedByString:@"\n"]);
    NSMutableArray<NSString *> *output([NSMutableArray array]);
    NSMutableString *paragraph([NSMutableString string]);
    BOOL hasLongText(NO);
    for (NSUInteger index(1); index < [rawLines count]; ++index) {
        NSString *line(rawLines[index]);
        if ([line hasPrefix:@" "])
            line = [line substringFromIndex:1]; // Exactly the control continuation space.
        if ([line isEqualToString:@"."] ||
            [[line stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]] length] == 0) {
            FlushProse(paragraph, output);
            [output addObject:@""];
        } else if ([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) {
            FlushProse(paragraph, output);
            [output addObjectsFromArray:WrappedLines(line, NO)];
            hasLongText = YES;
        } else {
            NSString *prose(Prose(line));
            if ([prose length] != 0) {
                if ([paragraph length] != 0)
                    [paragraph appendString:@" "];
                [paragraph appendString:prose];
                hasLongText = YES;
            }
        }
    }
    FlushProse(paragraph, output);
    if (hasLongText)
        return [output componentsJoinedByString:@"\n"];

    NSString *fallback(Prose(shortDescription ?: @""));
    if ([fallback length] == 0 && [rawLines count] != 0)
        fallback = Prose(rawLines[0]);
    return [fallback length] == 0 ? nil :
        [WrappedLines(fallback, YES) componentsJoinedByString:@"\n"];
}

NS_ASSUME_NONNULL_END

#endif
