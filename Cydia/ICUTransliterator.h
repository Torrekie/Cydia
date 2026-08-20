/* Cydia - iPhone UIKit Front-End for Debian APT
 * Compatibility wrapper portions Copyright (C) 2026  Torrekie
 * ICU API declarations Copyright (C) 1991-2020 Unicode, Inc. and others.
 * See Cydia/ICU-LICENSE for the ICU permission notice.
 */

#ifndef Cydia_ICUTransliterator_H
#define Cydia_ICUTransliterator_H

/*
 * Apple ships the ICU C headers used by Cydia, but the iPhoneOS 14.5 SDK
 * does not expose unicode/utrans.h.  Keep the small part of that API we use
 * here while reusing the SDK's ABI definitions for the surrounding types.
 */
#if defined(__has_include)
#if __has_include(<unicode/utrans.h>)
#include <unicode/utrans.h>
#define CYDIA_HAS_ICU_TRANSLITERATOR_HEADER 1
#endif
#endif

#ifndef CYDIA_HAS_ICU_TRANSLITERATOR_HEADER
#include <unicode/utypes.h>
#include <unicode/parseerr.h>
#if defined(__has_include)
#if __has_include(<unicode/urep.h>)
#include <unicode/urep.h>
#define CYDIA_HAS_ICU_REPLACEABLE_HEADER 1
#endif
#endif

/* Theos' iPhoneOS SDK exports ICU's ABI but omits the deprecated urep.h.
 * Transliteration only passes these values through to ICU, so an opaque
 * declaration is sufficient and keeps the SDK-independent boundary narrow. */
#ifndef CYDIA_HAS_ICU_REPLACEABLE_HEADER
typedef void *UReplaceable;
typedef struct UReplaceableCallbacks {
    int32_t (*length)(const UReplaceable *rep);
    UChar (*charAt)(const UReplaceable *rep, int32_t offset);
    UChar32 (*char32At)(const UReplaceable *rep, int32_t offset);
    void (*replace)(UReplaceable *rep,
                    int32_t start,
                    int32_t limit,
                    const UChar *text,
                    int32_t textLength);
    void (*extract)(UReplaceable *rep,
                    int32_t start,
                    int32_t limit,
                    UChar *dst);
    void (*copy)(UReplaceable *rep,
                 int32_t start,
                 int32_t limit,
                 int32_t dest);
} UReplaceableCallbacks;
#endif

U_CDECL_BEGIN

typedef void *UTransliterator;

typedef enum UTransDirection {
    UTRANS_FORWARD,
    UTRANS_REVERSE
} UTransDirection;

U_CAPI UTransliterator *U_EXPORT2
utrans_openU(const UChar *id,
             int32_t idLength,
             UTransDirection dir,
             const UChar *rules,
             int32_t rulesLength,
             UParseError *parseError,
             UErrorCode *pErrorCode);

U_CAPI void U_EXPORT2
utrans_trans(const UTransliterator *trans,
             UReplaceable *rep,
             const UReplaceableCallbacks *repFunc,
             int32_t start,
             int32_t *limit,
             UErrorCode *status);

U_CDECL_END
#endif

#endif
