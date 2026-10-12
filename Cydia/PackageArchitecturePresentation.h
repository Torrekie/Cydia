/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageArchitecturePresentation_H
#define Cydia_PackageArchitecturePresentation_H

#import <Foundation/Foundation.h>

#include <string>
#include <vector>

/* Keep the presentation policy independent of APT and UIKit.  Callers pass
 * dpkg's registered architectures, native first; acquisition filters do not
 * decide whether an installation is multiarch.  Unknown runtime state does
 * not invent an incompatibility warning. */
static inline NSArray<NSString *> *CydiaPackageRegisteredArchitectureNames(
    const std::vector<std::string> &architectures) {
    NSMutableArray<NSString *> *names([NSMutableArray array]);
    for (const std::string &architecture : architectures) {
        NSString *name([NSString stringWithUTF8String:architecture.c_str()]);
        if ([name length] != 0 && ![name isEqualToString:@"all"] &&
            ![name isEqualToString:@"any"] && ![names containsObject:name])
            [names addObject:name];
    }
    return [names copy];
}

static inline NSString *CydiaPackageArchitectureCaption(
    NSString *architecture, NSArray<NSString *> *registeredArchitectures) {
    if (![architecture isKindOfClass:[NSString class]] || [architecture length] == 0 ||
        [architecture isEqualToString:@"any"] || [registeredArchitectures count] == 0)
        return nil;

    const BOOL independent([architecture isEqualToString:@"all"]);
    const BOOL supported(independent || [registeredArchitectures containsObject:architecture]);
    if (supported && [registeredArchitectures count] < 2)
        return nil;

    NSString *key;
    NSString *fallback;
    if (!supported) {
        key = @"PACKAGE_ARCHITECTURE_UNSUPPORTED_LABEL";
        fallback = @"Unsupported · %@";
    } else if (independent) {
        key = @"PACKAGE_ARCHITECTURE_ALL";
        fallback = @"Architecture-independent · %@";
    } else if ([architecture isEqualToString:[registeredArchitectures firstObject]]) {
        key = @"PACKAGE_ARCHITECTURE_NATIVE";
        fallback = @"Native · %@";
    } else {
        key = @"PACKAGE_ARCHITECTURE_FOREIGN";
        fallback = @"Additional · %@";
    }
    NSString *format([[NSBundle mainBundle] localizedStringForKey:key value:fallback table:@"Actions"]);
    return [NSString stringWithFormat:format, architecture];
}

/* This is a native UI label, never a replacement for Package.name or an APT,
 * dpkg, route, or repository depiction identifier. */
static inline NSString *CydiaPackageNameWithArchitectureCaption(NSString *name, NSString *caption) {
    if ([caption length] == 0)
        return name;
    return [NSString stringWithFormat:@"%@ (%@)", name ?: @"", caption];
}

#endif
