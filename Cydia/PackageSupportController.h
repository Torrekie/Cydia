/* Cydia Refurbished native package-support page.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageSupportController_H
#define Cydia_PackageSupportController_H

#include "CyteKit/ViewController.h"

@class Database;

NS_ASSUME_NONNULL_BEGIN

/* UIKit counterpart of the legacy package/support popup.  It intentionally
 * receives a Database snapshot through the same route boundary as the package
 * page and does not retain an APT transaction or web view. */
@interface PackageSupportController : CyteViewController

- (nullable instancetype)initWithDatabase:(Database *)database
                                  package:(NSString *)identity;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_PackageSupportController_H
