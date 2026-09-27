/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/Application.h"
#include "Cydia/LegacyUICompatibilityNativeProvider.h"

/* Keep this Foundation value copier beside the application forwarding
 * category, outside the provider's implementation file.  It intentionally
 * preserves the historical object identity for scalar/non-container values
 * while detaching mutable Foundation containers at the compatibility edge. */
id CopyValue(id value) {
    if (value == nil || value == [NSNull null])
        return value;
    if ([value isKindOfClass:[NSString class]] ||
        [value isKindOfClass:[NSArray class]] ||
        [value isKindOfClass:[NSDictionary class]] ||
        [value isKindOfClass:[NSSet class]])
        return [value copy];
    return value;
}

@implementation Cydia (LegacyUICompatibilityNativeProvider)

- (CydiaLegacyUICompatibilityNativeCaller *) legacyUICompatibilityCaller {
    return legacyCompatibilityCaller_;
}

- (CydiaLegacyUICompatibilityNativeProvider *) legacyUICompatibilityProvider {
    return legacyCompatibilityProvider_;
}

- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForPackage:(Package *)package
                                                                              presenter:(id)presenter {
    return [legacyCompatibilityProvider_ sessionForPackage:package presenter:presenter];
}

- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForSource:(Source *)source
                                                                            presenter:(id)presenter {
    return [legacyCompatibilityProvider_ sessionForSource:source presenter:presenter];
}

- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForApplicationWithPresenter:(id)presenter {
    return [legacyCompatibilityProvider_ sessionForApplicationWithPresenter:presenter];
}

- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForRenderingWithPresenter:(id)presenter {
    return [legacyCompatibilityProvider_ sessionForRenderingWithPresenter:presenter];
}

- (void) invalidateLegacyUICompatibility {
    [legacyCompatibilityProvider_ invalidate];
    legacyCompatibilityApplicationSession_ = nil;
    legacyCompatibilityProvider_ = nil;
    legacyCompatibilityCaller_ = nil;
}

@end
