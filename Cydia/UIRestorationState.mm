/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/UIRestorationState.h"

namespace {

BOOL IsIntegerNumber(NSNumber *number) {
    if (![number isKindOfClass:[NSNumber class]])
        return NO;
    const char *type([number objCType]);
    if (type == NULL || type[0] == '\0')
        return NO;
    switch (type[0]) {
        case 'c': case 'i': case 's': case 'l': case 'q':
        case 'C': case 'I': case 'S': case 'L': case 'Q':
            return YES;
        default:
            return NO;
    }
}

BOOL IsRouteStack(NSArray *stack) {
    if (![stack isKindOfClass:[NSArray class]] || [stack count] == 0)
        return NO;
    for (id route in stack)
        if (![route isKindOfClass:[NSString class]] || [(NSString *) route length] == 0)
            return NO;
    return YES;
}

} // namespace

@interface CydiaUIRestorationState ()
- (instancetype) initWithInterfaceState:(NSArray *)interfaceState
                           selectedIndex:(NSUInteger)selectedIndex
                              lastClosed:(NSDate *)lastClosed;
@end

@implementation CydiaUIRestorationState

- (instancetype) initWithInterfaceState:(NSArray *)interfaceState
                           selectedIndex:(NSUInteger)selectedIndex
                              lastClosed:(NSDate *)lastClosed {
    if ((self = [super init]) != nil) {
        _interfaceState = [interfaceState copy];
        _selectedIndex = selectedIndex;
        _lastClosed = [lastClosed copy];
    }
    return self;
}

+ (instancetype) stateWithDictionary:(NSDictionary *)dictionary
                       standardStacks:(NSArray *)standardStacks {
    if (![dictionary isKindOfClass:[NSDictionary class]] ||
        ![standardStacks isKindOfClass:[NSArray class]] ||
        [standardStacks count] == 0)
        return nil;

    id rawStacks([dictionary objectForKey:@"InterfaceState"]);
    id rawIndex([dictionary objectForKey:@"InterfaceIndex"]);
    id rawClosed([dictionary objectForKey:@"LastClosed"]);
    if (![rawStacks isKindOfClass:[NSArray class]] ||
        !IsIntegerNumber(rawIndex) ||
        (rawClosed != nil && ![rawClosed isKindOfClass:[NSDate class]]) ||
        [rawStacks count] != [standardStacks count])
        return nil;

    const long long signedIndex([rawIndex longLongValue]);
    if (signedIndex < 0 || (unsigned long long) signedIndex >= [standardStacks count])
        return nil;

    for (NSUInteger index(0); index != [standardStacks count]; ++index) {
        id standard([standardStacks objectAtIndex:index]);
        id saved([rawStacks objectAtIndex:index]);
        if (!IsRouteStack(standard) || !IsRouteStack(saved))
            return nil;
    }

    return [[self alloc] initWithInterfaceState:rawStacks
                                   selectedIndex:(NSUInteger) signedIndex
                                      lastClosed:rawClosed];
}

@end

NSDictionary *CydiaUIBuildRestorationStateDictionary(
    NSArray *interfaceState,
    NSDate *lastClosed,
    NSUInteger selectedIndex) {
    if (![interfaceState isKindOfClass:[NSArray class]] ||
        ![lastClosed isKindOfClass:[NSDate class]])
        return nil;

    /* dictionaryWithObjectsAndKeys: takes value,key pairs. */
    return [NSDictionary dictionaryWithObjectsAndKeys:
        interfaceState, @"InterfaceState",
        lastClosed, @"LastClosed",
        [NSNumber numberWithUnsignedInteger:selectedIndex], @"InterfaceIndex",
    nil];
}
