/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_LegacyUICompatibilityNativeSnapshot_H
#define Cydia_LegacyUICompatibilityNativeSnapshot_H

#import <Foundation/Foundation.h>

/*
 * A snapshot parent is intentionally smaller than the native session class.
 * Keeping this protocol Foundation-only lets the compatibility value layer
 * remain independent from Package, Relations, MIMEAddress, UIKit, and APT.
 * Native sessions conform to it and become false after capability/session
 * invalidation.
 */
@protocol CydiaLegacyUICompatibilityNativeSnapshotParent <NSObject>
@property (nonatomic, readonly, getter=isActive) BOOL active;
@end

typedef NS_ENUM(NSUInteger, CydiaLegacyUICompatibilityNativeSnapshotKind) {
    CydiaLegacyUICompatibilityNativeSnapshotKindOperation,
    CydiaLegacyUICompatibilityNativeSnapshotKindClause,
    CydiaLegacyUICompatibilityNativeSnapshotKindRelation,
    CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress,
};

/*
 * Opaque, immutable values used by the native legacy compatibility bridge.
 * The class has no model object ivars and no setters/KVC surface.  Its typed
 * accessors expose only copied Foundation values (or more snapshots), while
 * construction is private to the app-owned provider.
 */
@interface CydiaLegacyUICompatibilityNativeSnapshot : NSObject <NSCopying>

@property (nonatomic, readonly) CydiaLegacyUICompatibilityNativeSnapshotKind kind;
@property (nonatomic, readonly, getter=isValid) BOOL valid;

/* Operation snapshot (`CydiaOperation.operator` / `.value`). */
- (NSString *) operationOperator;
- (NSString *) operationValue;

/* Clause snapshot (`CydiaClause.package` / `.version`).  A missing version
 * is represented by NSNull, matching the historical model contract. */
- (NSString *) clausePackage;
- (id) clauseVersion;

/* Relation snapshot (`CydiaRelation.clauses` / `.relationship`). */
- (NSArray *) relationClauses;
- (NSString *) relationRelationship;

/* MIME address snapshot (`MIMEAddress.address` / `.name`). */
- (NSString *) mimeAddressAddress;
- (NSString *) mimeAddressName;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end

#endif // Cydia_LegacyUICompatibilityNativeSnapshot_H
