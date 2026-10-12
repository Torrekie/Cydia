/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageUnavailableController_H
#define Cydia_PackageUnavailableController_H

#include "CyteKit/ViewController.h"

@class Database;

NS_ASSUME_NONNULL_BEGIN

/* An owning, read-only presentation of an unsuccessful package lookup. */
@interface PackageUnavailableController : CyteViewController
- (nullable instancetype)initWithDatabase:(Database *)database
                              forPackage:(NSString *)identity
                            withReferrer:(nullable NSString *)referrer;
@end

NS_ASSUME_NONNULL_END

#endif
