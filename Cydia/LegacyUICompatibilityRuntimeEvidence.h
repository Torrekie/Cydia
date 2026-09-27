/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_LegacyUICompatibilityRuntimeEvidence_H
#define Cydia_LegacyUICompatibilityRuntimeEvidence_H

#include "Cydia/LegacyUICompatibilityNativeCaller.h"

#import <Foundation/Foundation.h>

/* The receipt is deliberately opt-in.  An unset, empty, or unsafe path is a
 * no-op; normal application launches therefore do not create files or inspect
 * compatibility targets. */
FOUNDATION_EXPORT NSString * const
    CydiaLegacyUICompatibilityRuntimeEvidencePathEnvironment;
FOUNDATION_EXPORT NSString * const
    CydiaLegacyUICompatibilityRuntimeEvidenceRunIDEnvironment;

FOUNDATION_EXPORT BOOL
CydiaLegacyUICompatibilityRuntimeEvidenceRequested(void);
FOUNDATION_EXPORT NSString *
CydiaLegacyUICompatibilityRuntimeEvidenceOutputPath(void);
FOUNDATION_EXPORT NSString *
CydiaLegacyUICompatibilityRuntimeEvidenceRunID(void);

/* `sessions` is an app-owned dictionary keyed by receiver scope.  Values are
 * either a live, typed native session or NSNull.  The implementation sends
 * only `decisionForScope:` to a supplied session; it never invokes a member,
 * asks a provider to read data, or performs a route handoff. */
FOUNDATION_EXPORT NSDictionary *
CydiaLegacyUICompatibilityRuntimeEvidenceBuildReceipt(
    NSString *runID,
    NSDictionary *identity,
    NSDictionary *sessions);

FOUNDATION_EXPORT BOOL
CydiaLegacyUICompatibilityRuntimeEvidenceWriteReceipt(
    NSString *path,
    NSString *runID,
    NSDictionary *identity,
    NSDictionary *sessions,
    NSError **error);

#endif // Cydia_LegacyUICompatibilityRuntimeEvidence_H
