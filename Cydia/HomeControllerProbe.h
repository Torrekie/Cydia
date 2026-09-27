/* Cydia Refurbished native Home simulator probe.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_HomeControllerProbe_H
#define Cydia_HomeControllerProbe_H

#include <TargetConditionals.h>
#include <UIKit/UIKit.h>

#if TARGET_OS_SIMULATOR
UIViewController *CydiaHomeControllerProbeRootController(void);
#endif

#endif // Cydia_HomeControllerProbe_H
