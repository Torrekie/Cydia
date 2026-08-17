#ifndef Cydia_Collation_HPP
#define Cydia_Collation_HPP

#include "CyteKit/UCPlatform.h"
#include "Menes/ObjectHandle.h"

#include <Foundation/Foundation.h>
#include "Cydia/ICUTransliterator.h"

#include <string>
#include <vector>

typedef std::basic_string<UChar> CydiaUString;

extern _H<NSLocale> CollationLocale_;
extern _H<NSArray> CollationThumbs_;
extern std::vector<NSInteger> CollationOffset_;
extern _H<NSArray> CollationTitles_;
extern _H<NSArray> CollationStarts_;
extern UTransliterator *CollationTransl_;
extern CydiaUString CollationString_;
extern struct UReplaceableCallbacks CollationUCalls_;

#endif//Cydia_Collation_HPP
