/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 */

#include <Foundation/Foundation.h>

#include "Menes/yieldToSelector.h"

static void Require(BOOL condition, NSString *message) {
    if (condition)
        return;
    NSLog(@"[fail] %@", message);
    exit(1);
}

@interface YieldToSelectorFixture : NSObject
@property(nonatomic, assign) BOOL invokedOffMainThread;
@property(nonatomic, strong) id observedObject;
@end

@implementation YieldToSelectorFixture

- (void) recordObject:(id)object {
    self.invokedOffMainThread = ![NSThread isMainThread];
    self.observedObject = object;
}

- (NSString *) echoObject:(NSString *)object {
    self.invokedOffMainThread = ![NSThread isMainThread];
    return [@"echo:" stringByAppendingString:object];
}

- (BOOL) scalarResult:(id)object {
    self.invokedOffMainThread = ![NSThread isMainThread];
    self.observedObject = object;
    return YES;
}

- (NSString *) objectWithoutArgument {
    self.invokedOffMainThread = ![NSThread isMainThread];
    return @"no-argument";
}

@end

int main(void) {
    @autoreleasepool {
        YieldToSelectorFixture *fixture([YieldToSelectorFixture new]);

        id voidResult([fixture yieldToSelector:@selector(recordObject:)
                                    withObject:@"void"]);
        Require(voidResult == nil, @"void selector returns nil");
        Require([fixture.observedObject isEqual:@"void"],
                @"void selector receives its object");
        Require(fixture.invokedOffMainThread,
                @"void selector executes on the worker thread");

        id objectResult([fixture yieldToSelector:@selector(echoObject:)
                                      withObject:@"value"]);
        Require([objectResult isEqual:@"echo:value"],
                @"object selector preserves its return value");

        id scalarResult([fixture yieldToSelector:@selector(scalarResult:)
                                      withObject:@"scalar"]);
        Require(scalarResult == nil,
                @"non-object selector completes without treating scalar bits as an object");
        Require([fixture.observedObject isEqual:@"scalar"],
                @"non-object selector still executes");

        id noArgument([fixture yieldToSelector:@selector(objectWithoutArgument)]);
        Require([noArgument isEqual:@"no-argument"],
                @"zero-argument object selector remains supported");

        NSLog(@"[ok] yieldToSelector return ABI");
    }
    return 0;
}
