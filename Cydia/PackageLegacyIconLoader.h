/* Native loader for the legacy first-party package alternate icon.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageLegacyIconLoader_H
#define Cydia_PackageLegacyIconLoader_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CydiaPackageLegacyIconCompletion)(UIImage * _Nullable image);

@interface CydiaPackageLegacyIconLoader : NSObject

- (nullable instancetype)initWithPackageIdentity:(NSString *)packageIdentity
                                       completion:(CydiaPackageLegacyIconCompletion)completion;
- (void)start;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageLegacyIconLoader_H
