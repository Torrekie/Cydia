/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_DatabaseRuntimeInternal_H
#define Cydia_DatabaseRuntimeInternal_H
#import "Cydia/RuntimeProviderSettingsController.h"
#include "Cydia/RuntimeProviderCoordinator.hpp"
#include "Cydia/TransactionReview.h"

@interface Database (RuntimeProviderInternal)
- (void)initializeRuntimeProvider;
- (void)selectRuntimeProviderForReload;
- (void)publishRuntimeProviderStatus;
- (void)invalidateConfirmationReview;
- (bool)captureConfirmationReview;
- (bool)confirmedTransactionUnchanged;
// Asynchronous policy changes restart the same selection policy with a clean
// worker/configuration, preserving absence separately from a saved override.
- (void)setRepositorySecurityPreference:(NSString *)value completion:(CydiaRuntimeProviderCompletion)completion;
@end
#endif
