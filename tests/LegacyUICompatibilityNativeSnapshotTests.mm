/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibilityNativeCaller.h"

#include <cstdlib>
#include <iostream>
#include <objc/runtime.h>

/* Provider-only construction remains private in the public snapshot header;
 * this host test declares the same narrow factory seam without importing any
 * Package/Relations/MIMEAddress implementation type. */
@interface CydiaLegacyUICompatibilityNativeSnapshot (TestFactory)
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
@end

namespace {

__weak id CurrentIssuer;

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    std::cerr << "[verify-legacy-ui-compatibility-native-snapshot][FAIL] "
              << [message UTF8String] << std::endl;
    std::exit(1);
}

BOOL IsUndefined(id value) {
    return value == [CydiaLegacyUIUndefinedValue value];
}

BOOL IssuerPredicate(id object, SEL selector) {
    (void)selector;
    return object == CurrentIssuer;
}

id MakeIssuer(void) {
    Class cydiaClass(NSClassFromString(@"Cydia"));
    if (cydiaClass == Nil) {
        cydiaClass = objc_allocateClassPair([NSObject class], "Cydia", 0);
        Expect(cydiaClass != Nil, @"create exact Cydia host class");
        const char types[] = "B@:";
        Expect(class_addMethod(cydiaClass,
            NSSelectorFromString(
                @"cydiaLegacyUICompatibilityApplicationMayIssueCapability"),
            reinterpret_cast<IMP>(IssuerPredicate), types),
            @"install issuer predicate");
        objc_registerClassPair(cydiaClass);
    }
    id issuer([[cydiaClass alloc] init]);
    CurrentIssuer = issuer;
    return issuer;
}

} // namespace

@interface SnapshotTestReader : NSObject <CydiaLegacyUICompatibilityNativeReading>
@property (nonatomic) BOOL returnMutableArray;
@property (nonatomic, strong) id rawValue;
@end

@implementation SnapshotTestReader

- (id) legacyNativeSession:(CydiaLegacyUICompatibilityNativeSession *)session
 valueForNestedSnapshotMember:(NSString *)memberName
                       target:(CydiaLegacyUICompatibilityNativeSnapshot *)target
                    arguments:(NSArray *)arguments {
    (void)session;
    if ([arguments count] != 0)
        return nil;
    if (_rawValue != nil)
        return _rawValue;
    switch ([target kind]) {
        case CydiaLegacyUICompatibilityNativeSnapshotKindOperation:
            return [memberName isEqualToString:@"operator"] ?
                [target operationOperator] : [target operationValue];
        case CydiaLegacyUICompatibilityNativeSnapshotKindClause:
            return [memberName isEqualToString:@"package"] ?
                [target clausePackage] : [target clauseVersion];
        case CydiaLegacyUICompatibilityNativeSnapshotKindRelation:
            if ([memberName isEqualToString:@"relationship"])
                return [target relationRelationship];
            if (_returnMutableArray)
                return [[target relationClauses] mutableCopy];
            return [target relationClauses];
        case CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress:
            return [memberName isEqualToString:@"address"] ?
                [target mimeAddressAddress] : [target mimeAddressName];
    }
    return nil;
}

@end

int main(void) {
    @autoreleasepool {
        id application(MakeIssuer());
        SnapshotTestReader *reader([[SnapshotTestReader alloc] init]);
        CydiaLegacyUICompatibilityNativeCapability *capability(
            [CydiaLegacyUICompatibilityNativeCaller
                issueCapabilityForApplication:application]);
        CydiaLegacyUICompatibilityNativeCaller *caller(
            [[CydiaLegacyUICompatibilityNativeCaller alloc]
                initWithCapability:capability reader:reader commander:nil router:nil]);
        NSObject *target([[NSObject alloc] init]);
        NSObject *presenter([[NSObject alloc] init]);
        CydiaLegacyUICompatibilityNativeSession *session([caller
            sessionForScope:@"Package" target:target
            packageIdentity:@"fixture.package" sourceKey:nil presenter:presenter]);
        Expect(session != nil && [session isActive], @"live parent Package session");

        CydiaLegacyUICompatibilityNativeSnapshot *operation(
            [CydiaLegacyUICompatibilityNativeSnapshot
                operationSnapshotWithOperator:@">=" value:@"2:1.0"
                parentSession:session]);
        CydiaLegacyUICompatibilityNativeSnapshot *clause(
            [CydiaLegacyUICompatibilityNativeSnapshot
                clauseSnapshotWithPackage:@"runtime:any" version:operation
                parentSession:session]);
        CydiaLegacyUICompatibilityNativeSnapshot *relation(
            [CydiaLegacyUICompatibilityNativeSnapshot
                relationSnapshotWithClauses:@[clause] relationship:@"Depends"
                parentSession:session]);
        CydiaLegacyUICompatibilityNativeSnapshot *address(
            [CydiaLegacyUICompatibilityNativeSnapshot
                mimeAddressSnapshotWithAddress:@"dev@example.com" name:@"Dev"
                parentSession:session]);
        Expect(operation != nil && clause != nil && relation != nil && address != nil,
               @"all four exact snapshot kinds construct");
        Expect([operation kind] == CydiaLegacyUICompatibilityNativeSnapshotKindOperation &&
               [clause kind] == CydiaLegacyUICompatibilityNativeSnapshotKindClause &&
               [relation kind] == CydiaLegacyUICompatibilityNativeSnapshotKindRelation &&
               [address kind] == CydiaLegacyUICompatibilityNativeSnapshotKindMIMEAddress,
               @"snapshot kinds are explicit and opaque");
        Expect([operation copy] == operation && [clause copy] == clause &&
               [relation copy] == relation && [address copy] == address,
               @"snapshots cannot be cloned into mutable copies");

        Expect([[session invokeSnapshot:operation memberName:@"operator" arguments:@[]]
                    isEqualToString:@">="] &&
               [[session invokeSnapshot:operation memberName:@"value" arguments:@[]]
                    isEqualToString:@"2:1.0"] &&
               [[session invokeSnapshot:clause memberName:@"package" arguments:@[]]
                    isEqualToString:@"runtime:any"],
               @"operation and clause scalar attributes dispatch through reader");
        id nestedVersion([session invokeSnapshot:clause memberName:@"version" arguments:@[]]);
        Expect(nestedVersion == operation,
               @"clause version remains an operation snapshot, never a raw model");
        id nestedClauses([session invokeSnapshot:relation memberName:@"clauses" arguments:@[]]);
        Expect([nestedClauses isKindOfClass:[NSArray class]] &&
               ![nestedClauses isKindOfClass:[NSMutableArray class]] &&
               [nestedClauses count] == 1 && [nestedClauses objectAtIndex:0] == clause,
               @"relation clauses are immutable child snapshots");
        Expect([[session invokeSnapshot:relation memberName:@"relationship" arguments:@[]]
                    isEqualToString:@"Depends"] &&
               [[session invokeSnapshot:address memberName:@"address" arguments:@[]]
                    isEqualToString:@"dev@example.com"] &&
               [[session invokeSnapshot:address memberName:@"name" arguments:@[]]
                    isEqualToString:@"Dev"],
               @"relation and MIME attributes dispatch through reader");

        Expect(![nestedClauses respondsToSelector:@selector(addObject:)],
               @"returned child array has no mutable mutation API");

        reader.returnMutableArray = YES;
        id sanitizedClauses([session invokeSnapshot:relation memberName:@"clauses" arguments:@[]]);
        Expect([sanitizedClauses isKindOfClass:[NSArray class]] &&
               ![sanitizedClauses isKindOfClass:[NSMutableArray class]] &&
               sanitizedClauses != nestedClauses,
               @"mutable provider arrays are copied before crossing the snapshot boundary");
        reader.returnMutableArray = NO;
        NSMutableString *mutableString([[NSMutableString alloc] initWithString:@"forged"]);
        reader.rawValue = mutableString;
        id sanitizedString([session invokeSnapshot:operation memberName:@"operator" arguments:@[]]);
        Expect([sanitizedString isKindOfClass:[NSString class]] &&
               [sanitizedString isEqualToString:@"forged"] && sanitizedString != mutableString,
               @"mutable provider strings are copied before crossing the snapshot boundary");
        reader.rawValue = nil;

        Expect(IsUndefined([session invokeScope:@"CydiaRelation"
            memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"relationship"
            arguments:@[] targetOrigin:nil]),
            @"direct nested scope invocation without a target snapshot is denied");
        Expect(IsUndefined([session invokeSnapshot:operation memberName:@"package" arguments:@[]]),
               @"wrong-kind nested attribute is denied");

        [session invalidate];
        Expect(![session isActive] && ![operation isValid] && ![relation isValid] &&
               IsUndefined([session invokeSnapshot:operation memberName:@"operator" arguments:@[]]),
               @"parent invalidation makes retained snapshots stale and unusable");

        std::cout << "[verify-legacy-ui-compatibility-native-snapshot][ ok ] "
                  << "immutable nested snapshots, typed dispatch, and stale binding"
                  << std::endl;
    }
    return 0;
}
