/* Cydia depiction resource resolver.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_URLResourceResolver_H
#define Cydia_URLResourceResolver_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CydiaURLResourceResolution) {
    CydiaURLResourceResolutionUnhandled = 0,
    CydiaURLResourceResolutionFailed,
    CydiaURLResourceResolutionSucceeded,
};

/* Resolves one already-separated legacy resource path. Unknown commands stay
 * distinguishable from recognized requests that fail validation or lookup. */
FOUNDATION_EXPORT CydiaURLResourceResolution CydiaResolveURLResourcePath(
    NSString * _Nullable path,
    NSData * _Nullable * _Nullable PNGData);

NS_ASSUME_NONNULL_END

#endif // Cydia_URLResourceResolver_H
