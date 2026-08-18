#ifndef Cydia_Section_H
#define Cydia_Section_H

#include "CyteKit/UCPlatform.h"
#include "Menes/ObjectHandle.h"

#include <Foundation/Foundation.h>

@interface Section : NSObject {
    _H<NSString> name_;
    size_t row_;
    size_t count_;
    _H<NSString> localized_;
}

- (NSComparisonResult) compareByLocalized:(Section *)section;
- (instancetype) initWithName:(NSString *)name localized:(NSString *)localized;
- (instancetype) initWithName:(NSString *)name localize:(BOOL)localize;
- (instancetype) initWithName:(NSString *)name row:(size_t)row localize:(BOOL)localize;

- (NSString *) name;
- (void) setName:(NSString *)name;
- (size_t) row;
- (size_t) count;
- (void) addToRow;
- (void) addToCount;
- (void) setCount:(size_t)count;
- (NSString *) localized;

@end

#endif
