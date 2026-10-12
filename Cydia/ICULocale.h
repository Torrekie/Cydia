/* Cydia - iPhone UIKit Front-End for Debian APT
 * Compatibility wrapper portions Copyright (C) 2026 Torrekie
 * ICU API declarations Copyright (C) 1991-2020 Unicode, Inc. and others.
 * See Cydia/ICU-LICENSE for the ICU permission notice.
 */

#ifndef Cydia_ICULocale_H
#define Cydia_ICULocale_H

// Some Apple SDK distributions omit uloc.h while exporting these stable ICU
// APIs. Reuse the SDK ABI types and declare only the functions Cydia calls.
// The override lets host tests exercise the same declarations as those SDKs.
#if !defined(CYDIA_USE_ICU_LOCALE_DECLARATIONS) && defined(__has_include)
#if __has_include(<unicode/uloc.h>)
#include <unicode/uloc.h>
#define CYDIA_HAS_ICU_LOCALE_HEADER 1
#endif
#endif

#ifndef CYDIA_HAS_ICU_LOCALE_HEADER
#include <unicode/utypes.h>

#define ULOC_FULLNAME_CAPACITY 157

U_CAPI int32_t U_EXPORT2
uloc_getLanguage(const char *localeID, char *language, int32_t capacity, UErrorCode *status);

U_CAPI int32_t U_EXPORT2
uloc_getScript(const char *localeID, char *script, int32_t capacity, UErrorCode *status);

U_CAPI int32_t U_EXPORT2
uloc_getCountry(const char *localeID, char *country, int32_t capacity, UErrorCode *status);

U_CAPI int32_t U_EXPORT2
uloc_canonicalize(const char *localeID, char *name, int32_t capacity, UErrorCode *status);

U_CAPI int32_t U_EXPORT2
uloc_addLikelySubtags(const char *localeID, char *maximizedLocaleID, int32_t capacity, UErrorCode *status);

U_CAPI int32_t U_EXPORT2
uloc_forLanguageTag(const char *languageTag, char *localeID, int32_t capacity,
    int32_t *parsedLength, UErrorCode *status);
#endif

#endif
