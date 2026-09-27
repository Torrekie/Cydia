/* Cydia URL-protocol resource boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/URLProtocolPolicy.h"

#include <stdint.h>
#include <string.h>

namespace {

static const NSUInteger kMaximumIdentifierBytes = 1024;
static const NSUInteger kMaximumPNGBytes = 8 * 1024 * 1024;
static const NSUInteger kMaximumPNGDimension = 4096;
/* Four million decoded pixels cap one response near 16 MiB before UIKit's
 * transient encode/decode storage, while still admitting any plausible icon
 * and narrow high-resolution system artwork. */
static const uint64_t kMaximumPNGPixelCount = 4ULL * 1024ULL * 1024ULL;

BOOL HasAnyCharacter(NSString *value, NSString *characters) {
    return [value rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:characters]].location != NSNotFound;
}

BOOL HasEncodedSeparator(NSString *value) {
    NSString *candidate(value);
    /* A second pass catches a separator hidden behind %25 (for example,
     * %252f), while the bounded loop avoids treating arbitrary data as a
     * recursive URL encoding language. */
    for (NSUInteger pass = 0; pass != 3; ++pass) {
        if ([candidate rangeOfString:@"%2f" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [candidate rangeOfString:@"%5c" options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;

        NSString *decoded([candidate stringByRemovingPercentEncoding]);
        if (decoded == nil || [decoded isEqualToString:candidate])
            return NO;
        candidate = decoded;
    }
    return NO;
}

BOOL HasUnsafeRawIdentifierContent(NSString *value) {
    if ([value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound)
        return YES;
    /* Raw '?' and '#' are URL syntax; encoded forms are identifier data. */
    return HasAnyCharacter(value, @"/\\?#");
}

BOOL HasUnsafeDecodedIdentifierContent(NSString *value) {
    if ([value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound)
        return YES;
    return HasAnyCharacter(value, @"/\\");
}

uint32_t ReadBigEndian32(const uint8_t *bytes) {
    return (static_cast<uint32_t>(bytes[0]) << 24) |
        (static_cast<uint32_t>(bytes[1]) << 16) |
        (static_cast<uint32_t>(bytes[2]) << 8) |
        static_cast<uint32_t>(bytes[3]);
}

} // namespace


CydiaURLResourceKind CydiaURLResourceKindForCommand(NSString *command) {
    if (![command isKindOfClass:[NSString class]])
        return CydiaURLResourceKindUnknown;
    if ([command isEqualToString:@"application-icon"])
        return CydiaURLResourceKindApplicationIcon;
    if ([command isEqualToString:@"package-icon"])
        return CydiaURLResourceKindPackageIcon;
    if ([command isEqualToString:@"uikit-image"])
        return CydiaURLResourceKindUIKitImage;
    if ([command isEqualToString:@"section-icon"])
        return CydiaURLResourceKindSectionIcon;
    return CydiaURLResourceKindUnknown;
}

NSString *CydiaURLResourcePathForURL(NSURL *URL) {
    if (![URL isKindOfClass:[NSURL class]] ||
        ![[[URL scheme] lowercaseString] isEqualToString:@"cydia"])
        return nil;

    NSString *absolute([URL absoluteString]);
    NSRange delimiter([absolute rangeOfString:@"://"]);
    if (delimiter.location == NSNotFound || NSMaxRange(delimiter) >= [absolute length])
        return nil;
    return [absolute substringFromIndex:NSMaxRange(delimiter)];
}

NSString *CydiaURLResourceDecodeIdentifier(NSString *rawIdentifier,
                                            CydiaURLResourceKind kind) {
    if (kind == CydiaURLResourceKindUnknown ||
        ![rawIdentifier isKindOfClass:[NSString class]] ||
        [rawIdentifier length] == 0)
        return nil;

    /* Bound UTF-16 storage before creating any full UTF-8 or decoded copies.
     * The later byte checks remain authoritative for multibyte input. */
    if ([rawIdentifier length] > kMaximumIdentifierBytes)
        return nil;

    if (HasUnsafeRawIdentifierContent(rawIdentifier) ||
        HasEncodedSeparator(rawIdentifier))
        return nil;

    NSData *rawBytes([rawIdentifier dataUsingEncoding:NSUTF8StringEncoding
                                  allowLossyConversion:NO]);
    if (rawBytes == nil || [rawBytes length] == 0 ||
        [rawBytes length] > kMaximumIdentifierBytes)
        return nil;

    NSString *decoded([rawIdentifier stringByRemovingPercentEncoding]);
    if (decoded == nil || [decoded length] == 0 ||
        [decoded isEqualToString:@"."] || [decoded isEqualToString:@".."] ||
        HasUnsafeDecodedIdentifierContent(decoded) || HasEncodedSeparator(decoded))
        return nil;

    NSData *decodedBytes([decoded dataUsingEncoding:NSUTF8StringEncoding
                                allowLossyConversion:NO]);
    if (decodedBytes == nil || [decodedBytes length] == 0 ||
        [decodedBytes length] > kMaximumIdentifierBytes)
        return nil;
    return decoded;
}

BOOL CydiaURLResourceImageDimensionsAreAllowed(NSUInteger width,
                                                NSUInteger height) {
    if (width == 0 || height == 0 || width > kMaximumPNGDimension ||
        height > kMaximumPNGDimension)
        return NO;
    return static_cast<uint64_t>(width) * static_cast<uint64_t>(height) <=
        kMaximumPNGPixelCount;
}

BOOL CydiaURLResourcePNGDataIsAllowed(NSData *data) {
    if (![data isKindOfClass:[NSData class]] ||
        [data length] < 33 || [data length] > kMaximumPNGBytes)
        return NO;

    const uint8_t *bytes(static_cast<const uint8_t *>([data bytes]));
    static const uint8_t signature[] = {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    };
    if (memcmp(bytes, signature, sizeof(signature)) != 0 ||
        ReadBigEndian32(bytes + 8) != 13 ||
        memcmp(bytes + 12, "IHDR", 4) != 0)
        return NO;

    return CydiaURLResourceImageDimensionsAreAllowed(
        ReadBigEndian32(bytes + 16), ReadBigEndian32(bytes + 20));
}
