/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/UIRestorationState.h"

#include <cstdlib>
#include <iostream>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    std::cerr << "[verify-ui-restoration-state][FAIL] " << [message UTF8String] << std::endl;
    std::exit(1);
}

NSDictionary *ValidDictionary(void) {
    return CydiaUIBuildRestorationStateDictionary(@[
        @[ @"cydia://home" ],
        @[ @"cydia://sources", @"cydia://sections/main" ],
    ], [NSDate date], 1);
}

NSArray *StandardStacks(void) {
    return @[
        @[ @"cydia://home" ],
        @[ @"cydia://sources" ],
    ];
}

void VerifyRoundTrip(void) {
    NSDictionary *dictionary(ValidDictionary());
    Expect(dictionary != nil, @"writer returns a plist dictionary");
    Expect([[dictionary objectForKey:@"InterfaceState"] isKindOfClass:[NSArray class]],
        @"interface state is stored under its key");
    Expect([[dictionary objectForKey:@"InterfaceIndex"] unsignedIntegerValue] == 1,
        @"interface index uses value/key ordering");

    NSString *path([NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"cydia-restoration-%u.plist", arc4random()]]);
    Expect([dictionary writeToFile:path atomically:YES], @"state writes to disk");
    NSDictionary *read([NSDictionary dictionaryWithContentsOfFile:path]);
    CydiaUIRestorationState *state([CydiaUIRestorationState
        stateWithDictionary:read standardStacks:StandardStacks()]);
    Expect(state != nil, @"written state validates");
    Expect([state selectedIndex] == 1, @"selected index survives round trip");
    Expect([[state interfaceState] count] == 2, @"all tab stacks survive round trip");
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

void VerifyMalformedStatesFailClosed(void) {
    NSArray *standard(StandardStacks());
    NSDictionary *valid(ValidDictionary());

    Expect([CydiaUIRestorationState stateWithDictionary:(id) @[] standardStacks:standard] == nil,
        @"non-dictionary state is rejected");

    NSMutableDictionary *wrongStacks([valid mutableCopy]);
    [wrongStacks setObject:@"not-an-array" forKey:@"InterfaceState"];
    Expect([CydiaUIRestorationState stateWithDictionary:wrongStacks standardStacks:standard] == nil,
        @"non-array interface state is rejected");

    NSMutableDictionary *wrongIndex([valid mutableCopy]);
    [wrongIndex setObject:@(-1) forKey:@"InterfaceIndex"];
    Expect([CydiaUIRestorationState stateWithDictionary:wrongIndex standardStacks:standard] == nil,
        @"negative interface index is rejected");

    NSMutableDictionary *outOfRange([valid mutableCopy]);
    [outOfRange setObject:@(2) forKey:@"InterfaceIndex"];
    Expect([CydiaUIRestorationState stateWithDictionary:outOfRange standardStacks:standard] == nil,
        @"out-of-range interface index is rejected");

    NSMutableDictionary *wrongStack([valid mutableCopy]);
    [wrongStack setObject:@[ @[ @"cydia://home" ], @[ @"cydia://sources", @42 ] ]
        forKey:@"InterfaceState"];
    Expect([CydiaUIRestorationState stateWithDictionary:wrongStack standardStacks:standard] == nil,
        @"non-string route entries are rejected");

    NSMutableDictionary *wrongDate([valid mutableCopy]);
    [wrongDate setObject:@"yesterday" forKey:@"LastClosed"];
    Expect([CydiaUIRestorationState stateWithDictionary:wrongDate standardStacks:standard] == nil,
        @"non-date close time is rejected");
}

} // namespace

int main(void) {
    @autoreleasepool {
        VerifyRoundTrip();
        VerifyMalformedStatesFailClosed();
    }
    std::cout << "[verify-ui-restoration-state][ ok ] plist round-trip and fail-closed validation" << std::endl;
    return 0;
}
