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
#include <unicode/parseerr.h>
#include <unicode/urep.h>

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
