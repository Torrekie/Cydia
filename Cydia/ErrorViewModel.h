/* Cydia Refurbished native error presentation.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_ErrorViewModel_H
#define Cydia_ErrorViewModel_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Immutable, presentation-only diagnostic. It deliberately snapshots no
 * request headers, body, URL path, query, fragment, user, or password. */
@interface CydiaErrorViewModel : NSObject

@property(nonatomic, copy, readonly) NSString *summary;
@property(nonatomic, copy, readonly) NSString *details;
@property(nonatomic, copy, readonly) NSString *destinationDisplayName;
@property(nonatomic, readonly) BOOL hasDetails;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithError:(nullable NSError *)error
                destinationURL:(nullable NSURL *)destinationURL
    NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_ErrorViewModel_H
