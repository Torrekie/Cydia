/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* Observation only. An emitted row is never an installed-acceptance verdict. */
@interface CydiaNativeAccessibilityJournal : NSObject
- (instancetype)initWithEnvironment:(NSDictionary *)environment
                     runtimeVersion:(NSString *)runtimeVersion;
- (void)appendEvent:(NSString *)event fields:(NSDictionary *)fields;
@property(nonatomic, readonly, getter=isHealthy) BOOL healthy;
@end
