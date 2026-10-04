/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/NativeMutationEvidence.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

const NSUInteger MaximumEvents = 512;
const NSUInteger MaximumRequests = 32;
const NSUInteger MaximumBytes = 256 * 1024;

BOOL SafeToken(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0 ||
        [value length] > 128)
        return NO;
    NSCharacterSet *allowed([NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"]);
    return [value rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

BOOL SafePath(id path) {
    if (![path isKindOfClass:[NSString class]] || [path length] > 1024 ||
        ![path isAbsolutePath] ||
        [path rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound)
        return NO;
    for (NSString *component in [path pathComponents])
        if ([component isEqualToString:@"."] || [component isEqualToString:@".."])
            return NO;
    if (![[path stringByStandardizingPath] isEqualToString:path])
        return NO;
    struct stat status;
    return lstat([[path stringByDeletingLastPathComponent] fileSystemRepresentation],
        &status) == 0 && S_ISDIR(status.st_mode);
}

NSSet *EventNames(void) {
    return [NSSet setWithArray:@[@"presentation_requested", @"presented",
        @"presentation_rejected", @"confirm_callback", @"cancel_callback",
        @"duplicate_callback_suppressed", @"wrong_thread_rejected",
        @"execution_entered", @"effect_returned", @"authority_rejected",
        @"cancelled", @"request_finished"]];
}

} // namespace

@implementation CydiaNativeMutationEvidence {
    int descriptor_;
    BOOL healthy_;
    NSUInteger sequence_;
    NSUInteger bytes_;
    NSMapTable *identities_;
    NSMutableSet *requests_;
}

- (instancetype) initWithEnvironment:(NSDictionary *)environment
                       runtimeVersion:(NSString *)runtimeVersion {
    if ((self = [super init]) == nil)
        return nil;
    descriptor_ = -1;
    if (![environment isKindOfClass:[NSDictionary class]])
        return nil;
    NSString *path([environment objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_MUTATION_EVIDENCE_PATH"]);
    NSString *runID([environment objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_EVIDENCE_RUN_ID"]);
    if (!SafePath(path) || !SafeToken(runID) || !SafeToken(runtimeVersion)) {
        if (path != nil || runID != nil)
            NSLog(@"Cydia native compatibility mutation evidence unavailable: invalid environment path=%@ pathSafe=%d runIDSafe=%d runtimeSafe=%d",
                path, SafePath(path), SafeToken(runID), SafeToken(runtimeVersion));
        return nil;
    }
    descriptor_ = open([path fileSystemRepresentation],
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor_ < 0) {
        NSLog(@"Cydia native compatibility mutation evidence unavailable: open failed errno=%d path=%@",
            errno, path);
        return nil;
    }
    healthy_ = YES;
    identities_ = [NSMapTable mapTableWithKeyOptions:
        NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
        valueOptions:NSPointerFunctionsStrongMemory];
    requests_ = [NSMutableSet set];
    [self append:@{
        @"schema": @1, @"event": @"journal_opened", @"runID": runID,
        @"runtimeVersion": runtimeVersion, @"processID": @((unsigned int)getpid()),
        @"processInstance": [[NSUUID UUID] UUIDString],
        @"callerContext": @"trusted_native_provider",
        @"sourceAttestation": @"runtime-version-requires-external-binary-provenance",
        @"persistence": @"unverified", @"installedAcceptance": @"not_claimed",
        @"coverage": @"native-confirmation-callbacks-not-package-transactions",
    }];
    if (!healthy_)
        NSLog(@"Cydia native compatibility mutation evidence unavailable: journal_opened write failed errno=%d path=%@",
            errno, path);
    return healthy_ ? self : nil;
}

- (void) dealloc {
    if (descriptor_ >= 0)
        close(descriptor_);
}

- (BOOL) isHealthy {
    @synchronized (self) { return healthy_; }
}

- (BOOL) writeLine:(NSData *)json {
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

- (void) stopWithReason:(NSString *)reason {
    /* Reserve one record and 2 KiB for a fail-closed marker. I/O failures may
     * still leave a partial line; consumers must reject partial journals. */
    NSData *marker([NSJSONSerialization dataWithJSONObject:@{
        @"event": @"journal_incomplete", @"sequence": @(sequence_), @"reason": reason
    } options:0 error:NULL]);
    if (marker != nil && bytes_ + [marker length] + 1 <= MaximumBytes)
        [self writeLine:marker];
    healthy_ = NO;
}

- (void) append:(NSDictionary *)record {
    @synchronized (self) {
        if (!healthy_)
            return;
        if (sequence_ >= MaximumEvents - 1) {
            [self stopWithReason:@"event_limit"];
            return;
        }
        NSMutableDictionary *row([record mutableCopy]);
        [row setObject:@(sequence_) forKey:@"sequence"];
        NSData *json([NSJSONSerialization dataWithJSONObject:row options:0 error:NULL]);
        if (json == nil || bytes_ + [json length] + 2048 > MaximumBytes) {
            [self stopWithReason:@"byte_limit_or_encoding_failure"];
            return;
        }
        if (![self writeLine:json])
            [self stopWithReason:@"io_failure"];
    }
}

- (NSString *) identityForObject:(id)object {
    if (object == nil)
        return nil;
    NSString *identity([identities_ objectForKey:object]);
    if (identity == nil) {
        identity = [[NSUUID UUID] UUIDString];
        [identities_ setObject:identity forKey:object];
    }
    return identity;
}

- (NSString *) beginRequestWithSession:(id)session target:(id)target
                            presenter:(id)presenter operation:(NSString *)operation
                           effectKind:(NSString *)effectKind {
    @synchronized (self) {
        if (!healthy_ || session == nil || target == nil || presenter == nil ||
            !SafeToken(operation) || ![@[@"typed-provider-call", @"metadata-set",
                @"metadata-remove"] containsObject:effectKind])
            return nil;
        if ([requests_ count] >= MaximumRequests) {
            [self stopWithReason:@"request_limit"];
            return nil;
        }
        NSString *request([[NSUUID UUID] UUIDString]);
        [requests_ addObject:request];
        [self append:@{@"event": @"request_created", @"requestID": request,
            @"sessionID": [self identityForObject:session],
            @"targetID": [self identityForObject:target],
            @"presenterID": [self identityForObject:presenter],
            @"operation": operation, @"effectKind": effectKind}];
        return healthy_ ? request : nil;
    }
}

- (void) recordEvent:(NSString *)event request:(NSString *)request {
    @synchronized (self) {
        if (!healthy_ || request == nil || ![requests_ containsObject:request])
            return;
        if (![EventNames() containsObject:event]) {
            [self stopWithReason:@"invalid_event"];
            return;
        }
        [self append:@{@"event": event, @"requestID": request}];
    }
}

@end

@implementation CydiaNativeMutationAction {
    CydiaNativeMutationEvidence *evidence_;
    NSString *request_;
    BOOL (^execute_)(void);
    BOOL consumed_;
}

- (instancetype) initWithEvidence:(CydiaNativeMutationEvidence *)evidence
                          request:(NSString *)request
                          execute:(BOOL (^)(void))execute {
    if ((self = [super init]) != nil) {
        evidence_ = evidence;
        request_ = [request copy];
        execute_ = [execute copy];
    }
    return self;
}

- (void) event:(NSString *)event {
    [evidence_ recordEvent:event request:request_];
}
- (void) presentationRequested { [self event:@"presentation_requested"]; }
- (void) presented { [self event:@"presented"]; }
- (void) presentationRejected {
    @synchronized (self) { consumed_ = YES; }
    [self event:@"presentation_rejected"];
    [self event:@"request_finished"];
}

- (BOOL) consume {
    if (![NSThread isMainThread]) {
        [self event:@"wrong_thread_rejected"];
        return NO;
    }
    @synchronized (self) {
        if (consumed_) {
            [self event:@"duplicate_callback_suppressed"];
            return NO;
        }
        consumed_ = YES;
        return YES;
    }
}

- (void) accept {
    [self event:@"confirm_callback"];
    if (![self consume])
        return;
    [self event:@"execution_entered"];
    BOOL effected(execute_ != nil && execute_());
    [self event:effected ? @"effect_returned" : @"authority_rejected"];
    [self event:@"request_finished"];
}

- (void) cancel {
    [self event:@"cancel_callback"];
    if (![self consume])
        return;
    [self event:@"cancelled"];
    [self event:@"request_finished"];
}

@end
