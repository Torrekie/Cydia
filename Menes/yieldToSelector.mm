/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
*/

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#include "CyteKit/UCPlatform.h"

#include "Menes/yieldToSelector.h"

@implementation NSObject (MenesYieldToSelector)

- (void) doNothing {
}

- (void) _yieldToContext:(NSMutableArray *)context {
    @autoreleasepool {

    SEL selector(reinterpret_cast<SEL>([[context objectAtIndex:0] pointerValue]));
    id storedObject([context objectAtIndex:1]);
    id object(storedObject == [NSNull null] ? nil : storedObject);
    volatile bool &stopped(*reinterpret_cast<bool *>([[context objectAtIndex:2] pointerValue]));

    NSMethodSignature *signature([self methodSignatureForSelector:selector]);
    if (signature == nil)
        [self doesNotRecognizeSelector:selector];

    NSUInteger arguments([signature numberOfArguments]);
    if (arguments > 3)
        [NSException raise:NSInvalidArgumentException
                    format:@"yieldToSelector supports at most one object argument: %@",
                           NSStringFromSelector(selector)];

    NSInvocation *invocation([NSInvocation invocationWithMethodSignature:signature]);
    [invocation setTarget:self];
    [invocation setSelector:selector];
    if (arguments == 3) {
        __unsafe_unretained id argument(object);
        [invocation setArgument:&argument atIndex:2];
    }
    [invocation retainArguments];
    [invocation invoke];

    id value(nil);
    const char *returnType([signature methodReturnType]);
    while (*returnType == 'r' || *returnType == 'n' || *returnType == 'N' ||
           *returnType == 'o' || *returnType == 'O' || *returnType == 'R' ||
           *returnType == 'V')
        ++returnType;
    if ([signature methodReturnLength] != 0 &&
        (*returnType == '@' || *returnType == '#')) {
        __unsafe_unretained id result(nil);
        [invocation getReturnValue:&result];
        value = result;
    }

    [context removeAllObjects];
    if (value != nil)
        [context addObject:value];

    stopped = true;

    [self
        performSelectorOnMainThread:@selector(doNothing)
        withObject:nil
        waitUntilDone:NO
    ];

    }
}

- (id) yieldToSelector:(SEL)selector withObject:(id)object {
    volatile bool stopped(false);

    NSMutableArray *context([NSMutableArray arrayWithObjects:
        [NSValue valueWithPointer:selector],
        object ?: [NSNull null],
        [NSValue valueWithPointer:const_cast<bool *>(&stopped)],
    nil]);

    NSThread *thread([[NSThread alloc]
        initWithTarget:self
        selector:@selector(_yieldToContext:)
        object:context
    ]);

    [thread start];

    NSRunLoop *loop([NSRunLoop currentRunLoop]);
    NSDate *future([NSDate distantFuture]);
    NSString *mode([loop currentMode] ?: NSDefaultRunLoopMode);

    while (!stopped && [loop runMode:mode beforeDate:future]);

    return [context count] == 0 ? nil : [context objectAtIndex:0];
}

- (id) yieldToSelector:(SEL)selector {
    return [self yieldToSelector:selector withObject:nil];
}

@end
