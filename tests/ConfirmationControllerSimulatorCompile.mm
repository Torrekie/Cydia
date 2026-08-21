/* Cydia Refurbished confirmation screenshot seam compile fixture.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR
#error This fixture must be compiled against an iPhoneSimulator SDK.
#endif

#include "Cydia/ConfirmationController.h"
#include "Cydia/ConfirmationViewModel.h"

ConfirmationController *CydiaConfirmationControllerForSimulatorProbe(
    CydiaConfirmationViewModel *viewModel,
    id<ConfirmationControllerDelegate> delegate) {
    return [[ConfirmationController alloc] initWithViewModel:viewModel
                                                    delegate:delegate];
}
