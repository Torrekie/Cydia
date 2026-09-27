/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacyUICompatibilityRuntimeEvidence.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

@interface EvidenceDecisionSession : NSObject
@property(nonatomic) NSUInteger decisionCount;
@property(nonatomic) NSUInteger invokeCount;
@end

@implementation EvidenceDecisionSession

- (CydiaLegacyUICompatibilityDecision *) decisionForScope:(NSString *)scope
                                                memberKind:(CydiaLegacyBridgeMemberKind)memberKind
                                                memberName:(NSString *)memberName
                                                 arguments:(NSArray *)arguments
                                              targetOrigin:(NSURL *)targetOrigin {
    (void)scope;
    (void)memberKind;
    (void)memberName;
    (void)arguments;
    (void)targetOrigin;
    ++_decisionCount;
    /* A nil decision models a target that cannot attest a policy evaluation;
     * the receipt must retain that distinction instead of fabricating an
     * allow/deny result. */
    return nil;
}

- (id) invokeScope:(NSString *)scope
         memberKind:(CydiaLegacyBridgeMemberKind)memberKind
         memberName:(NSString *)memberName
          arguments:(NSArray *)arguments
       targetOrigin:(NSURL *)targetOrigin {
    (void)scope;
    (void)memberKind;
    (void)memberName;
    (void)arguments;
    (void)targetOrigin;
    ++_invokeCount;
    return nil;
}

@end

namespace {

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    std::cerr << "[verify-legacy-runtime-evidence][FAIL] "
              << ([message UTF8String] ?: "failure") << std::endl;
    std::exit(1);
}

NSSet *Set(NSArray *values) {
    return [NSSet setWithArray:values];
}

void VerifySchemaAndAccounting(NSDictionary *receipt) {
    Expect([receipt isKindOfClass:[NSDictionary class]], @"receipt is a dictionary");
    Expect(Set([receipt allKeys]).count == 9 &&
        [Set([receipt allKeys]) isEqualToSet:Set(@[
            @"schema", @"kind", @"mode", @"runID", @"identity",
            @"callerContext", @"counts", @"mutationMode", @"members"])] ,
        @"top-level schema is stable");
    Expect([[receipt objectForKey:@"schema"] unsignedIntegerValue] == 1 &&
        [[receipt objectForKey:@"mode"] isEqualToString:@"decision-only"],
        @"schema and mode are explicit");

    NSDictionary *counts([receipt objectForKey:@"counts"]);
    Expect([[counts objectForKey:@"members"] unsignedIntegerValue] == 152 &&
        [[counts objectForKey:@"expectedAllow"] unsignedIntegerValue] == 87 &&
        [[counts objectForKey:@"expectedDeny"] unsignedIntegerValue] == 65,
        @"receipt carries the exact 152/87/65 policy accounting");
    NSArray *rows([receipt objectForKey:@"members"]);
    Expect([rows count] == 152, @"receipt contains exactly 152 rows");

    NSMutableSet *identities([NSMutableSet setWithCapacity:[rows count]]);
    NSSet *rowKeys(Set(@[
        @"identity", @"scope", @"kind", @"name", @"family", @"sourceForm",
        @"callerContext", @"policyDecision", @"signature", @"target",
        @"dispatchStatus", @"resultShape"]));
    NSSet *policyKeys(Set(@[
        @"expected", @"actual", @"actualReason", @"authorizationReason"]));
    for (NSDictionary *row in rows) {
        Expect([row isKindOfClass:[NSDictionary class]] &&
            [Set([row allKeys]) isEqualToSet:rowKeys], @"row schema is stable");
        NSString *identity([row objectForKey:@"identity"]);
        Expect([identity isKindOfClass:[NSString class]] &&
            ![identities containsObject:identity], @"row identities are unique");
        [identities addObject:identity];
        NSDictionary *policy([row objectForKey:@"policyDecision"]);
        Expect([Set([policy allKeys]) isEqualToSet:policyKeys],
            @"policy decision remains separate from dispatch status");
        Expect([[row objectForKey:@"resultShape"] isEqualToString:@"not_observed"],
            @"decision-only rows never claim an observed result");
    }
    Expect([identities count] == 152, @"all stable identities are represented");

    NSDictionary *mutation([receipt objectForKey:@"mutationMode"]);
    Expect([[mutation objectForKey:@"status"] isEqualToString:@"disabled"] &&
        ![[mutation objectForKey:@"automated"] boolValue] &&
        [[mutation objectForKey:@"singleCasePerRun"] boolValue] &&
        [[mutation objectForKey:@"authorizationRequired"] boolValue] &&
        [[mutation objectForKey:@"prompt"] isEqualToString:@"not-presented"],
        @"mutation mode is an explicit disabled placeholder");
}

void VerifyDecisionOnlyNoInvocation(void) {
    EvidenceDecisionSession *session([[EvidenceDecisionSession alloc] init]);
    NSDictionary *sessions(@{
        @"CydiaObject": session,
        @"Package": session,
        @"Source": session,
        @"NSDictionary": session,
    });
    NSDictionary *receipt(CydiaLegacyUICompatibilityRuntimeEvidenceBuildReceipt(
        @"unit-run", @{
            @"expectedSourceCommit": @"commit-for-test",
            @"expectedSourceTreeSHA256": @"tree-for-test",
            @"expectedVersion": @"version-for-test",
            @"runtimeVersion": @"runtime-for-test",
            @"processID": @123,
        }, sessions));
    VerifySchemaAndAccounting(receipt);
    Expect([session decisionCount] != 0 && [session invokeCount] == 0,
        @"manifest asks only for decisions and never invokes a member");

    NSArray *rows([receipt objectForKey:@"members"]);
    for (NSDictionary *row in rows) {
        NSString *family([row objectForKey:@"family"]);
        NSString *scope([row objectForKey:@"scope"]);
        if ([family isEqualToString:@"mutation"] &&
            ([scope isEqualToString:@"CydiaObject"] ||
             [scope isEqualToString:@"Package"] ||
             [scope isEqualToString:@"Source"]))
            Expect([[row objectForKey:@"dispatchStatus"]
                isEqualToString:@"not_dispatched_mutation_disabled"],
                @"mutation rows remain non-dispatched");
        if ([scope isEqualToString:@"CyteObject"] &&
            ([[row objectForKey:@"name"] isEqualToString:@"supports"] ||
             [[row objectForKey:@"name"] isEqualToString:@"isReachable"]))
            Expect([[row objectForKey:@"dispatchStatus"]
                isEqualToString:@"not_dispatched_no_production_target"],
                @"CyteObject target gaps are explicit");
    }
}

void VerifyRenderingSessionLane(void) {
    EvidenceDecisionSession *session([[EvidenceDecisionSession alloc] init]);
    NSDictionary *receipt(CydiaLegacyUICompatibilityRuntimeEvidenceBuildReceipt(
        @"rendering-run", @{}, @{@"CyteObject": session}));
    NSArray *rows([receipt objectForKey:@"members"]);
    BOOL found(NO);
    for (NSDictionary *row in rows) {
        if (![[row objectForKey:@"scope"] isEqualToString:@"CyteObject"] ||
            ![[row objectForKey:@"name"] isEqualToString:@"supports"])
            continue;
        found = YES;
        NSDictionary *target([row objectForKey:@"target"]);
        Expect([[target objectForKey:@"availability"] isEqualToString:@"available"] &&
            [[target objectForKey:@"reason"] isEqualToString:@"typed-native-session"],
            @"a supplied rendering session is represented as an available target");
        Expect([[row objectForKey:@"dispatchStatus"]
            isEqualToString:@"not_dispatched_decision_unavailable"],
            @"rendering evidence remains decision-only when attestation is unavailable");
    }
    Expect(found && [session decisionCount] != 0 && [session invokeCount] == 0,
        @"rendering session evaluates policy without invoking a member");
}

void VerifyPathBoundsAndAtomicWrite(void) {
    char directoryTemplate[] = "/tmp/cydia-runtime-evidence-test.XXXXXX";
    char *directory(mkdtemp(directoryTemplate));
    Expect(directory != NULL, @"allocate bounded test directory");
    NSString *directoryPath([NSString stringWithUTF8String:directory]);
    NSString *path([directoryPath stringByAppendingPathComponent:@"receipt.json"]);
    NSError *error(nil);
    Expect(CydiaLegacyUICompatibilityRuntimeEvidenceWriteReceipt(path, @"path-run",
        @{}, @{}, &error) && error == nil, @"write a new receipt atomically");
    NSData *data([NSData dataWithContentsOfFile:path]);
    NSError *parseError(nil);
    NSDictionary *parsed([NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError]);
    VerifySchemaAndAccounting(parsed);
    Expect(!CydiaLegacyUICompatibilityRuntimeEvidenceWriteReceipt(path, @"path-run-2",
        @{}, @{}, &error), @"existing receipt cannot be clobbered");
    Expect(!CydiaLegacyUICompatibilityRuntimeEvidenceWriteReceipt(@"relative.json",
        @"path-run-3", @{}, @{}, &error), @"relative output path is rejected");
    NSString *traversal([directoryPath stringByAppendingPathComponent:@"../escape.json"]);
    Expect(!CydiaLegacyUICompatibilityRuntimeEvidenceWriteReceipt(traversal,
        @"path-run-4", @{}, @{}, &error), @"traversal output path is rejected");
    unlink([path fileSystemRepresentation]);
    rmdir([directoryPath fileSystemRepresentation]);
}

} // namespace

int main(void) {
    @autoreleasepool {
        VerifyDecisionOnlyNoInvocation();
        VerifyRenderingSessionLane();
        VerifyPathBoundsAndAtomicWrite();
        std::cout << "[verify-legacy-runtime-evidence][ ok ] bounded 152-row decision-only receipt"
                  << std::endl;
    }
    return 0;
}
