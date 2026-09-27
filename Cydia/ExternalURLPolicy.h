/* Cydia Refurbished external URL boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_ExternalURLPolicy_H
#define Cydia_ExternalURLPolicy_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CydiaExternalURLPresentationKind) {
    CydiaExternalURLPresentationKindSafari,
    CydiaExternalURLPresentationKindSystem,
    CydiaExternalURLPresentationKindAppStore,
};

/* Shared Foundation-only HTTP(S) boundary. The URL must be standalone and
 * credential-free, with a nonempty host containing no controls/whitespace and
 * an explicit port, when present, in the IANA 1...65535 range. */
FOUNDATION_EXPORT BOOL CydiaExternalURLIsValidWebURL(NSURL * _Nullable URL);

/* Foundation-only validation shared by cydia://url parsing, native Home and
 * package handoffs, and the UIKit/SafariServices coordinator. */
@interface CydiaExternalURLPolicy : NSObject

@property(nonatomic, copy, readonly) NSURL *destinationURL;
@property(nonatomic, readonly) CydiaExternalURLPresentationKind presentationKind;
@property(nonatomic, readonly) BOOL requiresConfirmation;
@property(nonatomic, copy, readonly) NSString *displayName;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithURL:(NSURL * _Nullable)URL NS_DESIGNATED_INITIALIZER;

@end

/* Produces the canonical typed wrapper consumed by CydiaUIRouteContext. The
 * destination is fully percent-encoded so query, fragment, and existing
 * escapes cannot become syntax of the outer cydia:// URL. */
FOUNDATION_EXPORT NSURL * _Nullable CydiaExternalURLRouteURL(NSURL * _Nullable URL);

NS_ASSUME_NONNULL_END

#endif // Cydia_ExternalURLPolicy_H
