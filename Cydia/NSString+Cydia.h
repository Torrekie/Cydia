#ifndef Cydia_NSString_Cydia_H
#define Cydia_NSString_Cydia_H

#include <Foundation/Foundation.h>

@interface NSString (Cydia)

- (NSComparisonResult) compareByPath:(NSString *)other;
- (NSString *) stringByAddingPercentEscapesIncludingReserved;

@end

#endif//Cydia_NSString_Cydia_H
