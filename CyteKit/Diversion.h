#ifndef CyteKit_Diversion_H
#define CyteKit_Diversion_H

#include <Foundation/Foundation.h>

@interface Diversion : NSObject

- (id) initWithFrom:(NSString *)from to:(NSString *)to;

+ (void) initializeStore;
+ (void) addDiversion:(Diversion *)diversion;
+ (NSURL *) divertURL:(NSURL *)url;

@end

#endif//CyteKit_Diversion_H
