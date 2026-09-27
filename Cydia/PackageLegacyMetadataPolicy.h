/* Cydia legacy package-metadata data boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageLegacyMetadataPolicy_H
#define Cydia_PackageLegacyMetadataPolicy_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* The retired HTML package topper asked this first-party endpoint for optional
 * visible metadata such as the alternate package icon.  Native UIKit keeps
 * that small data request without restoring a page bridge or identity headers. */
FOUNDATION_EXPORT NSURL * _Nullable CydiaPackageLegacyMetadataURL(
    NSString * _Nullable packageIdentity);

/* Parses the bounded legacy parenthesized JSON response.  The returned URL is
 * canonical HTTPS and is restricted to the one first-party PNG namespace
 * observed in the retired package topper. */
FOUNDATION_EXPORT NSURL * _Nullable CydiaPackageLegacyAlternateIconURL(
    NSData * _Nullable metadataData);
FOUNDATION_EXPORT BOOL CydiaPackageLegacyIconURLIsAllowed(
    NSURL * _Nullable URL);
FOUNDATION_EXPORT BOOL CydiaPackageLegacyIconPNGDataIsAllowed(
    NSData * _Nullable data);

FOUNDATION_EXPORT NSUInteger CydiaPackageLegacyMetadataMaximumBytes(void);
FOUNDATION_EXPORT NSUInteger CydiaPackageLegacyIconMaximumBytes(void);

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageLegacyMetadataPolicy_H
