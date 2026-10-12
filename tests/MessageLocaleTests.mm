/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/MessageLocale.h"
#import "Cydia/MessageLocaleConversion.h"
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <locale.h>

static void Require(BOOL condition, const char *message) {
    if (condition) return;
    std::cerr << "[verify-message-locale][FAIL] " << message << std::endl;
    std::exit(1);
}

int main() {
    @autoreleasepool {
        Require([CydiaGettextLanguages(@"fr") isEqual:@[@"fr_FR", @"fr"]],
            "a bare Apple language gains an ICU-inferred POSIX territory and catalog fallback");
        Require([CydiaGettextLanguages(@"pt") isEqual:@[@"pt_BR", @"pt"]] &&
            [CydiaGettextLanguages(@"pt-PT") isEqual:@[@"pt_PT", @"pt"]],
            "Portuguese localization identifiers preserve Brazilian and European preferences");
        Require([CydiaGettextLanguages(@"zh-Hans") isEqual:@[@"zh_CN"]] &&
            [CydiaGettextLanguages(@"zh-Hant") isEqual:@[@"zh_TW"]] &&
            [CydiaGettextLanguages(@"zh-Hant-CN") isEqual:@[@"zh_TW"]],
            "Chinese scripts remain authoritative even when a region implies a different script");
        Require([CydiaGettextLanguages(@"sr-Latn") isEqual:@[@"sr_RS@latin", @"sr@latin"]] &&
            [CydiaPOSIXMessageLocales(@"sr-Latn").firstObject isEqualToString:@"sr_RS@latin"],
            "Latin Serbian uses the Unix modifier without requesting Cyrillic catalogs");
        Require([CydiaPOSIXMessageLocales(@"es-419") isEqual:@[@"es_419", @"es_ES", @"es"]] &&
            [CydiaGettextLanguages(@"es-419") isEqual:@[@"es_419", @"es"]],
            "libc can try a supported Spanish territory without changing catalog preferences");
        Require([CydiaPOSIXMessageLocales(@"zh-Hant-HK") isEqual:@[@"zh_HK", @"zh_TW"]] &&
            [CydiaGettextLanguages(@"de_DE") isEqual:@[@"de_DE", @"de"]],
            "regional script fallbacks and Apple underscore identifiers are converted");
        Require(CydiaGettextLanguages(@"fr/../../en").count == 0 &&
            CydiaGettextLanguages(@"fr\nen").count == 0 && CydiaGettextLanguages(@"en-Qaaa").count == 0,
            "invalid identifiers and unrepresentable scripts do not select unrelated catalogs");
        for (NSString *language in @[@"ar", @"de", @"el", @"en", @"es", @"fr", @"he", @"it", @"ja", @"ko", @"nl",
            @"pl", @"pt", @"pt-PT", @"ru", @"sv", @"th", @"tr", @"vi", @"zh-Hans", @"zh-Hant"])
            Require(CydiaGettextLanguages(language).count != 0 && CydiaPOSIXMessageLocales(language).count != 0,
                "every existing Cydia localization has a Unix locale conversion");

        NSMutableArray *attempts([NSMutableArray array]);
        NSDictionary *selected(CydiaMessageLocaleEnvironment(@[@"zh_TW", @"en"], @[@"zh_TW"], ^BOOL(NSString *locale) {
            [attempts addObject:locale]; return [locale isEqualToString:@"zh_TW.UTF-8"];
        }));
        Require([selected[@"LC_MESSAGES"] isEqualToString:@"zh_TW.UTF-8"] &&
            [selected[@"LANG"] isEqualToString:@"zh_TW.UTF-8"] && attempts.count == 1,
            "an available preferred locale is used without probing unrelated locales");
        Require([selected[@"LANGUAGE"] isEqualToString:@"zh_TW:en"],
            "the supplied script-safe catalog chain is preserved without a generic Chinese fallback");

        NSDictionary *fallback(CydiaMessageLocaleEnvironment(@[@"pt_BR", @"pt", @"en"], @[@"pt_BR"], ^BOOL(NSString *locale) {
            return [locale isEqualToString:@"en_US.UTF-8"];
        }));
        Require([fallback[@"LC_MESSAGES"] isEqualToString:@"en_US.UTF-8"] &&
            [fallback[@"LANGUAGE"] isEqualToString:@"pt_BR:pt:en"],
            "an unavailable locale retains the desired gettext catalogs using an available non-C fallback");
        NSDictionary *missing(CydiaMessageLocaleEnvironment(@[@"pt_PT", @"pt"], @[@"pt_PT"], ^BOOL(NSString *) { return NO; }));
        Require([missing[@"LC_MESSAGES"] isEqualToString:@"C"] && [missing[@"LC_CTYPE"] isEqualToString:@"C"] &&
            [missing[@"LANG"] isEqualToString:@"C"],
            "a system without usable locale data falls back without inventing an installed locale");
        Require([missing[@"LANGUAGE"] isEqualToString:@"pt_PT:pt:en"], "European Portuguese keeps its own preference");
        NSDictionary *modifier(CydiaMessageLocaleEnvironment(@[@"sr@latin", @"sr"], @[@"sr_RS@latin"], ^BOOL(NSString *locale) {
            return [locale isEqualToString:@"sr_RS.UTF-8@latin"];
        }));
        Require([modifier[@"LC_MESSAGES"] isEqualToString:@"sr_RS.UTF-8@latin"], "codesets precede POSIX modifiers");
        const unichar nulCharacters[] = {'f', 'r', 0, 'e', 'n'};
        NSString *embeddedNUL([[NSString alloc] initWithCharacters:nulCharacters length:5]);
        NSDictionary *invalid(CydiaMessageLocaleEnvironment(@[@"../../bad", @"fr:de", embeddedNUL, @"fr", @"fr"], @[@"C", @"C.UTF-8", @"/bad", embeddedNUL], ^BOOL(NSString *locale) {
            Require([locale isEqualToString:@"en_US.UTF-8"], "unsafe or C locale candidates are not probed"); return YES;
        }));
        Require([invalid[@"LANGUAGE"] isEqualToString:@"fr:en"], "catalog identifiers reject embedded NULs and remain single safe tokens");

        setenv("LC_ALL", "unused-prior-value", 1);
        Require(CydiaConfigureMessageLocale(@[@"fr", @"en"], @[@"fr_FR"]), "startup locale application succeeds");
        Require(getenv("LC_ALL") == NULL && !strcmp(getenv("LC_NUMERIC"), "C") && !strcmp(getenv("LC_TIME"), "C"),
            "a parent override cannot replace the message and machine category policy");
        char *end(NULL);
        Require(strtod("12.5", &end) == 12.5 && *end == '\0' && !strcmp(localeconv()->decimal_point, "."),
            "localized messages preserve dot-decimal machine progress parsing");
        Require(!strcmp(getenv("LANGUAGE"), "fr:en"), "child tools inherit the requested catalog order");
        Require(!strcmp(getenv("LANG"), getenv("LC_MESSAGES")) && !strcmp(getenv("LANG"), getenv("LC_CTYPE")),
            "LANG follows the usable message locale for tools that do not inspect categories");
        Require(CydiaConfigureMessageLocale(@[@"zh_TW", @"en"], @[@"zh_TW"]) &&
            !strcmp(getenv("LANGUAGE"), "zh_TW:en") && !strcmp(getenv("LC_NUMERIC"), "C"),
            "a fresh startup configuration replaces inherited language values without changing machine numbers");
    }
    std::cout << "[verify-message-locale] passed" << std::endl;
    return 0;
}
