/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SettingsController.h"
#import "Cydia/SettingsStore.h"
#import "Cydia/AdvancedSettingsController.h"
#import "Cydia/CapabilityController.h"
#import "Cydia/KeyringImportController.h"
#import "Cydia/Database.h"
#import "Cydia/CydiaDelegate.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/RepositorySecurityPolicy.hpp"

static NSString *SettingText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"];
}

void CydiaPresentAbout(UIViewController *presenter) {
    NSString *refurbished([NSString stringWithFormat:
        UCLocalizeEx(@"ABOUT_REFURBISHED_COPYRIGHT", @"Refurbished work Copyright (C) %@"), @"2026"]);
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("ABOUT_CYDIA")
        message:[NSString stringWithFormat:
            @"Original work Copyright (C) 2008-2017\nSaurikIT, LLC\n\n"
             "Jay Freeman (saurik)\nhttp://www.saurik.com/\n\n"
             "Modified work Copyright (C) 2018\nSB Designs, INC\n\n"
             "Sam Bingner (sbingner)\nhttp://www.bingner.com/\n\n"
             "%@\nTorrekie\nhttps://torrekie.dev/", refurbished]
        preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CLOSE")
        style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@interface CydiaSettingsController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) Database *database;
@property(nonatomic, strong) UITableView *table;
@end

@implementation CydiaSettingsController
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) _database = database;
    return self;
}

- (NSURL *)navigationURL { return [NSURL URLWithString:@"cydia://home/settings"]; }

- (void)loadView {
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 64;
    self.view = self.table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = UCLocalize("SETTINGS");
    self.table.accessibilityIdentifier = @"cydia.settings";
    [self applyAppearance];
}

- (void)applyAppearance {
    self.table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    self.table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
    [self.table reloadData];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory])
        [self applyAppearance];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : section == 1 ? 3 : 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? SettingText(@"REPOSITORY_SECURITY") : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return [NSString stringWithFormat:@"%@\n\n%@", SettingText(@"REPOSITORY_SECURITY_EXPLANATION"),
        SettingText(@"REPOSITORY_SECURITY_REFRESH_EX")];
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"setting"]);
    if (cell == nil) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"setting"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
    cell.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.detailTextLabel.text = nil;
    if (path.section == 0) {
        NSArray *names(@[@"SECURITY_ALLOW", @"SECURITY_WARNING", @"SECURITY_ERROR"]);
        NSArray *details(@[@"SECURITY_ALLOW_DETAIL", @"SECURITY_WARNING_DETAIL", @"SECURITY_ERROR_DETAIL"]);
        NSArray *values(@[@"allow", @"warning", @"error"]);
        cell.textLabel.text = SettingText(names[path.row]);
        cell.detailTextLabel.text = SettingText(details[path.row]);
        BOOL selected([CydiaRepositorySecurityPreference() isEqual:values[path.row]]);
        cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
        cell.accessibilityIdentifier = [@"cydia.settings.security." stringByAppendingString:values[path.row]];
    } else if (path.section == 1) {
        cell.textLabel.text = SettingText(path.row == 0 ? @"CAPABILITIES" : path.row == 1 ? @"KEY_IMPORT" : @"ADVANCED_SETTINGS");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = path.row == 0 ? @"cydia.settings.capabilities" : path.row == 1 ? @"cydia.settings.key-import" : @"cydia.settings.advanced";
        cell.accessibilityTraits = UIAccessibilityTraitButton;
    } else {
        cell.textLabel.text = UCLocalize("ABOUT");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = @"cydia.settings.about";
        cell.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 2) { CydiaPresentAbout(self); return; }
    if (path.section == 1) {
        CyteViewController *controller(path.row == 0 ?
            [[CydiaCapabilityController alloc] initWithDatabase:self.database] : path.row == 1 ?
                [[CydiaKeyringImportController alloc] initWithDatabase:self.database] :
                [[CydiaAdvancedSettingsController alloc] initWithDatabase:self.database]);
        controller.delegate = self.delegate;
        [self.navigationController pushViewController:controller animated:YES]; return;
    }
    id<CydiaDelegate, NSObject> delegate([self delegate]);
    BOOL busy([delegate respondsToSelector:@selector(updating)] && [delegate updating]);
    if (busy) { [self showMessage:SettingText(@"SETTINGS_WAIT_FOR_OPERATION")]; return; }
    NSString *value(@[@"allow", @"warning", @"error"][path.row]);
    if (![self.database beginSettingsChange]) {
        [self showMessage:SettingText(@"SETTINGS_WAIT_FOR_OPERATION")]; return;
    }
    @try {
        if (!CydiaSetRepositorySecurityPreference(value)) {
            [self showMessage:SettingText(@"SETTINGS_SAVE_FAILED")]; return;
        }
        CydiaAPT::SetRepositorySecurityMode(CydiaAPT::RepositorySecurityModeFromString([value UTF8String]));
    } @finally {
        [self.database endSettingsChange];
    }
    [table reloadData];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("SETTINGS") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
