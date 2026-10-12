/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/MessageLocaleConversion.h"
#include "Cydia/ICURuntime.hpp"
#include <cstring>

namespace {
BOOL Letters(NSString *value) {
    if (value.length == 0) return NO;
    for (NSUInteger index(0); index != value.length; ++index) {
        unichar character([value characterAtIndex:index]);
        if (!((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z'))) return NO;
    }
    return YES;
}

BOOL Region(NSString *value) {
    if (value.length == 2) return Letters(value);
    if (value.length != 3) return NO;
    for (NSUInteger index(0); index != value.length; ++index) {
        unichar character([value characterAtIndex:index]);
        if (character < '0' || character > '9') return NO;
    }
    return YES;
}

BOOL SafeIdentifier(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0 || value.length > 128) return NO;
    for (NSUInteger index(0); index != value.length; ++index) {
        unichar character([value characterAtIndex:index]);
        if (!((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') || character == '-' || character == '_')) return NO;
    }
    NSArray<NSString *> *parts([[value stringByReplacingOccurrencesOfString:@"_" withString:@"-"] componentsSeparatedByString:@"-"]);
    for (NSString *part in parts) if (part.length == 0) return NO;
    return YES;
}

NSString *CanonicalIdentifier(NSString *identifier) {
    if (!CydiaICU::Services().available() || !SafeIdentifier(identifier)) return nil;
    // Foundation understands Apple's identifiers and legacy language aliases.
    // https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/LanguageandLocaleIDs/LanguageandLocaleIDs.html
    NSString *canonical([NSLocale canonicalLanguageIdentifierFromString:identifier]);
    if (!SafeIdentifier(canonical)) return nil;
    canonical = [canonical stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    NSArray<NSString *> *parts([canonical componentsSeparatedByString:@"-"]);
    NSString *language(parts[0]);
    if (language.length < 2 || language.length > 8 || !Letters(language)) return nil;
    NSUInteger next(1);
    if (next < parts.count && [parts[next] length] == 4 && Letters(parts[next])) ++next;
    if (next < parts.count && Region(parts[next])) ++next;
    // Variants/extensions have no general POSIX equivalent. Do not silently
    // discard one and end up selecting a different language or orthography.
    if (next != parts.count) return nil;

    char parsed[ULOC_FULLNAME_CAPACITY] = {};
    UErrorCode status(U_ZERO_ERROR);
    int32_t consumed(0);
    const char *tag([canonical UTF8String]);
    int32_t length(CydiaICU::Services().localeForLanguageTag(tag, parsed, sizeof(parsed), &consumed, &status));
    // ICU permits a valid prefix followed by an invalid suffix unless checked.
    if (U_FAILURE(status) || consumed != static_cast<int32_t>(std::strlen(tag)) ||
        length <= 0 || length >= static_cast<int32_t>(sizeof(parsed))) return nil;
    char result[ULOC_FULLNAME_CAPACITY] = {};
    status = U_ZERO_ERROR;
    length = CydiaICU::Services().localeCanonicalize(parsed, result, sizeof(result), &status);
    if (U_FAILURE(status) || length <= 0 || length >= static_cast<int32_t>(sizeof(result))) return nil;
    return [NSString stringWithUTF8String:result];
}

NSString *Component(NSString *identifier, int32_t (*read)(const char *, char *, int32_t, UErrorCode *)) {
    char result[ULOC_FULLNAME_CAPACITY] = {};
    UErrorCode status(U_ZERO_ERROR);
    int32_t length(read([identifier UTF8String], result, sizeof(result), &status));
    if (U_FAILURE(status) || length < 0 || length >= static_cast<int32_t>(sizeof(result))) return nil;
    return [NSString stringWithUTF8String:result];
}

NSString *LikelyIdentifier(NSString *identifier) {
    // CLDR supplies likely script/territory instead of maintaining a country
    // table in Cydia. Use the same immutable provider as the rest of this conversion.
    // https://unicode-org.github.io/icu-docs/apidoc/released/icu4c/uloc_8h.html
    char result[ULOC_FULLNAME_CAPACITY] = {};
    UErrorCode status(U_ZERO_ERROR);
    int32_t length(CydiaICU::Services().localeLikelySubtags([identifier UTF8String], result, sizeof(result), &status));
    if (U_FAILURE(status) || length <= 0 || length >= static_cast<int32_t>(sizeof(result))) return nil;
    return [NSString stringWithUTF8String:result];
}

void Append(NSMutableArray<NSString *> *values, NSString *value) {
    if (value.length != 0 && ![values containsObject:value]) [values addObject:value];
}

NSArray<NSString *> *ConvertedLocales(NSString *appleIdentifier, BOOL includeDefaultTerritory) {
    NSString *identifier(CanonicalIdentifier(appleIdentifier));
    if (identifier == nil) return @[];
    NSString *language(Component(identifier, CydiaICU::Services().localeLanguage));
    if (language.length == 0 || [@[@"und", @"root", @"c", @"posix"] containsObject:language]) return @[];
    NSString *likely(LikelyIdentifier(identifier));
    NSString *script(likely == nil ? nil : Component(likely, CydiaICU::Services().localeScript));
    NSString *country(likely == nil ? nil : Component(likely, CydiaICU::Services().localeCountry));
    if (script.length == 0 || country.length == 0) return @[];

    NSMutableArray<NSString *> *values([NSMutableArray array]);
    // GNU gettext's Darwin conversion uses territory for Chinese scripts and
    // POSIX modifiers for other nondefault scripts. Use ICU for the territory.
    // https://github.com/coreutils/gnulib/blob/master/lib/localename-unsafe.c
    if ([language isEqualToString:@"zh"]) {
        if (![@[@"Hans", @"Hant"] containsObject:script]) return @[];
        NSString *regional([NSString stringWithFormat:@"%@_%@", language, country]);
        NSString *regionalLikely(LikelyIdentifier(regional));
        if (regionalLikely != nil && [Component(regionalLikely, CydiaICU::Services().localeScript) isEqualToString:script]) Append(values, regional);
        NSString *scriptLikely(LikelyIdentifier([NSString stringWithFormat:@"%@_%@", language, script]));
        NSString *scriptCountry(scriptLikely == nil ? nil : Component(scriptLikely, CydiaICU::Services().localeCountry));
        if (scriptCountry.length != 0) Append(values, [NSString stringWithFormat:@"%@_%@", language, scriptCountry]);
        // In particular, zh-Hant-CN must not explicitly select zh_CN or zh.
        return values;
    }

    NSString *defaultLikely(LikelyIdentifier(language));
    NSString *defaultScript(defaultLikely == nil ? nil : Component(defaultLikely, CydiaICU::Services().localeScript));
    NSString *regional([NSString stringWithFormat:@"%@_%@", language, country]);
    NSString *regionalLikely(LikelyIdentifier(regional));
    NSString *regionalScript(regionalLikely == nil ? nil : Component(regionalLikely, CydiaICU::Services().localeScript));
    BOOL defaultMatches([script isEqualToString:defaultScript]);
    BOOL regionalMatches([script isEqualToString:regionalScript]);
    NSDictionary<NSString *, NSString *> *modifiers(@{@"Latn": @"latin", @"Cyrl": @"cyrillic", @"Arab": @"arabic", @"Mong": @"mongolian"});
    NSString *modifier(defaultMatches && regionalMatches ? nil : modifiers[script]);
    if (!defaultMatches || !regionalMatches) {
        // An unsupported script is not permission to use the default script.
        if (modifier == nil) return @[];
    }
    Append(values, modifier == nil ? regional : [NSString stringWithFormat:@"%@@%@", regional, modifier]);
    if (includeDefaultTerritory) {
        // libc usually ships fewer regional locales than gettext catalogs.
        // Try a compatible language/script region before the caller's global
        // fallback, e.g. es_419 -> es_ES for tools that do not read LANGUAGE.
        NSString *scriptLikely(LikelyIdentifier([NSString stringWithFormat:@"%@_%@", language, script]));
        NSString *scriptCountry(scriptLikely == nil ? nil : Component(scriptLikely, CydiaICU::Services().localeCountry));
        if (scriptCountry.length != 0) {
            NSString *fallback([NSString stringWithFormat:@"%@_%@", language, scriptCountry]);
            NSString *fallbackLikely(LikelyIdentifier(fallback));
            BOOL fallbackMatches(fallbackLikely != nil && [Component(fallbackLikely, CydiaICU::Services().localeScript) isEqualToString:script]);
            NSString *fallbackModifier(defaultMatches && fallbackMatches ? nil : modifiers[script]);
            if (defaultMatches && fallbackMatches) Append(values, fallback);
            else if (fallbackModifier != nil) Append(values, [NSString stringWithFormat:@"%@@%@", fallback, fallbackModifier]);
        }
    }
    if (modifier != nil) Append(values, [NSString stringWithFormat:@"%@@%@", language, modifier]);
    if (defaultMatches) Append(values, language);
    return values;
}
}

NSArray<NSString *> *CydiaGettextLanguages(NSString *appleIdentifier) {
    return ConvertedLocales(appleIdentifier, NO);
}

NSArray<NSString *> *CydiaPOSIXMessageLocales(NSString *appleIdentifier) {
    return ConvertedLocales(appleIdentifier, YES);
}
