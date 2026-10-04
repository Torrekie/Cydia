/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/NativeAccessibilityJournal.h"
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
const NSUInteger MaximumEvents = 512;
const NSUInteger MaximumBytes = 2 * 1024 * 1024;
const NSUInteger MaximumRecordBytes = 256 * 1024;
const NSUInteger IncompleteReserve = 2048;

BOOL SafePath(id path) {
    return [path isKindOfClass:[NSString class]] && [path length] > 0 &&
        [path length] <= 1024 && [path hasPrefix:@"/"] &&
        [path rangeOfString:@".."].location == NSNotFound &&
        [path rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}
} // namespace

@implementation CydiaNativeAccessibilityJournal {
    int descriptor_;
    BOOL healthy_;
    NSUInteger sequence_;
    NSUInteger bytes_;
    NSString *processInstance_;
}

- (instancetype)initWithEnvironment:(NSDictionary *)environment
                     runtimeVersion:(NSString *)runtimeVersion {
    if ((self = [super init]) == nil)
        return nil;
    descriptor_ = -1;
    id path([environment isKindOfClass:[NSDictionary class]] ?
        environment[@"CYDIA_NATIVE_AX_TRACE_PATH"] : nil);
    if (!SafePath(path) || ![runtimeVersion isKindOfClass:[NSString class]] ||
        [runtimeVersion length] == 0 || [runtimeVersion length] > 128)
        return nil;
    descriptor_ = open([path fileSystemRepresentation],
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor_ < 0)
        return nil;
    struct stat status;
    if (fstat(descriptor_, &status) != 0 || !S_ISREG(status.st_mode))
        return nil;
    healthy_ = YES;
    processInstance_ = [[NSUUID UUID] UUIDString];
    [self appendEvent:@"trace_opened" fields:@{
        @"runtimeVersion": runtimeVersion,
        @"sourceAttestation": @"requires-external-installed-binary-provenance",
        @"coverage": @"native-object-snapshots-and-observed-focus-notifications",
        @"installedAcceptance": @"not_claimed",
    }];
    return healthy_ ? self : nil;
}

- (void)dealloc {
    if (descriptor_ >= 0)
        close(descriptor_);
}

- (BOOL)isHealthy {
    @synchronized(self) { return healthy_; }
}

- (BOOL)writeRecord:(NSDictionary *)record {
    NSMutableDictionary *row([record mutableCopy]);
    row[@"schema"] = @2;
    row[@"sequence"] = @(sequence_);
    row[@"processID"] = @((unsigned int)getpid());
    row[@"processInstance"] = processInstance_;
    row[@"uptime"] = @([NSProcessInfo processInfo].systemUptime);
    NSData *json([NSJSONSerialization dataWithJSONObject:row options:0 error:NULL]);
    if (json == nil || [json length] + 1 > MaximumRecordBytes ||
        bytes_ + [json length] + 1 > MaximumBytes)
        return NO;
    NSMutableData *line([json mutableCopy]);
    [line appendBytes:"\n" length:1];
    const char *data((const char *)[line bytes]);
    NSUInteger remaining([line length]);
    while (remaining != 0) {
        ssize_t written(write(descriptor_, data, remaining));
        if (written < 0 && errno == EINTR)
            continue;
        if (written <= 0)
            return NO;
        data += written;
        remaining -= (NSUInteger)written;
    }
    int result;
    do { result = fsync(descriptor_); } while (result < 0 && errno == EINTR);
    if (result != 0)
        return NO;
    bytes_ += [line length];
    ++sequence_;
    return YES;
}

- (void)stopWithReason:(NSString *)reason {
    /* Partial I/O is still possible; consumers must reject malformed JSONL.
     * Reserved space provides an explicit terminal marker for budget limits. */
    [self writeRecord:@{@"event": @"trace_incomplete", @"reason": reason}];
    healthy_ = NO;
}

- (void)appendEvent:(NSString *)event fields:(NSDictionary *)fields {
    @synchronized(self) {
        if (!healthy_)
            return;
        if (sequence_ >= MaximumEvents - 1) {
            [self stopWithReason:@"event_limit"];
            return;
        }
        if (![event isKindOfClass:[NSString class]] || [event length] == 0 ||
            [event length] > 64 || ![fields isKindOfClass:[NSDictionary class]] ||
            ![NSJSONSerialization isValidJSONObject:fields]) {
            [self stopWithReason:@"invalid_record"];
            return;
        }
        NSMutableDictionary *row([fields mutableCopy]);
        row[@"event"] = event;
        NSData *json([NSJSONSerialization dataWithJSONObject:row options:0 error:NULL]);
        if (json == nil || [json length] + IncompleteReserve > MaximumRecordBytes ||
            bytes_ + [json length] + 2 * IncompleteReserve > MaximumBytes) {
            [self stopWithReason:@"byte_limit"];
            return;
        }
        if (![self writeRecord:row])
            [self stopWithReason:@"io_failure"];
    }
}
@end
