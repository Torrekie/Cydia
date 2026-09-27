/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibilityNativeSnapshot.h"

#include <objc/runtime.h>

/* The provider and native caller use this private category.  It is kept out
 * of the public header so a depiction/web caller cannot manufacture values or
 * inspect the parent-session token. */
@interface CydiaLegacyUICompatibilityNativeSnapshot (Private)
+ (instancetype) operationSnapshotWithOperator:(NSString *)operatorValue
                                          value:(NSString *)value
                                  parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
+ (instancetype) clauseSnapshotWithPackage:(NSString *)package
                                    version:(id)version
                              parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
+ (instancetype) relationSnapshotWithClauses:(NSArray *)clauses
                                  relationship:(NSString *)relationship
                                  parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
+ (instancetype) mimeAddressSnapshotWithAddress:(NSString *)address
                                            name:(NSString *)name
                                    parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
- (BOOL) isBoundToSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
@end

namespace {

NSString *ImmutableString(id value) {
    if (![value isKindOfClass:[NSString class]])
        return nil;
    /* `stringWithString:` strips mutable-string subclasses before the value is
     * retained by the snapshot. */
    return [[NSString alloc] initWithString:(NSString *)value];
}

BOOL IsSnapshot(id value,
                CydiaLegacyUICompatibilityNativeSnapshotKind kind,
                id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    return value != nil && object_getClass(value) ==
        [CydiaLegacyUICompatibilityNativeSnapshot class] &&
        [(CydiaLegacyUICompatibilityNativeSnapshot *)value kind] == kind &&
        [(CydiaLegacyUICompatibilityNativeSnapshot *)value isBoundToSession:parent];
}

NSArray *ImmutableSnapshotArray(NSArray *values,
    CydiaLegacyUICompatibilityNativeSnapshotKind kind,
    id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent) {
    if (![values isKindOfClass:[NSArray class]])
        return nil;
    NSMutableArray *copy([NSMutableArray arrayWithCapacity:[values count]]);
    for (id value in values) {
        if (!IsSnapshot(value, kind, parent))
            return nil;
        [copy addObject:value];
    }
    return [[NSArray alloc] initWithArray:copy copyItems:YES];
}

} // namespace

@interface CydiaLegacyUICompatibilityNativeSnapshot () {
    __weak id<CydiaLegacyUICompatibilityNativeSnapshotParent> parentSession_;
    CydiaLegacyUICompatibilityNativeSnapshotKind kind_;
    NSString *operationOperator_;
    NSString *operationValue_;
    NSString *clausePackage_;
    id clauseVersion_;
    NSArray *relationClauses_;
    NSString *relationRelationship_;
    NSString *mimeAddressAddress_;
    NSString *mimeAddressName_;
}
- (instancetype) initWithKind:(CydiaLegacyUICompatibilityNativeSnapshotKind)kind
                 parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent;
@end

@implementation CydiaLegacyUICompatibilityNativeSnapshot

- (instancetype) initWithKind:(CydiaLegacyUICompatibilityNativeSnapshotKind)kind
                 parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent {
    if (parent == nil || ![parent isActive] ||
        (self = [super init]) == nil)
        return nil;
    kind_ = kind;
    parentSession_ = parent;
    return self;
}

+ (instancetype) operationSnapshotWithOperator:(NSString *)operatorValue
                                          value:(NSString *)value
                                  parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent {
    NSString *operatorCopy(ImmutableString(operatorValue));
    NSString *valueCopy(ImmutableString(value));
    if (operatorValue != nil && operatorCopy == nil)
        return nil;
    if (value != nil && valueCopy == nil)
        return nil;
    CydiaLegacyUICompatibilityNativeSnapshot *snapshot(
        [[self alloc] initWithKind:
            CydiaLegacyUICompatibilityNativeSnapshotKindOperation
            parentSession:parent]);
    if (snapshot == nil)
        return nil;
    snapshot->operationOperator_ = operatorCopy;
    snapshot->operationValue_ = valueCopy;
    return snapshot;
}

+ (instancetype) clauseSnapshotWithPackage:(NSString *)package
                                    version:(id)version
                              parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent {
    NSString *packageCopy(ImmutableString(package));
    if (package == nil || packageCopy == nil)
        return nil;
    id versionCopy(nil);
    if (version == nil || version == [NSNull null]) {
        versionCopy = [NSNull null];
    } else if (IsSnapshot(version,
               CydiaLegacyUICompatibilityNativeSnapshotKindOperation, parent)) {
        versionCopy = [version copy];
    } else {
        return nil;
    }
    CydiaLegacyUICompatibilityNativeSnapshot *snapshot(
        [[self alloc] initWithKind:
            CydiaLegacyUICompatibilityNativeSnapshotKindClause
            parentSession:parent]);
    if (snapshot == nil)
        return nil;
    snapshot->clausePackage_ = packageCopy;
    snapshot->clauseVersion_ = versionCopy;
    return snapshot;
}

+ (instancetype) relationSnapshotWithClauses:(NSArray *)clauses
                                  relationship:(NSString *)relationship
                                  parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent {
    NSArray *clausesCopy(ImmutableSnapshotArray(clauses,
        CydiaLegacyUICompatibilityNativeSnapshotKindClause, parent));
    NSString *relationshipCopy(ImmutableString(relationship));
    if (clausesCopy == nil || (relationship != nil && relationshipCopy == nil))
        return nil;
    CydiaLegacyUICompatibilityNativeSnapshot *snapshot(
        [[self alloc] initWithKind:
            CydiaLegacyUICompatibilityNativeSnapshotKindRelation
            parentSession:parent]);
    if (snapshot == nil)
        return nil;
    snapshot->relationClauses_ = clausesCopy;
    snapshot->relationRelationship_ = relationshipCopy;
    return snapshot;
}

+ (instancetype) mimeAddressSnapshotWithAddress:(NSString *)address
                                            name:(NSString *)name
                                    parentSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent {
    NSString *addressCopy(ImmutableString(address));
    NSString *nameCopy(ImmutableString(name));
    if (address != nil && addressCopy == nil)
        return nil;
    if (name != nil && nameCopy == nil)
        return nil;
    CydiaLegacyUICompatibilityNativeSnapshot *snapshot(
        [[self alloc] initWithKind:
            CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress
            parentSession:parent]);
    if (snapshot == nil)
        return nil;
    snapshot->mimeAddressAddress_ = addressCopy;
    snapshot->mimeAddressName_ = nameCopy;
    return snapshot;
}

- (CydiaLegacyUICompatibilityNativeSnapshotKind) kind {
    return kind_;
}

- (BOOL) isValid {
    id<CydiaLegacyUICompatibilityNativeSnapshotParent> parent(parentSession_);
    return parent != nil && [parent isActive];
}

- (BOOL) isBoundToSession:(id<CydiaLegacyUICompatibilityNativeSnapshotParent>)parent {
    return parent != nil && parentSession_ == parent && [self isValid];
}

- (NSString *) operationOperator {
    return [operationOperator_ copy];
}

- (NSString *) operationValue {
    return [operationValue_ copy];
}

- (NSString *) clausePackage {
    return [clausePackage_ copy];
}

- (id) clauseVersion {
    return [clauseVersion_ copy];
}

- (NSArray *) relationClauses {
    return [relationClauses_ copy];
}

- (NSString *) relationRelationship {
    return [relationRelationship_ copy];
}

- (NSString *) mimeAddressAddress {
    return [mimeAddressAddress_ copy];
}

- (NSString *) mimeAddressName {
    return [mimeAddressName_ copy];
}

- (id) copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

- (NSString *) description {
    return [NSString stringWithFormat:@"<native compatibility snapshot:%lu %@>",
        (unsigned long)kind_, [self isValid] ? @"live" : @"stale"];
}

@end
