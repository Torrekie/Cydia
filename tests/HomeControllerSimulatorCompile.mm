/* Cydia Refurbished native Home simulator seam.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR
#error This fixture must be compiled against an iPhoneSimulator SDK.
#endif

#include "Cydia/HomeController.h"

HomeController *CydiaHomeControllerForSimulatorProbe(CydiaHomeViewModel *viewModel) {
    return [[HomeController alloc] initWithViewModel:viewModel];
}
