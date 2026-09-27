/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibility.h"

#include <cstdlib>
#include <iostream>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (!condition) {
        std::cerr << "[verify-legacy-ui-format][fail] "
                  << [message UTF8String] << std::endl;
        std::exit(1);
    }
}

NSString *Format(id format, id values) {
    return CydiaLegacyUICompatibilityFormatString(format, values);
}

NSString *Repeated(unichar character, NSUInteger length) {
    return [@"" stringByPaddingToLength:length
        withString:[NSString stringWithCharacters:&character length:1]
        startingAtIndex:0];
}

} // namespace

int main() {
    @autoreleasepool {
        id undefined([CydiaLegacyUIUndefinedValue value]);

        Expect([Format(@"hello %@", @[@"world"]) isEqualToString:@"hello world"],
               @"NSString substitutions retain their text");
        Expect([Format(@"number=%@", @[@42]) isEqualToString:@"number=42"],
               @"NSNumber substitutions use their Foundation description");
        Expect([Format(@"null=%@ undefined=%@", @[ [NSNull null], undefined])
                    isEqualToString:@"null=<null> undefined=undefined"],
               @"NSNull and undefined retain deterministic descriptions");
        Expect([Format(@"100%% %@ %%", @[@"done"])
                    isEqualToString:@"100% done %"],
               @"escaped percent signs do not consume an argument");
        Expect([Format(@"%@", [NSOrderedSet orderedSetWithObjects:@"ordered", nil])
                    isEqualToString:@"ordered"],
               @"ordered-set sequences are accepted");
        Expect([Format(@"", @[]) isEqualToString:@""],
               @"an empty format with no values is valid");

        Expect(Format(nil, @[]) == nil,
               @"nil format is rejected");
        Expect(Format(@42, @[]) == nil,
               @"non-string format is rejected");
        Expect(Format(@"literal", nil) == nil,
               @"missing argument sequence is rejected");
        Expect(Format(@"%@", @[]) == nil,
               @"too few values are rejected");
        Expect(Format(@"literal", @[@"extra"]) == nil,
               @"too many values are rejected");
        Expect(Format(@"%", @[]) == nil,
               @"trailing percent is rejected");
        Expect(Format(@"%s", @[@"value"]) == nil,
               @"numeric/string printf grammar is rejected");
        Expect(Format(@"%d", @[@42]) == nil,
               @"numeric conversion grammar is rejected");
        Expect(Format(@"%1$@", @[@"value"]) == nil,
               @"positional printf grammar is rejected");
        Expect(Format(@"%02@", @[@"value"]) == nil,
               @"width and flag grammar is rejected");
        Expect(Format(@"%@%@", @[@"one"]) == nil,
               @"placeholder count mismatch is rejected");
        Expect(Format(@"%@", @[[NSDate date]]) == nil,
               @"arbitrary object values are rejected");
        Expect(Format(@"%@", @[@[]]) == nil,
               @"collection values are rejected");

        Expect(Format(Repeated('x', 4097), @[]) == nil,
               @"oversized format text is rejected");
        Expect(Format(@"%@", @[Repeated('x', 4097)]) == nil,
               @"oversized substitution text is rejected");

        NSMutableArray *tooMany([NSMutableArray arrayWithCapacity:65]);
        for (NSUInteger index = 0; index != 65; ++index)
            [tooMany addObject:@"x"];
        Expect(Format(@"literal", tooMany) == nil,
               @"oversized argument count is rejected");

        NSMutableString *longExpansion([NSMutableString string]);
        NSMutableArray *expansionValues([NSMutableArray arrayWithCapacity:64]);
        for (NSUInteger index = 0; index != 64; ++index) {
            [longExpansion appendString:@"%@"];
            [expansionValues addObject:Repeated('x', 4096)];
        }
        Expect(Format(longExpansion, expansionValues) == nil,
               @"expanded output beyond the cap is rejected");

        std::cout << "[verify-legacy-ui-format][ ok ] bounded %%/%@ Foundation slice"
                  << std::endl;
    }
    return 0;
}
