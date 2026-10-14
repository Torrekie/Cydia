/* Native HTTP(S) loader for a package control record's Icon metadata.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_PackageRecordIconLoader_H
#define Cydia_PackageRecordIconLoader_H
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^CydiaPackageRecordIconCompletion)(UIImage * _Nullable image);

@interface CydiaPackageRecordIconLoader : NSObject
/* Copied metadata only; no package, cache, APT or provider handle is retained. */
@property(nonatomic, copy, readonly) NSURL *sourceURL;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (nullable instancetype)initWithURL:(NSURL *)URL
                         completion:(CydiaPackageRecordIconCompletion)completion NS_DESIGNATED_INITIALIZER;
/* Idempotent. Completion runs on the main queue; cancel suppresses it. */
- (void)start;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
#endif
