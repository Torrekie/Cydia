/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Modified work Copyright (C) 2026       Torrekie
 */
#include "Cydia/DatabaseConfigurationInternal.h"
#include "Cydia/DpkgConffile.hpp"
#include "Cydia/DpkgStatusParser.hpp"
#include "Cydia/ProgressEvent.h"
#include "CyteKit/Localize.h"

#include <cstdio>
#include <cstring>

#define lprintf(args...) fprintf(stderr, args)

static NSString * const kCydiaProgressEventTypeError = @"Error";
static NSString * const kCydiaProgressEventTypeStatus = @"Status";

@implementation Database (ConfigurationInternal)

- (void) initializeConfigurationPrompts {
    __weak Database *database = self;
    CydiaRuntime::Dpkg::ConffileCallbacks conffiles;
    conffiles.status = [database](const std::string &line) {
        @autoreleasepool { [database _processDpkgStatusLine:line]; }
    };
    conffiles.question = [database](const CydiaRuntime::Dpkg::ConffilePrompt &question) {
        @autoreleasepool {
            Database *strong = database;
            if (!strong) return;
            NSString *path = [[NSString alloc] initWithBytes:question.oldPath.data() length:question.oldPath.size()
                encoding:NSUTF8StringEncoding];
            if (!path) path = [[NSString alloc] initWithBytes:question.oldPath.data() length:question.oldPath.size()
                encoding:NSISOLatin1StringEncoding];
            NSDictionary *prompt = @{@"execution": @(question.execution), @"question": @(question.question), @"path": path ?: @""};
            [strong->delegate_ performSelectorOnMainThread:@selector(setConfigurationPrompt:)
                withObject:prompt waitUntilDone:NO];
        }
    };
    conffiles.invalidated = [database](std::uint64_t execution, std::uint64_t question) {
        @autoreleasepool {
            Database *strong = database;
            if (!strong) return;
            NSDictionary *prompt = @{@"execution": @(execution), @"question": @(question)};
            [strong->delegate_ performSelectorOnMainThread:@selector(dismissConfigurationPrompt:)
                withObject:prompt waitUntilDone:NO];
        }
    };
    conffiles.unavailable = [database]() {
        @autoreleasepool {
            Database *strong = database;
            if (!strong) return;
            NSString *message = [NSString stringWithFormat:@"%@\n%@", UCLocalize("CONFIGURATION_UPGRADE"),
                [[NSBundle mainBundle] localizedStringForKey:@"OPERATION_FAILED" value:nil table:@"RuntimeProvider"]];
            [strong->delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message
                ofType:kCydiaProgressEventTypeError] forTask:UCLocalize("CONFIGURATION_UPGRADE")];
        }
    };
    CydiaRuntime::Dpkg::SetConffileCallbacks(conffiles);
}

- (void) _processDpkgStatusLine:(const std::string &)line {
    const char *data(line.c_str());
    lprintf("S:%s\n", data);
    // Only the execution-owned reader may create an answerable question.
    // A legacy/unscoped notification remains diagnostic text, never authority
    // to write into a shared stdin pipe.
    if (strncmp(data, "status: ", 8) == 0) {
        // status: <package>: {unpacked,half-configured,installed}
        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:(data + 8)] ofType:kCydiaProgressEventTypeStatus]);
        [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
    } else if (strncmp(data, "processing: ", 12) == 0) {
        // processing: configure: config-test
        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:(data + 12)] ofType:kCydiaProgressEventTypeStatus]);
        [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
    } else {
        CydiaRuntime::Dpkg::PackageManagerProgressRecord record;
        if (!CydiaRuntime::Dpkg::ParsePackageManagerProgress(line, &record)) {
            lprintf("E:unknown status\n");
            return;
        }

        NSString *package = [NSString stringWithUTF8String:record.package.c_str()];
        if ([package isEqualToString:@"dpkg-exec"])
            package = nil;

        [progress_ performSelectorOnMainThread:@selector(setProgressPercent:) withObject:[NSNumber numberWithDouble:(record.percent / 100)] waitUntilDone:YES];

        NSString *string = [NSString stringWithUTF8String:record.message.c_str()];

        if (record.type == "pmerror") {
            CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:string ofType:kCydiaProgressEventTypeError forPackage:package]);
            [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
        } else if (record.type == "pmstatus") {
            CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:string ofType:kCydiaProgressEventTypeStatus forPackage:package]);
            [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
        } else
            lprintf("E:unknown pmstatus\n");
    }
}

@end

@implementation Database (Configuration)

- (BOOL) isConfigurationPromptCurrent:(NSDictionary *)prompt {
    return CydiaRuntime::Dpkg::IsCurrentConffilePrompt([[prompt objectForKey:@"execution"] unsignedLongLongValue],
        [[prompt objectForKey:@"question"] unsignedLongLongValue]);
}
- (BOOL) answerConfigurationPrompt:(NSDictionary *)prompt keepOld:(BOOL)keepOld {
    return CydiaRuntime::Dpkg::AnswerConffilePrompt([[prompt objectForKey:@"execution"] unsignedLongLongValue],
        [[prompt objectForKey:@"question"] unsignedLongLongValue], keepOld);
}

@end
