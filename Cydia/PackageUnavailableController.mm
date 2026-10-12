/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageUnavailableController.h"

#include "Cydia/Appearance.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/Database.h"
#include "Cydia/PackageArchitecturePresentation.h"
#include "Cydia/TableViewCompatibility.h"
#include "Cydia/UIRouteContext.h"
#include "CyteKit/Localize.h"

@protocol CydiaPackageUnavailableRouteDelegate <NSObject>
- (CyteViewController *)pageForURL:(NSURL *)URL
                          context:(NSObject<CyteWebNavigationContext> *)context
                     withReferrer:(NSString *)referrer;
@end

namespace {

NSString *UnavailableText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:nil table:@"Actions"];
}

NSString *OwnedString(const std::string &value) {
    return [NSString stringWithUTF8String:value.c_str()] ?: @"";
}

NSURL *PackageURL(NSString *identity) {
    NSMutableCharacterSet *allowed([[NSCharacterSet alphanumericCharacterSet] mutableCopy]);
    [allowed addCharactersInString:@"-._~+:"];
    NSString *encoded([identity stringByAddingPercentEncodingWithAllowedCharacters:allowed]);
    return [encoded length] == 0 ? nil :
        [NSURL URLWithString:[@"cydia://package/" stringByAppendingString:encoded]];
}

NSString *ReasonKey(CydiaAPT::PackageLookupStatus status) {
    switch (status) {
        case CydiaAPT::PackageLookupStatus::InvalidSelector:
            return @"PACKAGE_LOOKUP_INVALID";
        case CydiaAPT::PackageLookupStatus::NotFound:
            return @"PACKAGE_LOOKUP_NOT_FOUND";
        case CydiaAPT::PackageLookupStatus::UnsupportedArchitecture:
            return @"PACKAGE_ARCHITECTURE_UNSUPPORTED";
        case CydiaAPT::PackageLookupStatus::NoEligibleVersion:
            return @"PACKAGE_LOOKUP_NO_ELIGIBLE";
        case CydiaAPT::PackageLookupStatus::Ambiguous:
            return @"PACKAGE_LOOKUP_AMBIGUOUS";
        case CydiaAPT::PackageLookupStatus::Found:
            return nil;
    }
    return @"PACKAGE_LOOKUP_NOT_FOUND";
}

} // namespace

@interface PackageUnavailableController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, weak) Database *database;
@property(nonatomic, copy) NSString *requestedIdentity;
@property(nonatomic, copy) NSString *referrer;
@property(nonatomic, copy) NSArray<NSDictionary *> *sections;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic) CydiaAPT::PackageLookupStatus lookupStatus;
@end

@implementation PackageUnavailableController

- (nullable instancetype)initWithDatabase:(Database *)database
                              forPackage:(NSString *)identity
                            withReferrer:(NSString *)referrer {
    if (database == nil || ![identity isKindOfClass:[NSString class]])
        return nil;
    if ((self = [super init]) != nil) {
        _database = database;
        _requestedIdentity = [identity copy];
        _referrer = [referrer copy];
        [self rebuildSnapshot];
        if (_lookupStatus == CydiaAPT::PackageLookupStatus::Found)
            return nil;
    }
    return self;
}

- (NSURL *)navigationURL {
    return PackageURL(_requestedIdentity);
}

- (void)rebuildSnapshot {
    NSMutableArray<NSDictionary *> *sections([NSMutableArray array]);
    NSMutableArray<NSDictionary *> *alternatives([NSMutableArray array]);
    NSArray<NSString *> *registered;
    Database *database(_database);
    @synchronized (database) {
        const CydiaAPT::PackageLookupResult result(database == nil ? CydiaAPT::PackageLookupResult() :
            [database lookupPackage:_requestedIdentity]);
        _lookupStatus = result.status;
        registered = CydiaPackageRegisteredArchitectureNames(CydiaAPT::RegisteredArchitectures());
        std::vector<CydiaAPT::PackageHandle> handles(result.alternatives);
        if (result.status == CydiaAPT::PackageLookupStatus::Found) {
            handles.clear();
            handles.push_back(result.handle);
        }
        NSMutableSet<NSString *> *seen([NSMutableSet set]);
        for (const CydiaAPT::PackageHandle handle : handles) {
            const CydiaAPT::PackageSnapshot snapshot([database packageSnapshot:handle]);
            if (!snapshot.handle.valid() || !snapshot.identity.valid())
                continue;
            /* An alternative is a concrete version architecture. In
             * particular, do not turn an all-version into a native alias or
             * feed the dependency proxy :any back into the route chooser. */
            NSString *architecture(OwnedString(snapshot.identity.versionArchitecture));
            if ([architecture length] == 0 || [architecture isEqualToString:@"any"])
                continue;
            NSString *selector([NSString stringWithFormat:@"%@:%@",
                OwnedString(snapshot.identity.baseName), architecture]);
            if ([seen containsObject:selector])
                continue;
            [seen addObject:selector];
            NSURL *URL(PackageURL(selector));
            if (URL == nil)
                continue;
            NSString *name(OwnedString(snapshot.record.displayName));
            if ([name length] == 0)
                name = OwnedString(snapshot.identity.baseName);
            NSString *caption(CydiaPackageArchitectureCaption(architecture, registered));
            NSString *version(OwnedString(snapshot.version));
            [alternatives addObject:@{
                @"title": CydiaPackageNameWithArchitectureCaption(name, caption),
                @"detail": [version length] == 0 ? selector :
                    [NSString stringWithFormat:@"%@\n%@", version, selector],
                @"url": [URL absoluteString], @"kind": @"alternative"
            }];
        }
    }

    NSString *titleKey(_lookupStatus == CydiaAPT::PackageLookupStatus::Ambiguous ?
        @"PACKAGE_LOOKUP_AMBIGUOUS_TITLE" :
        (_lookupStatus == CydiaAPT::PackageLookupStatus::Found ?
            @"PACKAGE_LOOKUP_AVAILABLE_TITLE" : @"PACKAGE_LOOKUP_TITLE"));
    self.title = UnavailableText(titleKey);
    NSMutableArray *summary([NSMutableArray array]);
    NSString *reasonKey(ReasonKey(_lookupStatus));
    if (reasonKey != nil)
        [summary addObject:@{@"title": UnavailableText(reasonKey), @"kind": @"reason"}];
    [summary addObject:@{@"title": UnavailableText(@"PACKAGE_LOOKUP_REQUESTED"),
        @"detail": _requestedIdentity, @"kind": @"requested"}];
    [sections addObject:@{@"title": @"", @"rows": summary}];

    NSMutableArray *architectures([NSMutableArray array]);
    for (NSString *architecture in registered)
        [architectures addObject:@{@"title":
            CydiaPackageArchitectureCaption(architecture, registered) ?: architecture,
            @"kind": @"architecture"}];
    if ([architectures count] == 0)
        [architectures addObject:@{@"title": UnavailableText(@"PACKAGE_LOOKUP_ARCHITECTURES_UNKNOWN"),
            @"kind": @"architecture"}];
    [sections addObject:@{@"title": UnavailableText(@"PACKAGE_LOOKUP_REGISTERED"), @"rows": architectures}];
    if ([alternatives count] != 0)
        [sections addObject:@{@"title": UnavailableText(@"PACKAGE_LOOKUP_ALTERNATIVES"),
            @"rows": alternatives}];
    [sections addObject:@{@"title": @"", @"rows": @[
        @{@"title": UCLocalize("SOURCES"), @"url": @"cydia://sources", @"kind": @"sources"}
    ]}];
    _sections = [sections copy];
}

- (void)loadView {
    UITableView *table([[UITableView alloc] initWithFrame:[UIScreen mainScreen].bounds
        style:UITableViewStyleGrouped]);
    table.dataSource = self;
    table.delegate = self;
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedRowHeight = 60.0;
    table.accessibilityIdentifier = @"cydia.package.unavailable.table";
    if (@available(iOS 15.0, *))
        table.sectionHeaderTopPadding = 0;
    _tableView = table;
    self.view = table;
    [self applyAppearance];
}

- (void)reloadData {
    [super reloadData];
    [self rebuildSnapshot];
    [_tableView reloadData];
}

- (void)releaseSubviews {
    _tableView = nil;
    [super releaseSubviews];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)[_sections count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)[_sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    NSString *title(_sections[section][@"title"]);
    return [title length] == 0 ? nil : title;
}

- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)indexPath {
    return _sections[indexPath.section][@"rows"][indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *row([self rowAtIndexPath:indexPath]);
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]);
    const BOOL link([row[@"url"] length] != 0);
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"detail"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    cell.accessoryType = link ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = link ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = row[@"title"];
    cell.accessibilityValue = row[@"detail"];
    cell.accessibilityTraits = link ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.package.unavailable.%@.%ld",
        row[@"kind"], (long)indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *URLString([self rowAtIndexPath:indexPath][@"url"]);
    if ([URLString length] == 0)
        return;
    id<CydiaPackageUnavailableRouteDelegate> application((id)[self delegate]);
    if (![application respondsToSelector:@selector(pageForURL:context:withReferrer:)])
        return;
    CyteViewController *page([application pageForURL:[NSURL URLWithString:URLString]
        context:[CydiaUIRouteContext trustedNativeContext]
        withReferrer:[[self navigationURL] absoluteString] ?: _referrer]);
    if (page != nil) {
        [page setDelegate:[self delegate]];
        [self.navigationController pushViewController:page animated:YES];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyAppearance];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection)) {
        [self applyAppearance];
        [_tableView reloadData];
    }
}

- (void)applyAppearance {
    UITraitCollection *traits(self.traitCollection);
    self.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:traits];
    _tableView.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:traits];
    self.view.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:traits];
}

@end
