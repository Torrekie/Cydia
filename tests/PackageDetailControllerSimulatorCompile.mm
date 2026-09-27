/* Cydia Refurbished package-detail simulator seam compile fixture.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR
#error This fixture must be compiled against an iPhoneSimulator SDK.
#endif

#include "Cydia/PackageDetailController.h"
#include "Cydia/PackageControllers.h"

PackageDetailController *CydiaPackageDetailControllerForSimulatorProbe(
    CydiaPackageDetailViewModel *viewModel,
    UIImage *icon,
    id<PackageDetailControllerDelegate> delegate) {
    return [[PackageDetailController alloc] initWithViewModel:viewModel
                                                  headerIcon:icon
                                                    delegate:delegate];
}

CYPackageController *CydiaProductionPackageControllerForSimulatorCompile(
    Database *database, NSString *identity) {
    return [[CYPackageController alloc] initWithDatabase:database
                                              forPackage:identity
                                            withReferrer:nil];
}
