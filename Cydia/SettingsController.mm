/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SettingsController.h"
#import "Cydia/SettingsStore.h"
#import "Cydia/AdvancedSettingsController.h"
#import "Cydia/SourceControllers.h"
#import "Cydia/KeyringImportController.h"
#import "Cydia/RepositoryAccountsController.h"
#import "Cydia/RepositoryAccountService.h"
#import "Cydia/Database.h"
#import "Cydia/DatabaseRuntimeInternal.h"
#import "Cydia/CydiaDelegate.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"

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

@interface CydiaRepositorySecurityController : CyteViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) Database *database;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic) BOOL saving;
- (instancetype)initWithDatabase:(Database *)database;
@end

static UITableView *SettingsTable(id<UITableViewDataSource, UITableViewDelegate> controller) {
    UITableViewStyle style(UITableViewStyleGrouped);
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    UITableView *table([[UITableView alloc] initWithFrame:CGRectZero style:style]);
    table.dataSource = controller; table.delegate = controller;
    table.rowHeight = UITableViewAutomaticDimension; table.estimatedRowHeight = 64;
    table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:table.traitCollection];
    table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:table.traitCollection];
    return table;
}
static UITableViewCell *SettingsCell(UITableView *table) {
    UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"setting"]);
    if (cell == nil) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"setting"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:table.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:table.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:table.traitCollection];
    cell.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:table.traitCollection];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.text = nil; cell.accessibilityTraits = UIAccessibilityTraitButton;
    return cell;
}
static NSString *SecurityValue(Database *database) {
    const CydiaRuntimeProviderState state([database runtimeProviderStatus].state);
    if (state == CydiaRuntimeProviderStateChecking) return CydiaRuntimeProviderLocalize(@"CHECKING");
    NSString *value(CydiaEffectiveRepositorySecurityPreference(state == CydiaRuntimeProviderStateExternalActive));
    return SettingText([value isEqual:@"distribution"] ? @"SECURITY_DISTRIBUTION" :
        [value isEqual:@"allow"] ? @"SECURITY_ALLOW" : [value isEqual:@"error"] ? @"SECURITY_ERROR" : @"SECURITY_WARNING");
}

@implementation CydiaRepositorySecurityController
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) _database = database;
    return self;
}

- (void)loadView {
    self.table = SettingsTable(self);
    self.view = self.table;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = SettingText(@"REPOSITORY_SECURITY");
    self.table.accessibilityIdentifier = @"cydia.settings.security";
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 1; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return 4; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return [NSString stringWithFormat:@"%@\n\n%@\n\n%@", SettingText(@"REPOSITORY_SECURITY_EXPLANATION"),
        SettingText(@"REPOSITORY_SECURITY_ENGINE_EX"),
        SettingText(@"REPOSITORY_SECURITY_REFRESH_EX")];
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell(SettingsCell(table));
    NSArray *names(@[@"SECURITY_DISTRIBUTION", @"SECURITY_ALLOW", @"SECURITY_WARNING", @"SECURITY_ERROR"]);
    NSArray *details(@[@"SECURITY_DISTRIBUTION_DETAIL", @"SECURITY_ALLOW_DETAIL", @"SECURITY_WARNING_DETAIL", @"SECURITY_ERROR_DETAIL"]);
    NSArray *values(@[@"distribution", @"allow", @"warning", @"error"]);
    cell.textLabel.text = SettingText(names[path.row]);
    cell.detailTextLabel.text = SettingText(details[path.row]);
    const CydiaRuntimeProviderState state([self.database runtimeProviderStatus].state);
    BOOL selected(state != CydiaRuntimeProviderStateChecking &&
        [CydiaEffectiveRepositorySecurityPreference(state == CydiaRuntimeProviderStateExternalActive) isEqual:values[path.row]]);
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
    cell.accessibilityIdentifier = [@"cydia.settings.security." stringByAppendingString:values[path.row]];
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    id<CydiaDelegate, NSObject> delegate([self delegate]);
    BOOL busy([delegate respondsToSelector:@selector(updating)] && [delegate updating]);
    if (busy) { [self showMessage:SettingText(@"SETTINGS_WAIT_FOR_OPERATION")]; return; }
    NSString *value(@[@"distribution", @"allow", @"warning", @"error"][path.row]);
    if (self.saving) return;
    self.saving = YES; table.userInteractionEnabled = NO;
    __weak CydiaRepositorySecurityController *weakSelf(self);
    [self.database setRepositorySecurityPreference:value completion:^(CydiaRuntimeProviderStatus *, NSError *error) {
        CydiaRepositorySecurityController *self(weakSelf); if (!self) return;
        self.saving = NO; self.table.userInteractionEnabled = YES;
        [self.table reloadData];
        if (error) [self showMessage:error.localizedDescription];
    }];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("SETTINGS") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

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
- (void)loadView { self.table = SettingsTable(self); self.view = self.table; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.navigationItem.title = UCLocalize("SETTINGS");
    self.table.accessibilityIdentifier = @"cydia.settings";
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.table reloadData]; }
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) {
        self.table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
        self.table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
        [self.table reloadData];
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 ? 4 : 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { return section == 0 ? UCLocalize("SOURCES") : nil; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell(SettingsCell(table));
    if (path.section == 0) {
        NSArray *keys(@[@"REPOSITORY_SETTINGS", @"REPOSITORY_SECURITY", @"KEY_IMPORT", @"ACCOUNTS"]);
        NSArray *identifiers(@[@"cydia.settings.repositories", @"cydia.settings.security", @"cydia.settings.key-import", @"cydia.settings.accounts"]);
        cell.textLabel.text = path.row == 3 ? CydiaAccountLocalize(@"ACCOUNTS") : SettingText(keys[path.row]);
        cell.accessibilityIdentifier = identifiers[path.row];
        if (path.row == 0) cell.detailTextLabel.text = SettingText(@"REPOSITORY_SETTINGS_HELP");
        if (path.row == 1) cell.detailTextLabel.text = SecurityValue(self.database);
    } else if (path.section == 1) {
        cell.textLabel.text = SettingText(@"ADVANCED_SETTINGS");
        cell.detailTextLabel.text = SettingText(@"ADVANCED_SETTINGS_HELP");
        cell.accessibilityIdentifier = @"cydia.settings.advanced";
    } else {
        cell.textLabel.text = UCLocalize("ABOUT"); cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessibilityIdentifier = @"cydia.settings.about";
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 2) { CydiaPresentAbout(self); return; }
    CyteViewController *controller;
    if (path.section == 1) controller = [[CydiaAdvancedSettingsController alloc] initWithDatabase:self.database];
    else if (path.row == 0) controller = [[CydiaRepositorySettingsController alloc] initWithDatabase:self.database advancedAccess:NO];
    else if (path.row == 1) controller = [[CydiaRepositorySecurityController alloc] initWithDatabase:self.database];
    else if (path.row == 3) controller = [[RepositoryAccountsController alloc] init];
    else controller = [[CydiaKeyringImportController alloc] initWithDatabase:self.database];
    controller.delegate = self.delegate;
    [self.navigationController pushViewController:controller animated:YES];
}
@end
