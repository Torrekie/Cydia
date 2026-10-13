/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/CapabilityController.h"
#import "Cydia/Database.h"
#import "Cydia/CydiaDelegate.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/CapabilityPreview.hpp"
#include "Cydia/PrivilegedClient.h"

static NSString *CapabilityText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"];
}
static NSString *CapabilityString(const std::string &value) {
    NSString *text([[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding]);
    return text ?: [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSISOLatin1StringEncoding];
}
static NSString *CapabilityDetailsTitle() {
    return [[NSBundle mainBundle] localizedStringForKey:@"ACCESS_CHECK_DETAILS" value:nil table:@"RuntimeAccess"];
}
static NSString *CapabilityResultDetails(const CydiaRuntime::PrivilegedClient::Result &result) {
    /* Helper output and execution metadata belong only in Technical Details. */
    return [NSString stringWithFormat:@"launch_error=%d, exit=%d, signal=%d, output_limit=%d\n\n%@\n%@",
        result.launchError, result.exitCode, result.termSignal, result.outputLimitExceeded ? 1 : 0,
        CapabilityString(result.output) ?: @"", CapabilityString(result.error) ?: @""];
}
static NSString *CapabilityReason(const std::string &reason) {
    if (reason == "package-state") return CapabilityText(@"CAPABILITY_PRESERVE_STATE");
    if (reason == "multiple-providers") return CapabilityText(@"CAPABILITY_PRESERVE_MULTIPLE");
    if (reason == "foreign-architecture") return CapabilityText(@"CAPABILITY_PRESERVE_ARCHITECTURE");
    if (reason == "unknown-version") return CapabilityText(@"CAPABILITY_PRESERVE_VERSION");
    if (reason == "current" || reason == "newer-provider") return CapabilityText(@"CAPABILITY_PRESERVE_CURRENT");
    return CapabilityText(@"CAPABILITY_PRESERVE_PROVIDER");
}

@interface CydiaCapabilityController () <UITableViewDataSource, UITableViewDelegate> {
    CydiaRuntime::CapabilityPreview _preview;
    CydiaRuntime::Privileged::Request _reviewedRequest;
}
@property(nonatomic, strong) Database *database;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) UIBarButtonItem *applyButton;
@property(nonatomic, strong) UIBarButtonItem *refreshButton;
@property(nonatomic, copy) NSString *status;
@property(nonatomic, copy) NSString *previewDiagnostics;
@property(nonatomic, copy) NSString *operationDiagnostics;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL ready;
@end

@implementation CydiaCapabilityController
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) _database = database;
    return self;
}
- (NSURL *)navigationURL { return [NSURL URLWithString:@"cydia://home/settings/capabilities"]; }
- (void)loadView {
    UITableViewStyle style(UITableViewStyleGrouped);
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:style];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 88;
    self.table.accessibilityIdentifier = @"cydia.settings.capabilities";
    self.view = self.table;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = CapabilityText(@"CAPABILITIES");
    self.applyButton = [[UIBarButtonItem alloc] initWithTitle:CapabilityText(@"CAPABILITIES_APPLY")
        style:UIBarButtonItemStyleDone target:self action:@selector(confirmApply)];
    self.applyButton.accessibilityIdentifier = @"cydia.settings.capabilities.apply";
    self.refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(refreshPreview)];
    self.refreshButton.accessibilityIdentifier = @"cydia.settings.capabilities.refresh";
    self.navigationItem.rightBarButtonItems = @[self.applyButton, self.refreshButton];
    [self applyAppearance];
    [self refreshPreview];
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
- (BOOL)operationAvailable {
    id<CydiaDelegate, NSObject> delegate([self delegate]);
    if (self.busy || ([delegate respondsToSelector:@selector(updating)] && [delegate updating])) {
        [self showMessage:CapabilityText(@"SETTINGS_WAIT_FOR_OPERATION")]; return NO;
    }
    return YES;
}
- (void)updateControls {
    self.applyButton.enabled = self.ready && !self.busy && !_preview.changes.empty();
    self.refreshButton.enabled = !self.busy;
    [self.table reloadData];
}
- (void)refreshPreview {
    if (![self operationAvailable]) return;
    self.busy = YES; self.ready = NO;
    self.status = UCLocalize("LOADING");
    [self updateControls];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            if (![self.database beginSettingsChange]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.busy = NO; self.status = CapabilityText(@"SETTINGS_WAIT_FOR_OPERATION"); [self updateControls];
                });
                return;
            }
            CydiaRuntime::Privileged::Request request;
            CydiaRuntime::PrivilegedClient::Result result;
            CydiaRuntime::CapabilityPreview preview;
            BOOL valid = NO;
            @try {
                request = CydiaRuntime::PrivilegedClient::RuntimeRequest("");
                result = CydiaRuntime::PrivilegedClient::Run(CydiaAPT::PrivilegedHelperPath(), "--cydia-firmware-preview", request);
                valid = result.succeeded() && CydiaRuntime::ParseCapabilityPreview(result.output, &preview);
            } @finally { [self.database endSettingsChange]; }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO; self.ready = valid;
                self.previewDiagnostics = valid ? nil : CapabilityResultDetails(result);
                if (valid) {
                    self->_preview = preview; self->_reviewedRequest = request;
                    self.status = preview.changes.empty() ? CapabilityText(@"CAPABILITIES_NO_CHANGES") : CapabilityText(@"CAPABILITIES_REVIEW");
                } else {
                    self->_preview = CydiaRuntime::CapabilityPreview();
                    self.status = CapabilityText(@"CAPABILITIES_PREVIEW_FAILED");
                }
                [self updateControls];
                if (!valid && self.view.window != nil && self.presentedViewController == nil)
                    [self showMessage:self.status details:YES];
            });
        }
    });
}
- (void)confirmApply {
    if (![self operationAvailable] || !self.ready || _preview.changes.empty()) return;
    UIAlertController *alert([UIAlertController alertControllerWithTitle:CapabilityText(@"CAPABILITIES_APPLY")
        message:[NSString stringWithFormat:CapabilityText(@"CAPABILITIES_CONFIRM"), (unsigned long)_preview.changes.size()]
        preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CONFIRM") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self applyReviewedCapabilities];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)applyReviewedCapabilities {
    if (![self operationAvailable] || !self.ready) return;
    CydiaRuntime::Privileged::Request reviewed(_reviewedRequest);
    reviewed.payload = _preview.reviewToken;
    self.busy = YES; self.ready = NO;
    self.status = CapabilityText(@"CAPABILITIES_APPLYING");
    [self updateControls];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            if (![self.database beginSettingsChange]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.busy = NO; self.ready = YES;
                    self.status = CapabilityText(@"SETTINGS_WAIT_FOR_OPERATION");
                    [self updateControls]; [self showMessage:CapabilityText(@"SETTINGS_WAIT_FOR_OPERATION")];
                });
                return;
            }
            CydiaRuntime::PrivilegedClient::Result result;
            @try { result = CydiaRuntime::PrivilegedClient::Run(CydiaAPT::PrivilegedHelperPath(), "--cydia-firmware", reviewed); }
            @finally { [self.database endSettingsChange]; }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                self.status = CapabilityText(result.succeeded() ? @"CAPABILITIES_COMPLETED" : @"CAPABILITIES_APPLY_FAILED");
                /* Keep a failed apply separate from the automatic preview:
                 * refreshing actual package state must not erase its output. */
                self.operationDiagnostics = result.succeeded() ? nil : CapabilityResultDetails(result);
                [self updateControls];
                /* Even a failed dpkg run may leave partial providers. Reload
                 * the package view before the next review of actual state. */
                id<CydiaDelegate, NSObject> delegate([self delegate]);
                if ([delegate respondsToSelector:@selector(reloadDataWithInvocation:)]) [delegate reloadDataWithInvocation:nil];
                if (self.view.window != nil)
                    [self showMessage:self.status details:!result.succeeded()];
                [self refreshPreview];
            });
        }
    });
}
- (BOOL)hasDiagnostics { return self.previewDiagnostics.length != 0 || self.operationDiagnostics.length != 0; }
- (BOOL)isDetailsSection:(NSInteger)section {
    return self.ready ? section == 3 : section == 1 && [self hasDiagnostics];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return self.ready ? 4 : [self hasDiagnostics] ? 2 : 1; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == 0 || [self isDetailsSection:section]) return 1;
    return section == 1 ? MAX((NSInteger)_preview.changes.size(), 1) : MAX((NSInteger)_preview.preserved.size(), 1);
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if (!self.ready) return nil;
    if (section == 1) return CapabilityText(@"CAPABILITIES_CHANGES");
    if (section == 2) return CapabilityText(@"CAPABILITIES_PRESERVED");
    return nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"capability"]);
    if (cell == nil) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"capability"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessibilityTraits = UIAccessibilityTraitStaticText;
    cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (path.section == 0) {
        cell.textLabel.text = self.status ?: CapabilityText(@"CAPABILITIES_REVIEW");
        cell.detailTextLabel.text = CapabilityText(@"CAPABILITIES_EXPLANATION");
        cell.accessibilityIdentifier = @"cydia.settings.capabilities.summary";
        if (self.busy) {
            UIActivityIndicatorView *spinner([[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray]);
            spinner.color = cell.textLabel.textColor; [spinner startAnimating]; cell.accessoryView = spinner;
        } else cell.accessoryView = nil;
        return cell;
    }
    cell.accessoryView = nil;
    if ([self isDetailsSection:path.section]) {
        cell.textLabel.text = CapabilityDetailsTitle();
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = UIAccessibilityTraitButton; cell.accessibilityIdentifier = @"cydia.settings.capabilities.details";
        return cell;
    }
    const auto &rows = path.section == 1 ? _preview.changes : _preview.preserved;
    if (rows.empty()) {
        cell.textLabel.text = CapabilityText(path.section == 1 ? @"CAPABILITIES_NO_CHANGES" : @"CAPABILITIES_NONE");
        cell.accessibilityIdentifier = @"cydia.settings.capabilities.empty";
        return cell;
    }
    const CydiaRuntime::CapabilityCandidate &candidate(rows[path.row]);
    cell.textLabel.text = CapabilityString(candidate.package);
    if (path.section == 1) {
        cell.detailTextLabel.text = [NSString stringWithFormat:CapabilityText(candidate.action == "create" ? @"CAPABILITY_CREATE" : @"CAPABILITY_UPDATE"), CapabilityString(candidate.version)];
    } else {
        NSString *identity([NSString stringWithFormat:CapabilityText(@"CAPABILITY_PROVIDER"), CapabilityString(candidate.providerPackage),
            CapabilityString(candidate.providerArchitecture), CapabilityString(candidate.providerVersion)]);
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", CapabilityReason(candidate.reason), identity];
    }
    cell.accessibilityIdentifier = [@"cydia.settings.capabilities.package." stringByAppendingString:cell.textLabel.text];
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES]; if (![self isDetailsSection:path.section]) return;
    [self showDetails];
}
- (void)showDetails {
    NSMutableArray<NSString *> *blocks([NSMutableArray array]);
    if (self.operationDiagnostics.length != 0)
        [blocks addObject:[NSString stringWithFormat:@"%@\n%@", CapabilityText(@"CAPABILITIES_APPLY_FAILED"), self.operationDiagnostics]];
    if (self.previewDiagnostics.length != 0)
        [blocks addObject:[NSString stringWithFormat:@"%@\n%@", CapabilityText(@"CAPABILITIES_PREVIEW_FAILED"), self.previewDiagnostics]];
    if (self.ready) {
        [blocks addObject:[NSString stringWithFormat:CapabilityText(@"CAPABILITIES_ENVIRONMENT"),
            CapabilityString(_preview.adminDirectory), CapabilityString(_preview.rootDirectory)]];
        for (const auto &candidate : _preview.preserved) {
            [blocks addObject:[NSString stringWithFormat:@"%@\n%@\n%@", CapabilityString(candidate.package),
            [NSString stringWithFormat:CapabilityText(@"CAPABILITY_PROVIDER"), CapabilityString(candidate.providerPackage),
                CapabilityString(candidate.providerArchitecture), CapabilityString(candidate.providerVersion)], CapabilityString(candidate.providerStatus)]];
        }
    }
    UIViewController *controller([[UIViewController alloc] init]);
    controller.navigationItem.title = CapabilityDetailsTitle();
    UITextView *view([[UITextView alloc] init]); view.editable = NO; view.text = [blocks componentsJoinedByString:@"\n\n"];
    view.accessibilityIdentifier = @"cydia.settings.capabilities.details.text";
    view.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; view.adjustsFontForContentSizeCategory = YES;
    view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:self.traitCollection];
    view.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    controller.view = view; [self.navigationController pushViewController:controller animated:YES];
}
- (void)showMessage:(NSString *)message {
    [self showMessage:message details:NO];
}
- (void)showMessage:(NSString *)message details:(BOOL)details {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:CapabilityText(@"CAPABILITIES") message:message preferredStyle:UIAlertControllerStyleAlert]);
    if (details && [self hasDiagnostics]) {
        [alert addAction:[UIAlertAction actionWithTitle:CapabilityDetailsTitle() style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
            [self showDetails];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
