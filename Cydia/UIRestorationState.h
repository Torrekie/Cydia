/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_UIRestorationState_H
#define Cydia_UIRestorationState_H

#import <Foundation/Foundation.h>

/* A validated, immutable view of SavedState.plist.  Callers may use the
 * returned arrays without repeating type checks before indexing them. */
@interface CydiaUIRestorationState : NSObject

@property (nonatomic, readonly, copy) NSArray *interfaceState;
@property (nonatomic, readonly) NSUInteger selectedIndex;
@property (nonatomic, readonly, copy) NSDate *lastClosed;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

+ (instancetype) stateWithDictionary:(NSDictionary *)dictionary
                       standardStacks:(NSArray *)standardStacks;

@end

/* Keep the plist writer in one place so its value/key ordering is exercised by
 * the host round-trip test as well as the application lifecycle. */
FOUNDATION_EXPORT NSDictionary *CydiaUIBuildRestorationStateDictionary(
    NSArray *interfaceState,
    NSDate *lastClosed,
    NSUInteger selectedIndex);

#endif // Cydia_UIRestorationState_H
