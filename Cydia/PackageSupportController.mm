/* Cydia Refurbished native package-support page.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageSupportController.h"
#include "Cydia/TableViewCompatibility.h"

#include "Cydia/Appearance.h"
#include "Cydia/AppState.h"
#include "Cydia/Database.h"
#include "Cydia/ExternalURLPolicy.h"
#include "Cydia/Package.h"
#include "Cydia/PackageDetailViewModel.h"
#include "Cydia/UIRouteContext.h"
#include "CyteKit/Localize.h"
#include "CyteKit/extern.h"

@protocol CydiaPackageSupportRouteDelegate <NSObject>
- (BOOL)openCydiaURL:(NSURL *)URL context:(CydiaUIRouteContext *)context;
- (CyteViewController *)pageForURL:(NSURL *)URL
                            context:(NSObject<CyteWebNavigationContext> *)context
                       withReferrer:(NSString *)referrer;
@end

namespace {

NSString *EncodeMailComponent(NSString *value) {
    NSMutableCharacterSet *allowed([[NSCharacterSet alphanumericCharacterSet] mutableCopy]);
    [allowed addCharactersInString:@"-._~"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

NSString *MailtoURL(NSString *address, NSString *type,
                    CydiaPackageDetailViewModel *model) {
    if ([address length] == 0)
        return nil;
    NSString *installed([model installedVersion]);
    NSString *name([model displayName] ?: [model identity]);
    if ([installed length] != 0)
        name = [NSString stringWithFormat:@"%@ (%@)", name, installed];
    NSString *subject([NSString stringWithFormat:@"Cydia/APT(%@): %@", type, name]);
    UIDevice *device([UIDevice currentDevice]);
    NSString *machine(Machine_ == NULL ? nil : [NSString stringWithUTF8String:Machine_]);
    NSString *identifier([UniqueID_ length] != 0 ? (NSString *)UniqueID_ : UniqueIdentifier(device));
    NSString *body([NSString stringWithFormat:@"%@-%@: %@", machine ?: device.model,
        device.systemVersion, identifier ?: @""]);
    NSString *escapedSubject(EncodeMailComponent(subject));
    NSString *escapedBody(EncodeMailComponent(body));
    return [NSString stringWithFormat:@"mailto:%@?subject=%@&body=%@",
        address, escapedSubject ?: @"", escapedBody ?: @""];
}

UIImage *SupportRowImage(void) {
    UIImage *image([UIImage imageNamed:@"email.png"]);
    if (image == nil)
        return nil;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(29.0, 29.0), NO, 0.0);
    [image drawInRect:CGRectMake(0, 0, 29.0, 29.0)];
    UIImage *result(UIGraphicsGetImageFromCurrentImageContext());
    UIGraphicsEndImageContext();
    return result;
}

} // namespace

@interface PackageSupportController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, weak) Database *database;
@property(nonatomic, copy) NSString *packageIdentity;
@property(nonatomic, strong) CydiaPackageDetailViewModel *viewModel;
@property(nonatomic, copy) NSArray<NSArray<NSDictionary *> *> *sections;
@property(nonatomic, strong) UITableView *tableView;
@end

@implementation PackageSupportController

- (nullable instancetype)initWithDatabase:(Database *)database
                                  package:(NSString *)identity {
    Package *package([database packageWithName:identity]);
    CydiaPackageDetailViewModel *model([[CydiaPackageDetailViewModel alloc]
        initWithPackage:package]);
    if (model == nil)
        return nil;
    if ((self = [super init]) != nil) {
        _database = database;
        _packageIdentity = [identity copy];
        _viewModel = model;
        self.title = UCLocalizeEx(@"PACKAGE_SUPPORT_TITLE", @"Support");
        [self rebuildSections];
    }
    return self;
}

- (NSURL *)navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@/support",
        [_viewModel identity]]];
}

- (void)rebuildSections {
    NSMutableArray *sections([NSMutableArray array]);
    NSString *support([_viewModel supportURLString]);
    NSURL *supportURL([NSURL URLWithString:support]);
    NSString *supportHost([[supportURL host] lowercaseString]);
    NSString *supportPath([[supportURL path] lowercaseString]);
    BOOL cydiaSupport([supportHost isEqualToString:@"cydia.saurik.com"] &&
        ([supportPath hasPrefix:@"/support/"] ||
         [supportPath hasPrefix:@"/api/support/"]));
    if ([support length] != 0 && !cydiaSupport) {
        [sections addObject:@[
            @{ @"kind": @"body", @"text":
                @"This package has a website registered for technical support; please read it ;P." },
            @{ @"kind": @"link", @"title": @"Package Support",
               @"detail": support, @"url": support }
        ]];
    }

    if ([_viewModel isCommercial]) {
        [sections addObject:@[
            @{ @"kind": @"body", @"text":
                @"For concerns regarding a Cydia Store payment (not the product, but just the payment), please directly contact the author of Cydia: the developer of this package is unlikely to be able to help." },
            @{ @"kind": @"body", @"text":
                @"Cydia's owner cannot help you with functionality questions: you must contact the developer or artist below." },
            @{ @"kind": @"link", @"title": @"Cydia",
               @"detail": @"Jay Freeman (saurik)",
               @"url": MailtoURL(@"saurik@saurik.com", @"C", _viewModel) }
        ]];
    }
    if ([[_viewModel authorName] length] != 0) {
        [sections addObject:@[
            @{ @"kind": @"body", @"text":
                @"Issues with the package's functionality should go to its developer or artist." },
            @{ @"kind": @"link", @"title": UCLocalize("AUTHOR"),
               @"detail": [_viewModel authorName],
               @"url": MailtoURL([_viewModel authorAddress], @"A", _viewModel) ?: @"" }
        ]];
    }
    if ([[_viewModel maintainerName] length] != 0) {
        [sections addObject:@[
            @{ @"kind": @"body", @"text":
                @"Installation problems should be sent to the person who helped make the package, known as its \"maintainer\"." },
            @{ @"kind": @"link", @"title": UCLocalize("MAINTAINER"),
               @"detail": [_viewModel maintainerName],
               @"url": MailtoURL([_viewModel maintainerAddress], @"M", _viewModel) ?: @"" }
        ]];
    }
    _sections = [sections copy];
}

- (void)loadView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 44.0;
    _tableView.sectionHeaderHeight = 0.01;
    _tableView.sectionFooterHeight = 12.0;
    if (@available(iOS 15.0, *))
        _tableView.sectionHeaderTopPadding = 0.0;
    _tableView.accessibilityIdentifier = @"cydia.package.support";
    self.view = _tableView;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("CLOSE") style:UIBarButtonItemStylePlain
        target:self action:@selector(closeSupport)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("RELOAD") style:UIBarButtonItemStylePlain
        target:self action:@selector(reloadData)];
    [self applyAppearance];
}

- (void)reloadData {
    [super reloadData];
    Package *package([_database packageWithName:_packageIdentity]);
    CydiaPackageDetailViewModel *model([[CydiaPackageDetailViewModel alloc]
        initWithPackage:package]);
    if (model != nil) {
        _viewModel = model;
        [self rebuildSections];
    }
    [_tableView reloadData];
}

- (void)closeSupport {
    if (self.presentingViewController != nil)
        [self dismissViewControllerAnimated:YES completion:nil];
    else
        [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)[_sections count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[[_sections objectAtIndex:section] count];
}

- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *section([_sections objectAtIndex:indexPath.section]);
    return [section objectAtIndex:indexPath.row];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row([self rowAtIndexPath:indexPath]);
    if ([[row objectForKey:@"kind"] isEqualToString:@"link"] &&
        [[row objectForKey:@"url"] hasPrefix:@"mailto:"] &&
        !UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory))
        return 44.0;
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row([self rowAtIndexPath:indexPath]);
    BOOL link([[row objectForKey:@"kind"] isEqualToString:@"link"]);
    BOOL mailto(link && [[row objectForKey:@"url"] hasPrefix:@"mailto:"]);
    UITableViewCell *cell([[UITableViewCell alloc]
        initWithStyle:mailto ? UITableViewCellStyleValue1 :
            (link ? UITableViewCellStyleSubtitle : UITableViewCellStyleDefault)
        reuseIdentifier:nil]);
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground
        traitCollection:self.traitCollection];
    // Let UIKit's selected background paint the entire row, not only its accessory.
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
        traitCollection:self.traitCollection];
    cell.textLabel.numberOfLines = mailto ? 1 : 0;
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.text = [row objectForKey:link ? @"title" : @"text"];
    if (link) {
        cell.detailTextLabel.text = [row objectForKey:@"detail"];
        if (mailto)
            cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
            traitCollection:self.traitCollection];
        cell.detailTextLabel.numberOfLines = mailto ? 1 : 0;
        if (mailto) {
            cell.imageView.image = SupportRowImage();
            cell.imageView.accessibilityIdentifier = @"email.png";
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.package.support.contact.%ld",
            (long)indexPath.section];
        cell.selectionStyle = [[row objectForKey:@"url"] length] == 0 ?
            UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.package.support.body.%ld",
            (long)indexPath.section];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row([self rowAtIndexPath:indexPath]);
    NSString *URLString([row objectForKey:@"url"]);
    if (![[row objectForKey:@"kind"] isEqualToString:@"link"] || [URLString length] == 0)
        return;
    NSURL *destination([NSURL URLWithString:URLString]);
    if (destination == nil)
        return;
    NSURL *route([[destination scheme] caseInsensitiveCompare:@"cydia"] == NSOrderedSame ?
        destination : CydiaExternalURLRouteURL(destination));
    id<CydiaPackageSupportRouteDelegate> application((id)[self delegate]);
    if (route == nil || application == nil)
        return;
    CydiaUIRouteContext *context([CydiaUIRouteContext trustedNativeContext]);
    if ([application respondsToSelector:@selector(openCydiaURL:context:)]) {
        [application openCydiaURL:route context:context];
    } else if ([application respondsToSelector:@selector(pageForURL:context:withReferrer:)]) {
        CyteViewController *page([application pageForURL:route context:context
            withReferrer:[[self navigationURL] absoluteString]]);
        if (page != nil)
            [self.navigationController pushViewController:page animated:YES];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection))
        [self applyAppearance];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyAppearance];
}

- (void)applyAppearance {
    UITraitCollection *traits(self.traitCollection);
    self.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
        traitCollection:traits];
    _tableView.backgroundColor = self.view.backgroundColor;
    _tableView.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator
        traitCollection:traits];
    self.view.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent
        traitCollection:traits];
    UINavigationBar *bar(self.navigationController.navigationBar);
    bar.tintColor = self.view.tintColor;
    bar.titleTextAttributes = @{NSForegroundColorAttributeName:
        [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits]};
}

@end
