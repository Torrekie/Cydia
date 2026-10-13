/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RuntimeProviderSettingsController.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"
#include "Cydia/RedactedURL.hpp"

static NSString *RuntimeText(NSString *key) { return CydiaRuntimeProviderLocalize(key); }
static NSString *SettingsText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"];
}

@interface CydiaRuntimeProviderSettingsController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) Database *database;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) CydiaRuntimeProviderStatus *status;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL hasPendingChanges;
@property(nonatomic) BOOL samplingPendingChanges;
@end

@implementation CydiaRuntimeProviderSettingsController
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init])) {
        _database = database;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(runtimeStatusDidChange:)
            name:CydiaRuntimeProviderStatusDidChangeNotification object:database];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)refreshPendingChanges {
    if (self.samplingPendingChanges) return;
    self.samplingPendingChanges = YES;
    Database *database(self.database);
    __weak CydiaRuntimeProviderSettingsController *weakSelf(self);
    // A remote cache-state query can require IPC even after acquiring the
    // operation gate. Keep both that query and any progress callbacks off the
    // main queue; this footer uses the last completed sample while busy.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL sampled(NO), pending(NO);
        if ([database beginSettingsChange]) {
            @try { pending = [database hasPendingPackageChanges]; sampled = YES; }
            @finally { [database endSettingsChange]; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            CydiaRuntimeProviderSettingsController *self(weakSelf);
            if (!self) return;
            self.samplingPendingChanges = NO;
            if (sampled && self.hasPendingChanges != pending) {
                self.hasPendingChanges = pending;
                [self.table reloadData];
            }
        });
    });
}
- (void)runtimeStatusDidChange:(NSNotification *)notification {
    self.status = [self.database runtimeProviderStatus];
    [self refreshPendingChanges];
    [self.table reloadData];
}
- (void)loadView {
    UITableViewStyle style(UITableViewStyleGrouped);
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:style];
    _table.dataSource = self; _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension; _table.estimatedRowHeight = 72;
    _table.accessibilityIdentifier = @"cydia.settings.runtime";
    self.view = _table;
    self.navigationItem.title = RuntimeText(@"RUNTIME_TITLE");
    [self applyAppearance];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.status = [self.database runtimeProviderStatus];
    [self refreshPendingChanges];
    [self.table reloadData];
}
- (void)applyAppearance {
    self.table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    self.table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
    [self.table reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) [self applyAppearance];
}
- (BOOL)isChecking { return self.busy || self.status.state == CydiaRuntimeProviderStateChecking; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;
    if (section == 1) return self.status.providerName.length ? 2 : 1;
    return 1;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? RuntimeText(@"CURRENT_RUNTIME") : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return section == 0 && self.hasPendingChanges ? RuntimeText(@"REVIEW_RESET_HELP") : nil;
}
- (NSString *)stateTitle {
    if ([self isChecking]) return RuntimeText(@"CHECKING");
    switch (self.status.state) {
        case CydiaRuntimeProviderStateExternalActive: return RuntimeText(@"STATUS_EXTERNAL");
        case CydiaRuntimeProviderStateRecoveryActive: return RuntimeText(@"STATUS_RECOVERY");
        case CydiaRuntimeProviderStateMissing: return RuntimeText(@"STATUS_MISSING");
        case CydiaRuntimeProviderStateUnsupported: return RuntimeText(@"STATUS_UNSUPPORTED");
        case CydiaRuntimeProviderStateBroken: return RuntimeText(@"STATUS_BROKEN");
        case CydiaRuntimeProviderStatePreparationFailed: return RuntimeText(@"OPERATION_FAILED");
        default: return RuntimeText(@"STATUS_UNCHECKED");
    }
}
- (NSString *)stateDetail {
    if ([self isChecking]) return nil;
    NSString *explanation(nil);
    switch (self.status.state) {
        case CydiaRuntimeProviderStateUnchecked: explanation = RuntimeText(@"UNCHECKED_HELP"); break;
        case CydiaRuntimeProviderStateMissing: explanation = RuntimeText(@"MISSING_HELP"); break;
        case CydiaRuntimeProviderStateUnsupported: explanation = RuntimeText(@"UNSUPPORTED_HELP"); break;
        case CydiaRuntimeProviderStateBroken: explanation = RuntimeText(@"BROKEN_HELP"); break;
        default: break;
    }
    if (!self.status.diagnostic.length || [self.status.diagnostic isEqualToString:explanation]) return explanation;
    return explanation.length ? [NSString stringWithFormat:@"%@\n\n%@", explanation, self.status.diagnostic] : self.status.diagnostic;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"runtime"]);
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"runtime"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
    cell.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
    cell.accessoryType = UITableViewCellAccessoryNone; cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.accessibilityTraits = UIAccessibilityTraitStaticText;
    cell.detailTextLabel.text = nil; cell.accessibilityIdentifier = nil;
    if (path.section == 0) {
        NSString *preference(path.row == 0 ? @"automatic" : @"recovery");
        const BOOL selected([self.status.preference isEqualToString:preference]);
        cell.textLabel.text = RuntimeText(path.row == 0 ? @"AUTOMATIC" : @"RECOVERY");
        cell.detailTextLabel.text = RuntimeText(path.row == 0 ? @"AUTOMATIC_HELP" : @"RECOVERY_HELP");
        cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = [self isChecking] ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0) |
            ([self isChecking] ? UIAccessibilityTraitNotEnabled : 0);
        cell.accessibilityIdentifier = [@"cydia.settings.runtime." stringByAppendingString:preference];
    } else if (path.section == 1 && path.row == 0) {
        cell.textLabel.text = [self stateTitle]; cell.detailTextLabel.text = [self stateDetail];
        cell.accessibilityIdentifier = @"cydia.settings.runtime.status";
    } else if (path.section == 1) {
        cell.textLabel.text = self.status.providerName;
        NSMutableArray *details([NSMutableArray array]);
        if (self.status.providerVersion.length) [details addObject:[NSString stringWithFormat:RuntimeText(@"PROVIDER_VERSION"), self.status.providerVersion]];
        if (self.status.aptVersion.length) [details addObject:[NSString stringWithFormat:RuntimeText(@"APT_VERSION"), self.status.aptVersion]];
        cell.detailTextLabel.text = [details componentsJoinedByString:@"\n"];
        cell.accessibilityIdentifier = @"cydia.settings.runtime.provider";
    } else {
        cell.textLabel.text = RuntimeText([self isChecking] ? @"CHECKING" : @"CHECK_AGAIN");
        cell.textLabel.textColor = [UIColor cydiaColorForRole:[self isChecking] ? CydiaColorRoleSecondaryLabel : CydiaColorRoleAccent traitCollection:self.traitCollection];
        cell.selectionStyle = [self isChecking] ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = UIAccessibilityTraitButton | ([self isChecking] ? UIAccessibilityTraitNotEnabled : 0);
        cell.accessibilityIdentifier = @"cydia.settings.runtime.check";
        if ([self isChecking]) {
            UIActivityIndicatorView *spinner([[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray]);
            spinner.color = cell.detailTextLabel.textColor; [spinner startAnimating]; cell.accessoryView = spinner;
        }
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if ([self isChecking] || path.section == 1) return;
    NSString *preference(path.section == 0 ? (path.row == 0 ? @"automatic" : @"recovery") : nil);
    if (preference && [self.status.preference isEqualToString:preference]) return;
    self.busy = YES; [self.table reloadData];
    __weak CydiaRuntimeProviderSettingsController *weakSelf(self);
    CydiaRuntimeProviderCompletion completion = ^(CydiaRuntimeProviderStatus *status, NSError *error) {
        CydiaRuntimeProviderSettingsController *self(weakSelf); if (!self) return;
        self.busy = NO; self.status = status;
        [self refreshPendingChanges];
        [self.table reloadData];
        if (error && self.view.window) {
            UIAlertController *alert([UIAlertController alertControllerWithTitle:RuntimeText(@"RUNTIME_TITLE")
                message:error.localizedDescription.length ? CydiaRedactedDiagnostic(error.localizedDescription) : SettingsText(@"SETTINGS_SAVE_FAILED")
                preferredStyle:UIAlertControllerStyleAlert]);
            [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    };
    if (preference) [self.database setRuntimeProviderPreference:preference completion:completion];
    else [self.database checkRuntimeProviderWithCompletion:completion];
}
@end
