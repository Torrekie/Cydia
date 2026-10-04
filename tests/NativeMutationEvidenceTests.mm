/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/NativeMutationEvidence.h"
#include <dispatch/dispatch.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

namespace {

void Expect(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "[native-mutation-evidence][FAIL] %s\n", [message UTF8String]);
        exit(1);
    }
}

NSDictionary *Environment(NSString *path) {
    return @{@"CYDIA_NATIVE_COMPATIBILITY_MUTATION_EVIDENCE_PATH": path,
        @"CYDIA_NATIVE_COMPATIBILITY_EVIDENCE_RUN_ID": @"host-unit-test"};
}

NSArray *Read(NSString *path) {
    NSData *bytes([NSData dataWithContentsOfFile:path]);
    NSString *text([[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]);
    Expect([text hasSuffix:@"\n"], @"journal has no partial last line");
    NSMutableArray *rows([NSMutableArray array]);
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line length] == 0)
            continue;
        NSDictionary *row([NSJSONSerialization JSONObjectWithData:
            [line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]);
        Expect([row isKindOfClass:[NSDictionary class]], @"every event is JSON");
        Expect([[row objectForKey:@"sequence"] unsignedIntegerValue] == [rows count],
            @"event sequence is contiguous");
        [rows addObject:row];
    }
    return rows;
}

NSUInteger Count(NSArray *rows, NSString *request, NSString *event) {
    NSUInteger count(0);
    for (NSDictionary *row in rows)
        if ([[row objectForKey:@"requestID"] isEqualToString:request] &&
            [[row objectForKey:@"event"] isEqualToString:event])
            ++count;
    return count;
}

void VerifyActions(NSString *path) {
    CydiaNativeMutationEvidence *journal([[CydiaNativeMutationEvidence alloc]
        initWithEnvironment:Environment(path) runtimeVersion:@"host-test-version"]);
    Expect([journal isHealthy], @"explicit host journal opened");
    struct stat status;
    Expect(stat([path fileSystemRepresentation], &status) == 0 &&
        (status.st_mode & 0777) == 0600, @"journal is owner-only");
    NSObject *session([[NSObject alloc] init]);
    NSObject *target([[NSObject alloc] init]);
    NSObject *presenter([[NSObject alloc] init]);
    __block NSUInteger effects(0);
    NSMutableDictionary *values([NSMutableDictionary dictionary]);

    NSString *cancel([journal beginRequestWithSession:session target:target
        presenter:presenter operation:@"CydiaObject.setMetadataValue" effectKind:@"metadata-set"]);
    CydiaNativeMutationAction *cancelAction([[CydiaNativeMutationAction alloc]
        initWithEvidence:journal request:cancel execute:^BOOL { ++effects; return YES; }]);
    [cancelAction presentationRequested];
    [cancelAction presented];
    [cancelAction cancel];
    [cancelAction accept];
    [cancelAction cancel];
    Expect(effects == 0, @"Cancel and replay have zero effects");

    NSString *set([journal beginRequestWithSession:session target:target
        presenter:presenter operation:@"CydiaObject.setMetadataValue" effectKind:@"metadata-set"]);
    CydiaNativeMutationAction *setAction([[CydiaNativeMutationAction alloc]
        initWithEvidence:journal request:set execute:^BOOL {
            ++effects;
            [values setObject:@"private-test-value" forKey:@"private-test-key"];
            return YES;
        }]);
    [setAction presentationRequested];
    [setAction presented];
    [setAction accept];
    [setAction accept];
    [setAction cancel];
    Expect(effects == 1 && [values count] == 1, @"accepted set body executes once");

    NSString *remove([journal beginRequestWithSession:session target:target
        presenter:presenter operation:@"CydiaObject.setMetadataValue" effectKind:@"metadata-remove"]);
    CydiaNativeMutationAction *removeAction([[CydiaNativeMutationAction alloc]
        initWithEvidence:journal request:remove execute:^BOOL {
            ++effects;
            [values removeObjectForKey:@"private-test-key"];
            return YES;
        }]);
    [removeAction presentationRequested];
    [removeAction presented];
    [removeAction accept];
    [removeAction accept];
    Expect(effects == 2 && [values count] == 0, @"accepted remove body executes once");

    for (NSString *revoked in @[@"session", @"target", @"presenter"]) {
        __block BOOL authority(NO);
        NSString *request([journal beginRequestWithSession:session target:target
            presenter:presenter operation:revoked effectKind:@"typed-provider-call"]);
        CydiaNativeMutationAction *action([[CydiaNativeMutationAction alloc]
            initWithEvidence:journal request:request execute:^BOOL {
                if (!authority) return NO;
                ++effects;
                return YES;
            }]);
        [action accept];
        authority = YES;
        [action accept];
        NSArray *rows(Read(path));
        Expect(Count(rows, request, @"authority_rejected") == 1 &&
            Count(rows, request, @"effect_returned") == 0,
            @"revoked authority consumes the request without effects");
    }

    NSString *offMain([journal beginRequestWithSession:session target:target
        presenter:presenter operation:@"wrong-thread" effectKind:@"typed-provider-call"]);
    CydiaNativeMutationAction *offMainAction([[CydiaNativeMutationAction alloc]
        initWithEvidence:journal request:offMain execute:^BOOL { ++effects; return YES; }]);
    dispatch_semaphore_t finished(dispatch_semaphore_create(0));
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [offMainAction accept];
        dispatch_semaphore_signal(finished);
    });
    Expect(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW,
        5 * NSEC_PER_SEC)) == 0, @"bounded off-main callback finished");
    Expect(effects == 2, @"off-main invocation has no effect");
    [offMainAction accept];
    Expect(effects == 3, @"a main-thread callback may consume the unused gate");

    NSString *unpresented([journal beginRequestWithSession:session target:target
        presenter:presenter operation:@"no-presenter" effectKind:@"typed-provider-call"]);
    CydiaNativeMutationAction *rejected([[CydiaNativeMutationAction alloc]
        initWithEvidence:journal request:unpresented execute:^BOOL { ++effects; return YES; }]);
    [rejected presentationRejected];
    [rejected accept];
    Expect(effects == 3, @"rejected presentation cannot later execute");

    NSArray *rows(Read(path));
    Expect(Count(rows, cancel, @"cancelled") == 1 && Count(rows, cancel, @"effect_returned") == 0,
        @"Cancel has explicit zero-effect terminal evidence");
    for (NSString *request in @[set, remove])
        Expect(Count(rows, request, @"effect_returned") == 1 &&
            Count(rows, request, @"duplicate_callback_suppressed") != 0 &&
            Count(rows, request, @"request_finished") == 1,
            @"effect records are distinct from replay and completion");
    NSDictionary *header([rows objectAtIndex:0]);
    Expect([[header objectForKey:@"persistence"] isEqualToString:@"unverified"] &&
        [[header objectForKey:@"installedAcceptance"] isEqualToString:@"not_claimed"],
        @"observation does not assert persistence or installed acceptance");
    NSString *wire([[NSString alloc] initWithData:[NSData dataWithContentsOfFile:path]
        encoding:NSUTF8StringEncoding]);
    Expect([wire rangeOfString:@"private-test"].location == NSNotFound,
        @"no metadata keys or values in the journal");
    NSMutableSet *sessionIDs([NSMutableSet set]);
    for (NSDictionary *row in rows)
        if ([row objectForKey:@"sessionID"] != nil)
            [sessionIDs addObject:[row objectForKey:@"sessionID"]];
    Expect([sessionIDs count] == 1, @"session identity is stable and opaque within the process");
    Expect([journal isHealthy], @"normal journal remains healthy");
}

void VerifyNoClobberAndBounds(NSString *directory) {
    NSString *absent([directory stringByAppendingPathComponent:@"absent.jsonl"]);
    Expect([[CydiaNativeMutationEvidence alloc] initWithEnvironment:@{}
        runtimeVersion:@"test"] == nil, @"default launch has no journal");
    NSMutableDictionary *bad([Environment(absent) mutableCopy]);
    [bad setObject:@"bad/run" forKey:@"CYDIA_NATIVE_COMPATIBILITY_EVIDENCE_RUN_ID"];
    Expect([[CydiaNativeMutationEvidence alloc] initWithEnvironment:bad
        runtimeVersion:@"test"] == nil && access([absent fileSystemRepresentation], F_OK) != 0,
        @"unsafe run token cannot create a file");
    for (NSString *path in @[@"relative.jsonl", [directory stringByAppendingString:@"/../escape.jsonl"]])
        Expect([[CydiaNativeMutationEvidence alloc] initWithEnvironment:Environment(path)
            runtimeVersion:@"test"] == nil, @"unsafe destination rejected");
    NSString *existing([directory stringByAppendingPathComponent:@"actions.jsonl"]);
    NSData *preimage([NSData dataWithContentsOfFile:existing]);
    Expect([[CydiaNativeMutationEvidence alloc] initWithEnvironment:Environment(existing)
        runtimeVersion:@"test"] == nil, @"existing journal is never overwritten");
    NSString *link([directory stringByAppendingPathComponent:@"symlink.jsonl"]);
    Expect(symlink([existing fileSystemRepresentation], [link fileSystemRepresentation]) == 0,
        @"create owned symlink test fixture");
    Expect([[CydiaNativeMutationEvidence alloc] initWithEnvironment:Environment(link)
        runtimeVersion:@"test"] == nil &&
        [preimage isEqualToData:[NSData dataWithContentsOfFile:existing]], @"symlink target untouched");

    NSString *bounded([directory stringByAppendingPathComponent:@"bounded.jsonl"]);
    CydiaNativeMutationEvidence *journal([[CydiaNativeMutationEvidence alloc]
        initWithEnvironment:Environment(bounded) runtimeVersion:@"test"]);
    NSObject *object([[NSObject alloc] init]);
    NSString *request([journal beginRequestWithSession:object target:object presenter:object
        operation:@"bounded-test" effectKind:@"typed-provider-call"]);
    for (NSUInteger i(0); i != 600; ++i)
        [journal recordEvent:@"presented" request:request];
    NSArray *rows(Read(bounded));
    Expect(![journal isHealthy] && [rows count] <= 512 &&
        [[[rows lastObject] objectForKey:@"event"] isEqualToString:@"journal_incomplete"] &&
        [[NSData dataWithContentsOfFile:bounded] length] <= 256 * 1024,
        @"bounded journal explicitly marks incomplete coverage");
    __block NSUInteger effects(0);
    CydiaNativeMutationAction *normal([[CydiaNativeMutationAction alloc]
        initWithEvidence:journal request:request execute:^BOOL { ++effects; return YES; }]);
    [normal accept];
    [normal accept];
    Expect(effects == 1, @"failed evidence does not alter normal one-shot mutation behavior");
}

int VerifyJournal(NSString *script, NSString *path, NSString *outcome, NSString *version) {
    const char *arguments[] = {"sh", [script fileSystemRepresentation], [path fileSystemRepresentation],
        "host-unit-test", [version UTF8String], "CydiaObject.setMetadataValue",
        "metadata-set", [outcome UTF8String], NULL};
    pid_t pid;
    Expect(posix_spawn(&pid, "/bin/sh", NULL, NULL, (char * const *)arguments, environ) == 0,
        @"spawn journal verifier");
    int status;
    Expect(waitpid(pid, &status, 0) == pid && WIFEXITED(status), @"journal verifier exited");
    return WEXITSTATUS(status);
}

void VerifyConsumption(NSString *directory, NSString *script) {
    NSString *path([directory stringByAppendingPathComponent:@"single.jsonl"]);
    CydiaNativeMutationEvidence *journal([[CydiaNativeMutationEvidence alloc]
        initWithEnvironment:Environment(path) runtimeVersion:@"host-test-version"]);
    NSObject *object([[NSObject alloc] init]);
    NSString *request([journal beginRequestWithSession:object target:object presenter:object
        operation:@"CydiaObject.setMetadataValue" effectKind:@"metadata-set"]);
    CydiaNativeMutationAction *action([[CydiaNativeMutationAction alloc]
        initWithEvidence:journal request:request execute:^BOOL { return YES; }]);
    [action presentationRequested];
    [action presented];
    [action accept];
    [action accept];
    Expect(VerifyJournal(script, path, @"effect", @"host-test-version") == 0,
        @"real writer output passes the single-case consumer");
    Expect(VerifyJournal(script, path, @"cancelled", @"host-test-version") != 0,
        @"effect cannot be relabeled cancellation");
    Expect(VerifyJournal(script, path, @"effect", @"wrong-version") != 0,
        @"wrong installed identity rejected");
    NSData *valid([NSData dataWithContentsOfFile:path]);
    NSString *truncated([directory stringByAppendingPathComponent:@"truncated.jsonl"]);
    [[valid subdataWithRange:NSMakeRange(0, [valid length] - 1)] writeToFile:truncated atomically:YES];
    Expect(VerifyJournal(script, truncated, @"effect", @"host-test-version") != 0,
        @"truncated journal is not a pass");
    [journal recordEvent:@"unknown" request:request];
    Expect(VerifyJournal(script, path, @"effect", @"host-test-version") != 0,
        @"incomplete evidence cannot certify an earlier prefix");
    for (NSString *outcome in @[@"cancelled", @"authority-rejected", @"presentation-rejected"]) {
        NSString *casePath([directory stringByAppendingPathComponent:
            [outcome stringByAppendingString:@".jsonl"]]);
        CydiaNativeMutationEvidence *caseJournal([[CydiaNativeMutationEvidence alloc]
            initWithEnvironment:Environment(casePath) runtimeVersion:@"host-test-version"]);
        NSString *caseID([caseJournal beginRequestWithSession:object target:object presenter:object
            operation:@"CydiaObject.setMetadataValue" effectKind:@"metadata-set"]);
        CydiaNativeMutationAction *caseAction([[CydiaNativeMutationAction alloc]
            initWithEvidence:caseJournal request:caseID execute:^BOOL { return NO; }]);
        if ([outcome isEqualToString:@"presentation-rejected"]) {
            [caseAction presentationRejected];
        } else {
            [caseAction presentationRequested];
            [caseAction presented];
            if ([outcome isEqualToString:@"cancelled"])
                [caseAction cancel];
            else
                [caseAction accept];
        }
        Expect(VerifyJournal(script, casePath, outcome, @"host-test-version") == 0,
            @"consumer accepts only the matching zero-effect outcome");
    }
    __block NSUInteger normalEffects(0);
    CydiaNativeMutationAction *normal([[CydiaNativeMutationAction alloc]
        initWithEvidence:nil request:nil execute:^BOOL { ++normalEffects; return YES; }]);
    [normal accept];
    [normal accept];
    Expect(normalEffects == 1, @"no journal opt-in is required for normal action behavior");
}

} // namespace

int main(int argc, char **argv) {
    @autoreleasepool {
        char pattern[] = "/tmp/cydia-mutation-evidence-test.XXXXXX";
        char *temporary(mkdtemp(pattern));
        Expect(temporary != NULL, @"allocate owned test directory");
        NSString *directory([NSString stringWithUTF8String:temporary]);
        VerifyActions([directory stringByAppendingPathComponent:@"actions.jsonl"]);
        VerifyNoClobberAndBounds(directory);
        Expect(argc == 2, @"journal verifier script supplied");
        VerifyConsumption(directory, [NSString stringWithUTF8String:argv[1]]);
        NSError *error(nil);
        Expect([[NSFileManager defaultManager] removeItemAtPath:directory error:&error],
            @"remove only the owned test fixture directory");
        puts("[native-mutation-evidence][ ok ] shared one-shot action and bounded journal; host-only, not installed provider/persistence evidence");
    }
    return 0;
}
