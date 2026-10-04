/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdlib.h>

/* Host-only model doubles. The tested parser and lookup below are extracted
 * verbatim from NativeMutationDiagnostic.mm, not reimplemented in this test. */
@interface Package : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic) NSUInteger installMarks;
- (NSString *)id;
- (void)install;
@end
@implementation Package
- (NSString *)id { return _identifier; }
- (void)install { ++_installMarks; _mode = @"INSTALL"; }
@end
@interface DerivedPackage : Package
@end
@implementation DerivedPackage
@end
@interface Database : NSObject
@property (nonatomic, copy) NSArray *packages;
@end
@implementation Database
@end

#include "NativePackageMutationDiagnostic.inc"

static void Expect(BOOL value, const char *message) {
    if (!value) {
        fprintf(stderr, "[native-package-mutation-diagnostic][FAIL] %s\n", message);
        exit(1);
    }
}

int main() {
    @autoreleasepool {
        for (NSString *operation in @[
            @"Source.addSection", @"Source.removeSection", @"Source.remove",
            @"CydiaObject.refreshSources", @"CydiaObject.saveConfig",
            @"CydiaObject.addTrivialSource", @"CydiaObject.addSource",
            @"Package.clear", @"Package.install", @"Package.remove",
            @"CydiaObject.installPackages"])
            Expect([CydiaNativeCompatibilityMutationDiagnosticOperationForValue(operation)
                isEqualToString:operation], "every fixed operation is accepted");
        Expect(CydiaNativeCompatibilityMutationDiagnosticOperationForValue(nil) == nil,
            "ordinary launch has no operation");
        for (id invalid in @[@"", @"Package", @"Package.install:", @"Package.install ",
            @"Package.INSTALL", @"CydiaObject.removePackages", @"Package.remove\n",
            @"Package.install;reboot", @42, [NSNull null], @[]])
            Expect(CydiaNativeCompatibilityMutationDiagnosticOperationForValue(invalid) == nil,
                "invalid type, selector or unlisted operation is rejected");

        NSString *identity(CydiaNativeCompatibilityMutationDiagnosticPackageIdentifier());
        Expect([identity isEqualToString:@"com.torrekie.cydia-ui-transaction-fixture"],
            "fixture identity is fixed, not supplied by environment");
        setenv("CYDIA_NATIVE_COMPATIBILITY_B17_FIXTURE", "1", 1);
        Expect([CydiaNativeCompatibilityMutationDiagnosticPackageIdentifier()
            isEqualToString:@"com.example.native-compatibility"],
            "B1.7 opt-in selects only the frozen fixture identity");
        unsetenv("CYDIA_NATIVE_COMPATIBILITY_B17_FIXTURE");
        Package *unrelated([[Package alloc] init]);
        unrelated.identifier = @"cydia";
        Package *fixture([[Package alloc] init]);
        fixture.identifier = identity;
        DerivedPackage *derived([[DerivedPackage alloc] init]);
        derived.identifier = identity;
        Database *database([[Database alloc] init]);
        Expect(CydiaNativeCompatibilityMutationDiagnosticPackage(nil) == nil,
            "missing database cannot select a target");
        database.packages = @[];
        Expect(CydiaNativeCompatibilityMutationDiagnosticPackage(database) == nil,
            "empty database cannot manufacture a target");
        database.packages = @[unrelated, derived, @{ @"id": identity }, [NSNull null]];
        Expect(CydiaNativeCompatibilityMutationDiagnosticPackage(database) == nil,
            "no fallback to unrelated packages, subclasses or lookalike values");
        database.packages = @[unrelated, derived, fixture];
        Expect(CydiaNativeCompatibilityMutationDiagnosticPackage(database) == fixture,
            "returns the exact canonical model from this database");
        database.packages = @[unrelated];
        Expect(CydiaNativeCompatibilityMutationDiagnosticPackage(database) == nil,
            "removed fixture is not retained across database lookups");
        Expect(!CydiaNativeCompatibilityMutationDiagnosticPreparePackage(@"Package.clear", unrelated) &&
            !CydiaNativeCompatibilityMutationDiagnosticPreparePackage(@"Package.clear", derived),
            "Clear setup cannot mark unrelated or subclass targets");
        Expect(CydiaNativeCompatibilityMutationDiagnosticPreparePackage(@"Package.install", fixture) &&
            fixture.installMarks == 0, "other APIs have no implicit fixture setup");
        Expect(CydiaNativeCompatibilityMutationDiagnosticPreparePackage(@"Package.clear", fixture) &&
            fixture.installMarks == 1 && [fixture.mode isEqualToString:@"INSTALL"],
            "Clear gets one explicit in-memory fixture install mark");
        Expect(!CydiaNativeCompatibilityMutationDiagnosticPreparePackage(@"Package.clear", fixture) &&
            fixture.installMarks == 1, "existing queue is preserved and never seeded twice");
        puts("[native-package-mutation-diagnostic][ ok ] fixed parser and canonical fixture lookup");
    }
    return 0;
}
