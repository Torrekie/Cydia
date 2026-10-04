/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/MoreSourcesModel.h"

NSArray<NSDictionary *> *CydiaDefaultSourceCatalog() {
    static NSArray *rows;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rows = @[
            @{@"identifier":@"bigboss", @"name":@"BigBoss",
              @"rooturi":@"http://apt.thebigboss.org/repofiles/cydia/",
              @"distribution":@"stable", @"components":@[@"main"]},
            @{@"identifier":@"modmyi", @"name":@"ModMyi",
              @"rooturi":@"http://modmyi.saurik.com/",
              @"distribution":@"stable", @"components":@[@"main"]},
            @{@"identifier":@"zodttd", @"name":@"ZodTTD",
              @"rooturi":@"http://cydia.zodttd.com/repo/cydia/",
              @"distribution":@"stable", @"components":@[@"main"]}
        ];
    });
    return rows;
}

NSDictionary *CydiaDefaultSourceForIdentifier(NSString *identifier) {
    for (NSDictionary *row in CydiaDefaultSourceCatalog())
        if ([row[@"identifier"] isEqual:identifier]) return row;
    return nil;
}

NSArray<NSDictionary *> *CydiaMissingDefaultSources(NSArray<NSDictionary *> *configured) {
    NSMutableArray *missing = [NSMutableArray array];
    for (NSDictionary *row in CydiaDefaultSourceCatalog()) {
        BOOL present = NO;
        for (NSDictionary *source in configured) {
            if (![source isKindOfClass:[NSDictionary class]] ||
                ![row[@"distribution"] isEqual:source[@"distribution"]]) continue;
            if ([row[@"rooturi"] isEqual:source[@"rooturi"]] ||
                ([row[@"identifier"] isEqual:@"modmyi"] &&
                 [source[@"rooturi"] isEqual:@"http://apt.modmyi.com/"])) {
                present = YES; break;
            }
        }
        if (!present) [missing addObject:row];
    }
    return missing;
}
