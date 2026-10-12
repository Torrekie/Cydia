/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_ICURuntime_HPP
#define Cydia_ICURuntime_HPP

#include "Cydia/ICULocale.h"
#include "Cydia/ICUTransliterator.h"
#include <unicode/uchar.h>
#include <unicode/uregex.h>
#include <unicode/ustring.h>
#include <string>

namespace CydiaICU {

enum class ProviderKind { Unavailable, Bootstrap, Apple, Private };

/* Only stable ICU C signatures cross this boundary. A selected table and its
 * libraries live for the process lifetime; ICU objects must never move between
 * providers. Foundation/UIKit retain their own ICU dependency. */
struct API {
    ProviderKind kind = ProviderKind::Unavailable;
    std::string library;
    std::string symbolSuffix;
    UVersionInfo version = {};

    decltype(&u_errorName) errorName = nullptr;
    decltype(&u_getVersion) getVersion = nullptr;
    decltype(&uloc_getLanguage) localeLanguage = nullptr;
    decltype(&uloc_getScript) localeScript = nullptr;
    decltype(&uloc_getCountry) localeCountry = nullptr;
    decltype(&uloc_canonicalize) localeCanonicalize = nullptr;
    decltype(&uloc_addLikelySubtags) localeLikelySubtags = nullptr;
    decltype(&uloc_forLanguageTag) localeForLanguageTag = nullptr;
    decltype(&uregex_openC) regexOpen = nullptr;
    decltype(&uregex_close) regexClose = nullptr;
    decltype(&uregex_groupCount) regexGroupCount = nullptr;
    decltype(&uregex_group) regexGroup = nullptr;
    decltype(&uregex_setText) regexSetText = nullptr;
    decltype(&uregex_matches) regexMatches = nullptr;
    decltype(&utrans_openU) transliteratorOpen = nullptr;
    decltype(&utrans_trans) transliterate = nullptr;
    decltype(&utrans_close) transliteratorClose = nullptr;
    decltype(&u_strFromUTF8WithSub) fromUTF8 = nullptr;
    decltype(&u_strToUTF8WithSub) toUTF8 = nullptr;
    decltype(&u_toupper) uppercase = nullptr;

    bool available() const { return kind != ProviderKind::Unavailable; }
};

/* Call before locale conversion or constructing regex objects. Directories
 * come from the installed package layout, never PATH or DYLD_* variables.
 * Private ICU is optional, uses the _cydia library/symbol suffix, and is only
 * considered when both the bootstrap and Apple providers are unavailable.
 * A second call cannot replace live handles and returns false. */
bool Initialize(const std::string &bootstrapLibraryDirectory,
                const std::string &privateLibraryDirectory);
const API &Services();

/* UIKit's section titles/thresholds and CoreFoundation's comparator belong
 * together with Apple's transliteration and case mapping. Switching only one
 * part can produce unsorted sections, so this service is always Apple-owned. */
const API &AppleCollation();

} // namespace CydiaICU
#endif
