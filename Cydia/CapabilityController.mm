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
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
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
                if (valid) {
                    self->_preview = preview; self->_reviewedRequest = request;
                    self.status = preview.changes.empty() ? CapabilityText(@"CAPABILITIES_NO_CHANGES") : CapabilityText(@"CAPABILITIES_REVIEW");
                } else {
                    self->_preview = CydiaRuntime::CapabilityPreview();
                    self.status = CapabilityText(@"CAPABILITIES_PREVIEW_FAILED");
                }
                [self updateControls];
                if (!valid && !result.error.empty() && self.view.window != nil && self.presentedViewController == nil)
                    [self showMessage:[NSString stringWithFormat:@"%@\n\n%@", self.status, CapabilityString(result.error)]];
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
                [self updateControls];
                /* Even a failed dpkg run may leave partial providers. Reload
                 * the package view before the next review of actual state. */
                id<CydiaDelegate, NSObject> delegate([self delegate]);
                if ([delegate respondsToSelector:@selector(reloadDataWithInvocation:)]) [delegate reloadDataWithInvocation:nil];
                if (self.view.window != nil) {
                    NSString *message(self.status);
                    if (!result.succeeded() && !result.error.empty()) message = [NSString stringWithFormat:@"%@\n\n%@", message, CapabilityString(result.error)];
                    [self showMessage:message];
                }
                [self refreshPreview];
            });
        }
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return self.ready ? 3 : 1; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    return section == 1 ? MAX((NSInteger)_preview.changes.size(), 1) : MAX((NSInteger)_preview.preserved.size(), 1);
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return CapabilityText(@"CAPABILITIES_CHANGES");
    if (section == 2) return CapabilityText(@"CAPABILITIES_PRESERVED");
    return nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 0 && self.ready) return [NSString stringWithFormat:CapabilityText(@"CAPABILITIES_ENVIRONMENT"),
        CapabilityString(_preview.adminDirectory), CapabilityString(_preview.rootDirectory)];
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
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@\n%@", CapabilityReason(candidate.reason), identity, CapabilityString(candidate.providerStatus)];
    }
    cell.accessibilityIdentifier = [@"cydia.settings.capabilities.package." stringByAppendingString:cell.textLabel.text];
    return cell;
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:CapabilityText(@"CAPABILITIES") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
