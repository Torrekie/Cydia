/* Cydia Refurbished native Home model tests.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#include "Cydia/HomeViewModel.h"

#include <cstdlib>
#include <iostream>

static void Require(BOOL condition, NSString *message) {
    if (condition)
        return;
    std::cerr << "[verify-home-view-model][FAIL] " << [message UTF8String] << std::endl;
    std::exit(1);
}

static void RequireString(NSString *actual, NSString *expected, NSString *message) {
    Require(actual == expected || [actual isEqualToString:expected],
        [NSString stringWithFormat:@"%@ (actual=%@ expected=%@)", message, actual, expected]);
}

int main(void) {
    @autoreleasepool {
        RequireString(CydiaHomeVisibleVersion(@"1.1.36+454.g4101661"),
            @"1.1.36+454", @"package build suffix is trimmed like legacy Home");
        RequireString(CydiaHomeVisibleVersion(@"1.1.36"), @"1.1.36",
            @"release version without a build suffix is retained");
        RequireString(CydiaHomeVisibleVersion(@"1.2+abc"), @"1.2+",
            @"legacy version expression permits an empty numeric build");
        RequireString(CydiaHomeVisibleVersion(@"+abc"), @"+",
            @"legacy version expression permits an empty release prefix");
        RequireString(CydiaHomeVisibleVersion(@"１.2+3.tail"), @"１.2+3.tail",
            @"legacy version expression recognizes ASCII digits only");
        RequireString(CydiaHomeVisibleVersion(@"1:1.1.36+454.g4101661"),
            @"1:1.1.36+454.g4101661", @"unexpected version syntax is not rewritten");

        RequireString(CydiaHomeFooterText(@"iPad7,5", @"14.5.1", 64,
            @"1.1.36+454.g4101661", @"zh-Hans", @"legacy-visible-udid"),
            @"iPad7,5, iOS 14.5.1, Cydia64_1.1.36+454 (zh-Hans)\nlegacy-visible-udid",
            @"legacy hardware/version/device footer is exact");
        RequireString(CydiaHomeFooterText(nil, nil, 32, nil, nil, nil),
            @", iOS , Cydia32_ ()", @"unavailable footer fields fail visibly empty");

        NSMutableString *status([NSMutableString stringWithString:@"Complete"]);
        CydiaHomeViewModel *model([[CydiaHomeViewModel alloc]
            initWithSourceCount:7
            packageCount:321
            installedCount:88
            upgradeCount:4
            halfInstalledCount:1
            databaseReady:YES
            databaseEra:42
            status:CydiaHomeStatusReady
            statusMessage:status]);

        Require(model.sourceCount == 7 && model.packageCount == 321,
            @"source/package counts are retained");
        Require(model.installedCount == 88 && model.upgradeCount == 4 &&
                model.halfInstalledCount == 1, @"package state counts are retained");
        Require(model.databaseReady && model.databaseEra == 42,
            @"database readiness and era are retained");
        Require(model.status == CydiaHomeStatusReady, @"status enum is retained");
        status.string = @"mutated";
        RequireString(model.statusMessage, @"Complete", @"status message is copied");
        Require(![model isKindOfClass:[NSMutableArray class]], @"model has the intended type");

        NSArray *statuses(@[
            @[@(CydiaHomeStatusLoading), @"Loading"],
            @[@(CydiaHomeStatusUpdating), @"Updating"],
            @[@(CydiaHomeStatusOffline), @"Offline"],
        ]);
        for (NSArray *entry in statuses) {
            CydiaHomeViewModel *state([[CydiaHomeViewModel alloc]
                initWithSourceCount:0 packageCount:0 installedCount:0 upgradeCount:0
                halfInstalledCount:0 databaseReady:NO databaseEra:0
                status:(CydiaHomeStatus)[entry[0] unsignedIntegerValue]
                statusMessage:entry[1]]);
            Require(state.status == (CydiaHomeStatus)[entry[0] unsignedIntegerValue],
                @"non-ready state enum is retained");
            RequireString(state.statusMessage, entry[1], @"non-ready status message is retained");
        }

        puts("[verify-home-view-model][ ok ] immutable Home state snapshot");
    }
    return 0;
}
