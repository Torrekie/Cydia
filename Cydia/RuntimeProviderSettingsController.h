/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RuntimeProviderSettingsController_H
#define Cydia_RuntimeProviderSettingsController_H
#import "CyteKit/ViewController.h"
#import "Cydia/Database.h"
#import "Cydia/RuntimeProviderStatus.h"

NS_ASSUME_NONNULL_BEGIN

@interface CydiaRuntimeProviderSettingsController : CyteViewController
- (instancetype)initWithDatabase:(Database *)database;
@end

@interface Database (RuntimeProviders)
/* Cached only: these reads must not probe executables or contact a provider. */
- (CydiaRuntimeProviderStatus *)runtimeProviderStatus;
/* The coordinator serializes checks/transitions, persists accepted choices,
 * and delivers a current snapshot on the main queue, including on failure. */
- (void)checkRuntimeProviderWithCompletion:(CydiaRuntimeProviderCompletion)completion;
- (void)setRuntimeProviderPreference:(NSString *)preference completion:(CydiaRuntimeProviderCompletion)completion;
@end

NS_ASSUME_NONNULL_END
#endif
