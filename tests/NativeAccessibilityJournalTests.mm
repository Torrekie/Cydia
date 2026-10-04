/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/NativeAccessibilityJournal.h"
#include "Cydia/NativeAccessibilityColor.h"
#include <sys/stat.h>
#include <unistd.h>

namespace {
NSUInteger checks(0);
void Expect(BOOL value, const char *message) {
    ++checks;
    if (!value) {
        fprintf(stderr, "[native-accessibility-journal][FAIL] %s\n", message);
        exit(1);
    }
}

CydiaNativeAccessibilityJournal *Open(NSString *path) {
    return [[CydiaNativeAccessibilityJournal alloc] initWithEnvironment:
        @{@"CYDIA_NATIVE_AX_TRACE_PATH": path} runtimeVersion:@"host-test-not-installed"];
}

NSArray *Read(NSString *path) {
    NSString *text([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]);
    Expect([text hasSuffix:@"\n"], "complete JSONL trailing newline");
    NSMutableArray *rows([NSMutableArray array]);
    NSString *identity;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0)
            continue;
        NSDictionary *row([NSJSONSerialization JSONObjectWithData:
            [line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]);
        Expect([row[@"schema"] isEqual:@2], "schema cannot be overwritten by fields");
        Expect([row[@"sequence"] unsignedIntegerValue] == rows.count, "contiguous sequence");
        Expect([row[@"processID"] intValue] == getpid(), "real process identity");
        if (identity == nil)
            identity = row[@"processInstance"];
        Expect(identity.length != 0 && [identity isEqual:row[@"processInstance"]], "stable process instance");
        [rows addObject:row];
    }
    return rows;
}

void Verify(NSString *root) {
    Expect([[CydiaNativeAccessibilityJournal alloc] initWithEnvironment:@{}
        runtimeVersion:@"test"] == nil, "opt-out is inert");
    for (NSString *bad in @[@"", @"relative", @"/tmp/../bad", @"/tmp/bad\nname",
        [@"/" stringByPaddingToLength:1025 withString:@"a" startingAtIndex:0]])
        Expect(Open(bad) == nil, "invalid path rejected before creation");
    NSString *path([root stringByAppendingPathComponent:@"normal.jsonl"]);
    CydiaNativeAccessibilityJournal *journal(Open(path));
    Expect(journal.isHealthy, "explicit trace opened");
    struct stat status;
    Expect(stat(path.fileSystemRepresentation, &status) == 0 &&
        (status.st_mode & 0777) == 0600, "owner-only file");
    NSData *before([NSData dataWithContentsOfFile:path]);
    Expect(Open(path) == nil && [before isEqual:[NSData dataWithContentsOfFile:path]], "existing trace never overwritten");
    NSString *link([root stringByAppendingPathComponent:@"link.jsonl"]);
    Expect(symlink(path.fileSystemRepresentation, link.fileSystemRepresentation) == 0 &&
        Open(link) == nil, "symlink leaf rejected");
    [journal appendEvent:@"focus_changed" fields:@{@"element": @{@"label": @"版本", @"value": @"1.1"},
        @"sequence": @999, @"schema": @0, @"event": @"forged", @"processID": @0}];
    NSArray *rows(Read(path));
    Expect(rows.count == 2 && [rows[1][@"event"] isEqual:@"focus_changed"], "event envelope cannot be forged");
    Expect([rows[0][@"installedAcceptance"] isEqual:@"not_claimed"], "host traces never imply installed proof");

    NSString *limitPath([root stringByAppendingPathComponent:@"events.jsonl"]);
    journal = Open(limitPath);
    for (NSUInteger i = 0; i != 600; ++i)
        [journal appendEvent:@"focus_changed" fields:@{}];
    rows = Read(limitPath);
    Expect(!journal.isHealthy && rows.count == 512 &&
        [rows.lastObject[@"reason"] isEqual:@"event_limit"], "event cap has terminal incomplete marker");

    NSString *bytesPath([root stringByAppendingPathComponent:@"bytes.jsonl"]);
    journal = Open(bytesPath);
    NSString *large([@"x" stringByPaddingToLength:250000 withString:@"x" startingAtIndex:0]);
    for (NSUInteger i = 0; i != 20; ++i)
        [journal appendEvent:@"surface_snapshot" fields:@{@"text": large}];
    rows = Read(bytesPath);
    Expect(!journal.isHealthy && [rows.lastObject[@"reason"] isEqual:@"byte_limit"], "byte cap fails closed");
    Expect([[NSData dataWithContentsOfFile:bytesPath] length] <= 2 * 1024 * 1024, "file byte bound");

    NSString *invalidPath([root stringByAppendingPathComponent:@"invalid.jsonl"]);
    journal = Open(invalidPath);
    [journal appendEvent:@"focus_changed" fields:@{@"invalid": [NSObject new]}];
    rows = Read(invalidPath);
    Expect(!journal.isHealthy && [rows.lastObject[@"reason"] isEqual:@"invalid_record"], "non-JSON payload stops journal");

    using namespace CydiaAccessibilityColor;
    const RGBA white{1, 1, 1, 1}, black{0, 0, 0, 1};
    Expect(std::abs(Contrast(white, black) - 21) < 1e-9, "white-black reference ratio");
    Expect(std::abs(Contrast(black, white) - 21) < 1e-9, "contrast is symmetric for opaque colors");
    Expect(std::abs(Contrast(white, white) - 1) < 1e-9, "identical colors ratio one");
    RGBA half(Over({1, 1, 1, 0.5}, black));
    Expect(half.red == 0.5 && half.alpha == 1, "alpha compositing uses background");
    Expect(std::abs(Contrast({1, 1, 1, 0.5}, black) - 5.2808228096) < 1e-8, "semi-transparent color reference ratio");
    Expect(Over({0, 0, 0, 0}, {0, 0, 0, 0}).alpha == 0, "transparent composite is finite");
}
} // namespace

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Expect(argc == 2, "explicit temporary evidence directory required");
        Verify([NSString stringWithUTF8String:argv[1]]);
        printf("[native-accessibility-journal][ ok ] %lu checks; host only, no OS focus claim\n", (unsigned long)checks);
    }
    return 0;
}
