/* Cydia URL-protocol resource boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_URLProtocolPolicy_H
#define Cydia_URLProtocolPolicy_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Resource commands retained for trusted/legacy depiction image requests.
 * The identifier returned by the policy is decoded data, never a path. */
typedef NS_ENUM(NSUInteger, CydiaURLResourceKind) {
    CydiaURLResourceKindUnknown = 0,
    CydiaURLResourceKindApplicationIcon,
    CydiaURLResourceKindPackageIcon,
    CydiaURLResourceKindUIKitImage,
    CydiaURLResourceKindSectionIcon,
};

FOUNDATION_EXPORT CydiaURLResourceKind CydiaURLResourceKindForCommand(
    NSString * _Nullable command);

/* Preserves the encoded command/identifier spelling after the cydia:// URL
 * boundary so both legacy and public depiction loaders apply one policy. */
FOUNDATION_EXPORT NSString * _Nullable CydiaURLResourcePathForURL(
    NSURL * _Nullable URL);

/* Decodes one URL-protocol identifier and rejects malformed escapes, control
 * characters, path separators (including encoded/double-encoded separators),
 * traversal components, raw URL delimiters, and unbounded input. Percent-
 * encoded '?' and '#' remain identifier data after the URL parser boundary. */
FOUNDATION_EXPORT NSString * _Nullable CydiaURLResourceDecodeIdentifier(
    NSString * _Nullable rawIdentifier,
    CydiaURLResourceKind kind);

/* The protocol only emits PNG data produced by UIImage. Keep both the encoded
 * response and its declared pixel dimensions bounded before delivering it to
 * an untrusted depiction consumer. */
FOUNDATION_EXPORT BOOL CydiaURLResourcePNGDataIsAllowed(NSData * _Nullable data);
FOUNDATION_EXPORT BOOL CydiaURLResourceImageDimensionsAreAllowed(
    NSUInteger width, NSUInteger height);

NS_ASSUME_NONNULL_END

#endif // Cydia_URLProtocolPolicy_H
