#include "CyteKit/WebFrame+Cydia.h"

#include "iPhonePrivate.h"

#include <objc/runtime.h>

@implementation WebFrame (Cydia)

- (NSString *) description {
    return [NSString stringWithFormat:@"<%s: %p, %@>", class_getName([self class]), self, [[[([self provisionalDataSource] ?: [self dataSource]) request] URL] absoluteString]];
}

- (void) cydia$updateHeight {
    [[[self frameElement] style]
        setProperty:@"height"
        value:[NSString stringWithFormat:@"%dpx",
            [[[self DOMDocument] body] scrollHeight]]
        priority:nil];
}

@end
