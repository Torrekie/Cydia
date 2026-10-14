/* Cydia Refurbished native package-support page.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageSupportController_H
#define Cydia_PackageSupportController_H

#include "CyteKit/ViewController.h"

@class Database;
@class CydiaPackageDetailViewModel;

NS_ASSUME_NONNULL_BEGIN

/* UIKit counterpart of the legacy package/support popup. It renders the same
 * immutable package snapshot as the detail page without retaining an APT
 * transaction or web view. */
@interface PackageSupportController : CyteViewController

- (nullable instancetype)initWithDatabase:(Database *)database
                                  package:(NSString *)identity;
/* Retains this exact selection, including its repository, across Reload. */
- (nullable instancetype)initWithViewModel:(CydiaPackageDetailViewModel *)viewModel;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageSupportController_H
