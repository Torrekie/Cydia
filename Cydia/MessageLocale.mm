/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/MessageLocale.h"
#include <cstdlib>
#include <cstring>
#include <locale.h>
#include <xlocale.h>

namespace {
BOOL LanguageIdentifier(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0 || value.length > 128) return NO;
    const char *bytes([value UTF8String]);
    if (bytes == NULL || std::strlen(bytes) != [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return NO;
    for (const unsigned char *character(reinterpret_cast<const unsigned char *>(bytes)); *character; ++character)
        if (!((*character >= 'a' && *character <= 'z') || (*character >= 'A' && *character <= 'Z') ||
            (*character >= '0' && *character <= '9') || *character == '_' || *character == '-' || *character == '@')) return NO;
    return ![value isEqualToString:@"C"] && ![value isEqualToString:@"POSIX"];
}
NSString *UTF8Locale(NSString *identifier) {
    NSRange modifier([identifier rangeOfString:@"@"]);
    if (modifier.location == NSNotFound) return [identifier stringByAppendingString:@".UTF-8"];
    return [NSString stringWithFormat:@"%@.UTF-8%@", [identifier substringToIndex:modifier.location],
        [identifier substringFromIndex:modifier.location]];
}
BOOL Available(NSString *name) {
    locale_t candidate(newlocale(LC_MESSAGES_MASK | LC_CTYPE_MASK, [name UTF8String], (locale_t)0));
    if (candidate == (locale_t)0) return NO;
    freelocale(candidate); return YES;
}
}

NSDictionary<NSString *, NSString *> *CydiaMessageLocaleEnvironment(
    NSArray<NSString *> *catalogLanguages, NSArray<NSString *> *localeCandidates,
    BOOL (^available)(NSString *locale)) {
    NSMutableArray<NSString *> *languages([NSMutableArray array]);
    for (NSString *language in catalogLanguages)
        if (LanguageIdentifier(language) && ![languages containsObject:language]) [languages addObject:language];
    if (![languages containsObject:@"en"]) [languages addObject:@"en"];

    NSMutableArray<NSString *> *candidates([NSMutableArray array]);
    for (NSString *candidate in localeCandidates) {
        if (!LanguageIdentifier(candidate)) continue;
        NSString *name(UTF8Locale(candidate));
        if (![candidates containsObject:name]) [candidates addObject:name];
    }
    // GNU gettext disables LANGUAGE under C, POSIX and C.UTF-8. A usable
    // non-C fallback lets its catalog preference still select the UI language.
    if (![candidates containsObject:@"en_US.UTF-8"]) [candidates addObject:@"en_US.UTF-8"];
    NSString *locale(@"C");
    for (NSString *candidate in candidates)
        if (available != nil ? available(candidate) : Available(candidate)) { locale = candidate; break; }
    return @{@"LANG": locale, @"LANGUAGE": [languages componentsJoinedByString:@":"],
        @"LC_MESSAGES": locale, @"LC_CTYPE": locale, @"LC_NUMERIC": @"C", @"LC_TIME": @"C",
        @"LC_COLLATE": @"C", @"LC_MONETARY": @"C"};
}

BOOL CydiaConfigureMessageLocale(NSArray<NSString *> *catalogLanguages,
    NSArray<NSString *> *localeCandidates) {
    NSDictionary<NSString *, NSString *> *environment(CydiaMessageLocaleEnvironment(catalogLanguages, localeCandidates, nil));
    BOOL success(unsetenv("LC_ALL") == 0);
    for (NSString *name in environment)
        if (setenv([name UTF8String], [environment[name] UTF8String], 1) != 0) success = NO;
    // Localize messages without changing machine numbers, dates or sorting.
    if (setlocale(LC_ALL, "C") == NULL) success = NO;
    if (setlocale(LC_CTYPE, [environment[@"LC_CTYPE"] UTF8String]) == NULL ||
        setlocale(LC_MESSAGES, [environment[@"LC_MESSAGES"] UTF8String]) == NULL) {
        setlocale(LC_CTYPE, "C"); setlocale(LC_MESSAGES, "C");
        for (NSString *name in @[@"LANG", @"LC_CTYPE", @"LC_MESSAGES"]) setenv([name UTF8String], "C", 1);
        success = NO;
    }
    return success;
}
