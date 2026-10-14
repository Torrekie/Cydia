/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RepositoryIdentityController.h"
#import "Cydia/RepositoryIdentity.h"
#import "Cydia/SettingsStore.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"

static NSString *IdentityText(NSString *key, NSString *fallback) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:fallback table:@"Settings"];
}
@interface CydiaRepositoryIdentityController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) UITextField *customField;
@property(nonatomic, copy) NSString *selectedIdentity;
@property(nonatomic, copy) NSString *inputError;
@property(nonatomic) BOOL editingCustom;
@end
@implementation CydiaRepositoryIdentityController
- (void)loadView {
    self.selectedIdentity = CydiaRepositoryIdentityPreference();
    UITableViewStyle style = UITableViewStyleGrouped;
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:style];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension; self.table.estimatedRowHeight = 48;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.accessibilityIdentifier = @"cydia.settings.identity";
    self.customField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.customField.delegate = self;
    self.customField.text = CydiaCustomRepositoryUserAgentPreference();
    self.customField.placeholder = IdentityText(@"IDENTITY_CUSTOM_PLACEHOLDER", @"Enter a User-Agent");
    self.customField.accessibilityLabel = IdentityText(@"IDENTITY_CUSTOM", @"Custom");
    self.customField.accessibilityIdentifier = @"cydia.settings.identity.custom-input";
    self.customField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.customField.adjustsFontForContentSizeCategory = YES;
    self.customField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.customField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.customField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.customField.smartQuotesType = UITextSmartQuotesTypeNo;
    self.customField.smartDashesType = UITextSmartDashesTypeNo;
    self.customField.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    self.customField.keyboardType = UIKeyboardTypeASCIICapable;
    self.customField.returnKeyType = UIReturnKeyDone;
    [self.customField addTarget:self action:@selector(inputChanged:) forControlEvents:UIControlEventEditingChanged];
    self.view = self.table;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = IdentityText(@"REPOSITORY_IDENTITY", @"Repository Identity");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("DONE")
        style:UIBarButtonItemStyleDone target:self action:@selector(finishEditing)];
    [self applyAppearance];
}
- (void)applyAppearance {
    self.table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    self.table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
    self.customField.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    self.customField.keyboardAppearance = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? UIKeyboardAppearanceDark : UIKeyboardAppearanceDefault;
    [self.table reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) [self applyAppearance];
}
- (void)inputChanged:(UITextField *)field {
    self.inputError = nil;
    [self.table footerViewForSection:1].textLabel.text = [self tableView:self.table titleForFooterInSection:1];
}
- (BOOL)saveIdentity:(NSString *)identity {
    NSString *custom = self.customField.text ?: @"";
    if ([identity isEqual:@"custom"] && !CydiaValidCustomRepositoryUserAgent(custom)) {
        self.inputError = IdentityText(@"IDENTITY_INVALID", @"Enter a valid User-Agent using 1–512 printable ASCII characters with no leading or trailing spaces.");
        [self reloadDetails]; return NO;
    }
    // An unfinished custom draft does not prevent selecting a built-in UA.
    if (![identity isEqual:@"custom"] && !CydiaValidCustomRepositoryUserAgent(custom))
        custom = CydiaCustomRepositoryUserAgentPreference();
    if (!CydiaSetRepositoryIdentityPreference(identity, custom)) {
        self.inputError = IdentityText(@"IDENTITY_SAVE_FAILED", @"The repository identity could not be saved.");
        [self reloadDetails]; return NO;
    }
    self.selectedIdentity = identity; self.inputError = nil;
    if (self.customField.isFirstResponder && [identity isEqual:@"custom"])
        [self.table reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
    else [self.table reloadData];
    [self reloadDetails]; return YES;
}
- (void)reloadDetails {
    // Keep the inline editor attached while showing validation feedback.
    [self.table footerViewForSection:1].textLabel.text = [self tableView:self.table titleForFooterInSection:1];
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
    [self.table beginUpdates]; [self.table endUpdates];
}
- (void)finishEditing {
    if (!self.customField.isFirstResponder) return;
    if (!CydiaValidCustomRepositoryUserAgent(self.customField.text)) {
        self.inputError = IdentityText(@"IDENTITY_INVALID", @"Enter a valid User-Agent using 1–512 printable ASCII characters with no leading or trailing spaces.");
        [self reloadDetails]; return;
    }
    [self.customField resignFirstResponder];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field { [self finishEditing]; return NO; }
- (void)textFieldDidBeginEditing:(UITextField *)field {
    self.editingCustom = YES;
}
- (void)textFieldDidEndEditing:(UITextField *)field {
    if (self.editingCustom) { self.editingCustom = NO; [self saveIdentity:@"custom"]; }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 ? 4 : 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 2 ? IdentityText(@"IDENTITY_PREVIEW", @"User-Agent Preview") : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 0) return IdentityText(@"REPOSITORY_IDENTITY_HELP", @"Choose the User-Agent sent to repositories and account providers.");
    if (section == 1) return self.inputError ?: IdentityText(@"IDENTITY_CUSTOM_HELP", @"Use 1–512 printable ASCII characters with no leading or trailing spaces.");
    return [NSString stringWithFormat:@"%@\n\n%@", IdentityText(@"IDENTITY_APPLY_HELP", @"Changes apply to new repository operations and account requests without restarting Cydia."),
        IdentityText(@"IDENTITY_EXTERNAL_HELP", @"Applies to Cydia account requests and Cydia-managed downloads. An external APT provider may keep its own User-Agent.")];
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.textLabel.numberOfLines = 0;
    cell.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
    if (path.section == 0) {
        NSArray *values = @[@"cydia", @"sileo", @"zebra", @"custom"];
        NSArray *titles = @[IdentityText(@"IDENTITY_CYDIA_DEFAULT", @"Cydia (Default)"), @"Sileo", @"Zebra", IdentityText(@"IDENTITY_CUSTOM", @"Custom")];
        BOOL selected = [self.selectedIdentity isEqual:values[path.row]];
        cell.textLabel.text = titles[path.row];
        cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
        cell.accessibilityIdentifier = [@"cydia.settings.identity." stringByAppendingString:values[path.row]];
    } else if (path.section == 1) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        self.customField.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:self.customField];
        UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [self.customField.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [self.customField.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [self.customField.topAnchor constraintEqualToAnchor:margins.topAnchor constant:5],
            [self.customField.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-5],
            [self.customField.heightAnchor constraintGreaterThanOrEqualToConstant:32]]];
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessibilityIdentifier = @"cydia.settings.identity.preview";
        NSString *account = CydiaRepositoryUserAgent(), *download = CydiaRepositoryDownloadUserAgent();
        cell.textLabel.text = [account isEqual:download] ? account : [NSString stringWithFormat:@"%@\n\n%@",
            [NSString stringWithFormat:IdentityText(@"IDENTITY_ACCOUNT_PREVIEW", @"Accounts: %@"), account],
            [NSString stringWithFormat:IdentityText(@"IDENTITY_DOWNLOAD_PREVIEW", @"Repositories and downloads: %@"), download]];
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section != 0) return;
    NSString *identity = @[@"cydia", @"sileo", @"zebra", @"custom"][path.row];
    if ([identity isEqual:@"custom"]) {
        if (CydiaValidCustomRepositoryUserAgent(self.customField.text)) [self saveIdentity:identity];
        [self.customField becomeFirstResponder];
    } else {
        // Choose the preset before ending editing so a custom draft cannot
        // overwrite the user's selection through didEndEditing.
        const BOOL editing = self.editingCustom; self.editingCustom = NO;
        if ([self saveIdentity:identity]) [self.customField resignFirstResponder];
        else self.editingCustom = editing;
    }
}
@end
