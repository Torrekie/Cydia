/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/Application.h"
#include "Cydia/LegacyUICompatibilityNativeProvider.h"

#include <objc/runtime.h>

@interface CydiaLegacyUICompatibilityNativeCapability (RenderingBinding)
- (BOOL) _isIssuedForApplication:(id)application;
@end

@interface CydiaLegacyUICompatibilityNativeProvider (RenderingPrivate)
- (BOOL) sessionIsOwnedAndActive:(CydiaLegacyUICompatibilityNativeSession *)session;
- (CydiaLegacyUICompatibilityNativeSession *) retainSession:(CydiaLegacyUICompatibilityNativeSession *)session;
@end

namespace {

BOOL RenderingSafeString(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] != 0 &&
        [value length] <= 4096 &&
        [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

BOOL RenderingSafeReachabilityName(id value) {
    if (!RenderingSafeString(value) || [value length] > 253)
        return NO;
    NSString *name((NSString *)value);
    NSCharacterSet *allowed([NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"]);
    if ([name rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound)
        return NO;
    for (NSString *label in [name componentsSeparatedByString:@"."])
        if ([label length] == 0 || [label length] > 63 ||
            [label hasPrefix:@"-"] || [label hasSuffix:@"-"])
            return NO;
    return YES;
}

} // namespace

@implementation CydiaLegacyUICompatibilityNativeProvider (Rendering)

- (CydiaLegacyUICompatibilityNativeSession *) sessionForRenderingWithPresenter:(id)presenter {
    Cydia *application(self.application);
    CydiaLegacyUICompatibilityNativeCaller *caller([application legacyUICompatibilityCaller]);
    id effectivePresenter(presenter ?: self.presenter);
    if (!self.isActive || application == nil || effectivePresenter != self.presenter ||
        caller == nil || object_getClass(application) != NSClassFromString(@"Cydia") ||
        ![[caller capability] _isIssuedForApplication:application])
        return nil;
    return [self retainSession:[caller sessionForScope:@"CyteObject" target:application
        packageIdentity:nil sourceKey:nil presenter:effectivePresenter]];
}

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
     valueForRenderingMember:(NSString *)memberName
                  arguments:(NSArray *)arguments {
    Cydia *application(self.application);
    BOOL explicitRendering([[session targetScope] isEqualToString:@"CyteObject"]);
    BOOL inheritedRendering([[session targetScope] isEqualToString:@"CydiaObject"] &&
        ([memberName isEqualToString:@"localize"] || [memberName isEqualToString:@"format"]));
    if (![self sessionIsOwnedAndActive:session] || application == nil ||
        [session target] != application || (!explicitRendering && !inheritedRendering))
        return nil;
    if ([memberName isEqualToString:@"format"] &&
        [arguments isKindOfClass:[NSArray class]] && [arguments count] == 2)
        return CydiaLegacyUICompatibilityFormatString(
            [arguments objectAtIndex:0], [arguments objectAtIndex:1]);
    if ([memberName isEqualToString:@"localize"] &&
        [arguments isKindOfClass:[NSArray class]] && [arguments count] == 3)
        return CydiaLegacyUICompatibilityLocalizedStringInBundle(
            [NSBundle mainBundle], [arguments objectAtIndex:0],
            [arguments objectAtIndex:1], [arguments objectAtIndex:2]);
    if ([memberName isEqualToString:@"supports"] &&
        [arguments isKindOfClass:[NSArray class]] && [arguments count] == 1 &&
        RenderingSafeString([arguments objectAtIndex:0]))
        return @([[arguments objectAtIndex:0] isEqualToString:@"window.open"]);
    if ([memberName isEqualToString:@"isReachable"] &&
        [arguments isKindOfClass:[NSArray class]] && [arguments count] == 1 &&
        RenderingSafeReachabilityName([arguments objectAtIndex:0]))
        /* No network/DNS probe is allowed until a first-party origin contract
         * exists; fail closed while preserving the typed boolean result. */
        return @NO;
    if ([arguments count] != 0)
        return nil;
    if ([memberName isEqualToString:@"getPreferredLanguages"])
        return [NSLocale preferredLanguages];
    if ([memberName isEqualToString:@"getLocaleIdentifier"])
        return [[NSLocale currentLocale] localeIdentifier];
    return nil;
}

@end
