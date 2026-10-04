/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef Cydia_NativeMutationDiagnostic_H
#define Cydia_NativeMutationDiagnostic_H

#import <Foundation/Foundation.h>

@class Database;
@class Package;
@class CydiaLegacyUICompatibilityNativeSession;

/* Internal fixed-input test selection only; no mutation or new authority. */
NSString *CydiaNativeCompatibilityMutationDiagnosticOperationForValue(id operation);
BOOL CydiaNativeCompatibilityB17FixtureRequested(void);
NSString *CydiaNativeCompatibilityMutationDiagnosticPackageIdentifier(void);
NSString *CydiaNativeCompatibilityMutationDiagnosticSourceURL(void);
NSString *CydiaNativeCompatibilityMutationDiagnosticDistribution(void);
NSString *CydiaNativeCompatibilityMutationDiagnosticSection(void);
NSString *CydiaNativeCompatibilityMutationDiagnosticMetadataKey(void);
id CydiaNativeCompatibilityMutationDiagnosticValue(void);
Package *CydiaNativeCompatibilityMutationDiagnosticPackage(Database *database);
BOOL CydiaNativeCompatibilityMutationDiagnosticPreparePackage(NSString *operation, Package *package);
NSDictionary *CydiaNativeCompatibilityPackageMutationObservation(NSString *operation,
    CydiaLegacyUICompatibilityNativeSession *session, Package *package,
    NSString *modeBefore, NSUInteger entriesBefore, NSUInteger rejectionsBefore, id result);

#endif
