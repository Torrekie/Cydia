/* Native unavailable-package simulator fixture.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageUnavailableProbe.h"
#if TARGET_OS_SIMULATOR

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/PackageUnavailableController.h"
#include "Cydia/UIRouteContext.h"

@interface CydiaUnavailableProbeDatabase : NSObject
@property(nonatomic) CydiaAPT::PackageLookupStatus status;
@property(nonatomic, copy) NSString *displayName;
@end

@implementation CydiaUnavailableProbeDatabase
- (CydiaAPT::PackageLookupResult)lookupPackage:(NSString *)identity {
    (void)identity;
    CydiaAPT::PackageLookupResult result;
    result.status = _status;
    if (_status == CydiaAPT::PackageLookupStatus::Found)
        result.handle = CydiaAPT::PackageHandle(1);
    if (_status == CydiaAPT::PackageLookupStatus::Ambiguous ||
        _status == CydiaAPT::PackageLookupStatus::UnsupportedArchitecture ||
        _status == CydiaAPT::PackageLookupStatus::NoEligibleVersion)
        for (unsigned int value(1); value <= 3; ++value)
            result.alternatives.push_back(CydiaAPT::PackageHandle(value));
    return result;
}
- (CydiaAPT::PackageSnapshot)packageSnapshot:(CydiaAPT::PackageHandle)handle {
    CydiaAPT::PackageSnapshot snapshot;
    if (handle.value < 1 || handle.value > 3) return snapshot;
    const std::string architecture(handle.value == 1 ? "iphoneos-arm64" :
        handle.value == 2 ? "iphoneos-arm" : "all");
    snapshot.handle = handle;
    snapshot.identity = CydiaAPT::BuildPackageIdentity("probe.package",
        architecture == "all" ? "iphoneos-arm64" : architecture, architecture,
        "iphoneos-arm64", CydiaAPT::MultiArchMode::None);
    snapshot.record.displayName = [_displayName UTF8String] ?: "Probe Package";
    snapshot.version = "1.0";
    return snapshot;
}
@end

@interface CydiaUnavailableProbeDelegate : NSObject
@property(nonatomic, copy) NSString *URLString;
@property(nonatomic, copy) NSString *referrer;
@property(nonatomic) BOOL trustedNative;
@end

@implementation CydiaUnavailableProbeDelegate
- (CyteViewController *)pageForURL:(NSURL *)URL
                          context:(NSObject<CyteWebNavigationContext> *)context
                     withReferrer:(NSString *)referrer {
    _URLString = [[URL absoluteString] copy];
    _referrer = [referrer copy];
    _trustedNative = [context isKindOfClass:[CydiaUIRouteContext class]] &&
        [(CydiaUIRouteContext *)context caller] == CydiaUIRouteCallerTrustedNative;
    return nil;
}
@end

static NSArray<NSDictionary *> *CydiaUnavailableProbeRows(PackageUnavailableController *page) {
    UITableView *table((UITableView *)page.view);
    NSMutableArray *rows([NSMutableArray array]);
    for (NSInteger section(0); section < [table.dataSource numberOfSectionsInTableView:table]; ++section)
        for (NSInteger row(0); row < [table.dataSource tableView:table numberOfRowsInSection:section]; ++row) {
            NSIndexPath *path([NSIndexPath indexPathForRow:row inSection:section]);
            UITableViewCell *cell([table.dataSource tableView:table cellForRowAtIndexPath:path]);
            [rows addObject:@{@"identifier": cell.accessibilityIdentifier ?: @"",
                @"title": cell.textLabel.text ?: @"", @"detail": cell.detailTextLabel.text ?: @"",
                @"accessibilityLabel": cell.accessibilityLabel ?: @"",
                @"accessibilityValue": cell.accessibilityValue ?: @"",
                @"button": @((cell.accessibilityTraits & UIAccessibilityTraitButton) != 0),
                @"section": @(section), @"row": @(row)}];
        }
    return rows;
}

@implementation CydiaPackageUnavailableProbe {
    CydiaUnavailableProbeDatabase *database_;
    CydiaUnavailableProbeDelegate *delegate_;
}

- (instancetype)init {
    if ((self = [super init]) == nil) return nil;
    database_ = [[CydiaUnavailableProbeDatabase alloc] init];
    database_.displayName = @"Probe Package";
    delegate_ = [[CydiaUnavailableProbeDelegate alloc] init];
    NSMutableArray *cases([NSMutableArray array]);
    const CydiaAPT::PackageLookupStatus statuses[] = {
        CydiaAPT::PackageLookupStatus::InvalidSelector, CydiaAPT::PackageLookupStatus::NotFound,
        CydiaAPT::PackageLookupStatus::UnsupportedArchitecture, CydiaAPT::PackageLookupStatus::NoEligibleVersion,
        CydiaAPT::PackageLookupStatus::Ambiguous};
    NSArray *keys(@[@"PACKAGE_LOOKUP_INVALID", @"PACKAGE_LOOKUP_NOT_FOUND",
        @"PACKAGE_ARCHITECTURE_UNSUPPORTED", @"PACKAGE_LOOKUP_NO_ELIGIBLE", @"PACKAGE_LOOKUP_AMBIGUOUS"]);
    BOOL passed(YES);
    for (NSUInteger index(0); index < [keys count]; ++index) {
        database_.status = statuses[index];
        NSString *identity(index == 0 ? @"probe.package:" :
            index == 2 ? @"probe.package:unsupported" : @"probe.package:any");
        PackageUnavailableController *page([[PackageUnavailableController alloc]
            initWithDatabase:(Database *)database_ forPackage:identity withReferrer:@"cydia://home"]);
        [page setDelegate:(id)delegate_];
        NSArray *rows(CydiaUnavailableProbeRows(page));
        NSString *reason([[NSBundle mainBundle] localizedStringForKey:keys[index] value:nil table:@"Actions"]);
        BOOL reasonMatches([rows count] >= 2 && [rows[0][@"title"] isEqualToString:reason]);
        BOOL requestedMatches([rows count] >= 2 && [rows[1][@"detail"] isEqualToString:identity]);
        BOOL accessibilityMatches(YES);
        NSMutableArray *routes([NSMutableArray array]);
        for (NSDictionary *row in rows) {
            accessibilityMatches &= [row[@"title"] isEqual:row[@"accessibilityLabel"]] &&
                [row[@"detail"] isEqual:row[@"accessibilityValue"]];
            if (![row[@"identifier"] hasPrefix:@"cydia.package.unavailable.alternative."]) continue;
            UITableView *table((UITableView *)page.view);
            [table.delegate tableView:table didSelectRowAtIndexPath:[NSIndexPath
                indexPathForRow:[row[@"row"] integerValue] inSection:[row[@"section"] integerValue]]];
            [routes addObject:delegate_.URLString ?: @""];
            accessibilityMatches &= [row[@"button"] boolValue] && delegate_.trustedNative &&
                [delegate_.referrer isEqualToString:[[page navigationURL] absoluteString]];
        }
        NSArray *expected(index < 2 ? @[] : @[@"cydia://package/probe.package:iphoneos-arm64",
            @"cydia://package/probe.package:iphoneos-arm", @"cydia://package/probe.package:all"]);
        BOOL exactRoutes([routes isEqualToArray:expected]);
        passed &= reasonMatches && requestedMatches && accessibilityMatches && exactRoutes;
        [cases addObject:@{@"reasonKey": keys[index], @"reasonMatches": @(reasonMatches),
            @"requestedMatches": @(requestedMatches), @"accessibilityMatches": @(accessibilityMatches),
            @"exactRoutes": @(exactRoutes), @"routes": routes, @"rows": rows}];
        if (index == 4) _controller = page;
    }

    /* A visible page owns text independently of subsequent cache changes. */
    NSArray *before(CydiaUnavailableProbeRows(_controller));
    database_.displayName = @"Changed Probe Package";
    BOOL ownsSnapshot([before isEqualToArray:CydiaUnavailableProbeRows(_controller)]);
    database_.status = CydiaAPT::PackageLookupStatus::Found;
    BOOL foundReturnsNil([[PackageUnavailableController alloc] initWithDatabase:(Database *)database_
        forPackage:@"probe.package:iphoneos-arm64" withReferrer:nil] == nil);
    [_controller reloadData];
    NSArray *after(CydiaUnavailableProbeRows(_controller));
    NSUInteger alternatives(0);
    BOOL changedName(NO);
    for (NSDictionary *row in after) {
        if (![row[@"identifier"] hasPrefix:@"cydia.package.unavailable.alternative."]) continue;
        ++alternatives;
        changedName = [row[@"title"] hasPrefix:@"Changed Probe Package"] &&
            [row[@"detail"] hasSuffix:@"probe.package:iphoneos-arm64"];
    }
    BOOL reloadFound(alternatives == 1 && changedName && [_controller.title isEqualToString:
        [[NSBundle mainBundle] localizedStringForKey:@"PACKAGE_LOOKUP_AVAILABLE_TITLE" value:nil table:@"Actions"]]);
    database_.status = CydiaAPT::PackageLookupStatus::Ambiguous;
    database_.displayName = @"Probe Package";
    [_controller reloadData];
    _results = @{@"passed": @(passed && ownsSnapshot && foundReturnsNil && reloadFound),
        @"cases": cases, @"ownsSnapshot": @(ownsSnapshot), @"foundReturnsNil": @(foundReturnsNil),
        @"reloadFound": @(reloadFound)};
    return self;
}

@end
#endif
