/* Cydia Refurbished native package-detail simulator probe.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageDetailControllerProbe_H
#define Cydia_PackageDetailControllerProbe_H

#include <TargetConditionals.h>
#include <UIKit/UIKit.h>

#if TARGET_OS_SIMULATOR
UIViewController *CydiaPackageDetailControllerProbeRootController(void);
#endif

#endif // Cydia_PackageDetailControllerProbe_H
