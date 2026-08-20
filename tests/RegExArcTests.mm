/* Cydia Refurbished ARC regression tests.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#include "CyteKit/RegEx.hpp"

#include <cstdio>

namespace {

bool ExpectReplacement(const char *locale, NSString *expected) {
    RegEx pattern("([a-z][a-z])(?:-[A-Za-z]*)?(_[A-Z][A-Z])?");
    if (!pattern(locale)) {
        std::fprintf(stderr, "locale did not match: %s\n", locale);
        return false;
    }

    NSString *replacement(pattern->*@"%1$@%2$@");
    if (![replacement isEqualToString:expected]) {
        std::fprintf(stderr, "unexpected replacement for %s: %s\n", locale,
                     [replacement UTF8String]);
        return false;
    }
    return true;
}

} // namespace

int main() {
    @autoreleasepool {
        for (unsigned iteration(0); iteration != 1024; ++iteration) {
            @autoreleasepool {
                if (!ExpectReplacement("zh_SG", @"zh_SG"))
                    return 1;
                if (!ExpectReplacement("en", @"en"))
                    return 1;
            }
        }
    }

    std::puts("RegEx ARC capture lifetime: PASS");
    return 0;
}
