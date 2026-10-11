/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RecoveryController.h"
#import "Cydia/Database.h"
#import "Cydia/Package.h"
#import "Cydia/CydiaDelegate.h"
#import "Cydia/UIColor+Cydia.h"
#import "Cydia/AdvancedSettingsController.h"
#import "CyteKit/Localize.h"
#include "Cydia/RecoveryPlan.hpp"
#include "Cydia/PrivilegedClient.h"
#include "Cydia/AptRuntime.hpp"

static NSString *RecoveryText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Recovery"];
}
static NSString *RecoveryEmergencyText(NSString *key) {
    return [NSString stringWithFormat:RecoveryText(key), UCLocalize("FORCIBLY_CLEAR")];
}
static NSString *RecoveryString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?:
        [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSISOLatin1StringEncoding];
}
static void RecoveryStyle(UITableViewCell *cell) {
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:cell.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:cell.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:cell.traitCollection];
}

@protocol RecoveryApplicationDelegate <CydiaDelegate, NSObject>
- (void)reinstallPackage:(Package *)package;
@end
@interface CydiaRecoveryDetailsController : CyteViewController
- (instancetype)initWithDetails:(NSString *)details;
@end
@implementation CydiaRecoveryDetailsController {
    NSString *details_;
}
- (instancetype)initWithDetails:(NSString *)details { if ((self = [super init]) != nil) details_ = [details copy]; return self; }
- (void)loadView {
    UITextView *text([[UITextView alloc] initWithFrame:CGRectZero]);
    text.editable = NO; text.text = details_; text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text.adjustsFontForContentSizeCategory = YES;
    text.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:self.traitCollection];
    text.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection]; self.view = text;
}
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.title = RecoveryText(@"RECOVERY_DETAILS"); }
@end
@interface CydiaRecoveryPackageController : CyteViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithDatabase:(Database *)database identifier:(NSString *)identifier;
@end
@implementation CydiaRecoveryPackageController {
    Database *database_;
    NSString *identifier_;
    NSString *packageName_;
    UITableView *table_;
    CydiaRuntime::Recovery::Review review_;
    NSString *message_;
    NSString *details_;
    BOOL busy_, ready_, ordinaryRepairFailed_;
}
- (instancetype)initWithDatabase:(Database *)database identifier:(NSString *)identifier {
    if ((self = [super init]) != nil) { database_ = database; identifier_ = [identifier copy]; }
    return self;
}
- (Package *)currentPackage {
    @synchronized (database_) {
        for (Package *package in [database_ packages]) if ([[package dpkgId] isEqual:identifier_]) return package;
    }
    return nil;
}
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self;
    table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 80;
    table_.accessibilityIdentifier = @"cydia.recovery.package"; self.view = table_;
}
- (void)viewDidLoad {
    [super viewDidLoad]; packageName_ = [[self currentPackage] name] ?: identifier_;
    self.navigationItem.title = packageName_;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshReview)];
    [self refreshReview];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:RecoveryText(@"RECOVERY_TITLE") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)updateControls {
    self.navigationItem.rightBarButtonItem.enabled = !busy_; self.navigationItem.hidesBackButton = busy_;
    [table_ reloadData];
}
- (void)refreshReview {
    if (busy_) return;
    busy_ = YES; ready_ = NO; message_ = UCLocalize("LOADING"); [self updateControls];
    const std::string identity([identifier_ UTF8String] ?: "");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            CydiaRuntime::PrivilegedClient::Result result{};
            CydiaRuntime::Recovery::Review review; bool parsed(false), available(false);
            if ([database_ beginSettingsChange]) {
                @try {
                    result = CydiaRuntime::PrivilegedClient::RunNativeCommand("--cydia-recovery-preview", CydiaRuntime::Privileged::SerializeFields({identity}));
                    parsed = result.succeeded() && CydiaRuntime::Recovery::ParseReview(result.output, &review); available = true;
                } @finally { [database_ endSettingsChange]; }
            }
            const auto captured(review);
            NSString *detail(RecoveryString(result.error));
            dispatch_async(dispatch_get_main_queue(), ^{
                busy_ = NO; ready_ = parsed; review_ = captured; if (!parsed) details_ = detail;
                message_ = parsed ? nil : RecoveryText(available ? @"RECOVERY_UNAVAILABLE" : @"RECOVERY_BUSY");
                [self updateControls];
            });
        }
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : section == 1 ? 4 : details_.length != 0 ? 1 : 0;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 2 ? RecoveryText(@"RECOVERY_DETAILS") : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 0) return message_ ?: RecoveryText(@"RECOVERY_REPAIR_EXPLANATION");
    if (section == 1) {
        if (ready_ && !review_.analysis.canEmergencyRemove) {
            if (review_.analysis.reason == "not-damaged") return RecoveryText(@"RECOVERY_REPAIR_COMPLETE");
            NSMutableArray *affected([NSMutableArray array]);
            for (const auto &package : review_.analysis.affected) [affected addObject:RecoveryString(package)];
            return affected.count == 0 ? RecoveryText(@"RECOVERY_PROTECTED") :
                [NSString stringWithFormat:@"%@\n%@: %@", RecoveryText(@"RECOVERY_PROTECTED"), RecoveryText(@"RECOVERY_AFFECTED"), [affected componentsJoinedByString:@", "]];
        }
        return ordinaryRepairFailed_ ? RecoveryEmergencyText(@"RECOVERY_FAILED") : RecoveryEmergencyText(@"RECOVERY_NORMAL_FIRST");
    }
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]); RecoveryStyle(cell);
    if (path.section == 0) {
        cell.textLabel.text = packageName_; cell.detailTextLabel.text = identifier_; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 2) {
        cell.textLabel.text = RecoveryText(@"RECOVERY_DETAILS"); cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSArray *titles(@[RecoveryText(@"RECOVERY_REPAIR"), UCLocalize("REINSTALL"), UCLocalize("REMOVE"), UCLocalize("FORCIBLY_CLEAR")]);
        cell.textLabel.text = titles[path.row]; cell.accessibilityTraits |= UIAccessibilityTraitButton;
        Package *package([self currentPackage]);
        const BOOL enabled(!busy_ && (path.row == 3 ? ready_ && ordinaryRepairFailed_ && review_.analysis.canEmergencyRemove :
            path.row == 0 ? ready_ && (review_.analysis.canConfigure || review_.analysis.state == "half-installed") :
            path.row == 1 ? package != nil && [package canReinstall] : package != nil));
        cell.textLabel.enabled = enabled; if (!enabled) cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (path.row == 3) cell.detailTextLabel.text = RecoveryText(@"RECOVERY_EMERGENCY_EXPLANATION");
    }
    return cell;
}
- (void)runCommand:(const std::string &)command review:(const CydiaRuntime::Recovery::Review &)review {
    busy_ = YES; message_ = RecoveryText(@"RECOVERY_WORKING"); [self updateControls];
    const std::string operation(command), payload(CydiaRuntime::Privileged::SerializeFields({review.analysis.package, review.token}));
    const bool emergency(operation == "--cydia-recovery-remove");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            CydiaRuntime::PrivilegedClient::Result result{}; bool available(false);
            if ([database_ beginSettingsChange]) {
                @try { result = CydiaRuntime::PrivilegedClient::RunNativeCommand(operation, payload); available = true; }
                @finally { [database_ endSettingsChange]; }
            }
            const bool success(available && result.succeeded());
            const int exitCode(result.exitCode);
            const std::string marker("CYDIA-RECOVERY-CONFIGURE-STARTED\n");
            const bool repairAttempted(result.output.compare(0, marker.size(), marker) == 0 && result.launchError == 0 && result.termSignal == 0);
            const std::string output(repairAttempted ? result.output.substr(marker.size()) : result.output);
            NSString *detail([NSString stringWithFormat:@"%@%@", RecoveryString(output) ?: @"", RecoveryString(result.error) ?: @""]);
            dispatch_async(dispatch_get_main_queue(), ^{
                busy_ = NO; details_ = detail;
                if (!emergency && available && repairAttempted && (exitCode == 1 || exitCode == 2)) ordinaryRepairFailed_ = YES;
                NSString *key(!available ? @"RECOVERY_BUSY" : exitCode == 75 ? @"RECOVERY_STATE_CHANGED" :
                    success ? emergency ? @"RECOVERY_COMPLETED" : @"RECOVERY_REPAIR_COMPLETE" : emergency ? @"RECOVERY_REMOVE_FAILED" : @"RECOVERY_FAILED");
                message_ = [key isEqual:@"RECOVERY_FAILED"] ? RecoveryEmergencyText(key) : RecoveryText(key); [self updateControls];
                id<RecoveryApplicationDelegate> delegate((id)self.delegate);
                if (available && [delegate respondsToSelector:@selector(syncData)]) [delegate syncData];
                if (available && !success) [self refreshReview];
                if (success) { ready_ = NO; [self updateControls]; }
                if (success) [self showMessage:message_];
            });
        }
    });
}
- (void)confirmEmergency {
    if (!ready_ || busy_ || !ordinaryRepairFailed_ || !review_.analysis.canEmergencyRemove) return;
    const auto captured(review_);
    UIAlertController *alert([UIAlertController alertControllerWithTitle:RecoveryText(@"RECOVERY_CONFIRM")
        message:[NSString stringWithFormat:@"%@\n%@\n\n%@", packageName_, identifier_, RecoveryText(@"RECOVERY_CONSEQUENCES")]
        preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("FORCIBLY_CLEAR") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *) {
        [self runCommand:"--cydia-recovery-remove" review:captured];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 2) {
        CydiaRecoveryDetailsController *details([[CydiaRecoveryDetailsController alloc] initWithDetails:details_]);
        [details setDelegate:self.delegate]; [self.navigationController pushViewController:details animated:YES]; return;
    }
    if (path.section != 1 || busy_) return;
    if (path.row == 3) { [self confirmEmergency]; return; }
    if (path.row == 0) { if (ready_) [self runCommand:"--cydia-recovery-configure" review:review_]; return; }
    Package *package([self currentPackage]);
    if (package == nil) { [self showMessage:RecoveryText(@"RECOVERY_STATE_CHANGED")]; return; }
    if (path.row == 1 && ![package canReinstall]) { [self showMessage:RecoveryText(@"RECOVERY_REINSTALL_UNAVAILABLE")]; return; }
    id<RecoveryApplicationDelegate> delegate((id)self.delegate);
    if (path.row == 1 && ![delegate respondsToSelector:@selector(reinstallPackage:)]) return;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (path.row == 1) [delegate reinstallPackage:package]; else [delegate removePackage:package];
    }];
}
@end

@interface CydiaRecoveryController () <UITableViewDataSource, UITableViewDelegate>
@end
@implementation CydiaRecoveryController {
    Database *database_;
    NSArray<NSString *> *identifiers_;
    NSArray<Package *> *packages_;
    UITableView *table_;
}
- (instancetype)initWithDatabase:(Database *)database packages:(NSArray *)packages {
    if ((self = [super init]) != nil) {
        database_ = database; NSMutableArray *identifiers([NSMutableArray array]);
        for (Package *package in packages) if ([package half] && [package dpkgId] != nil) [identifiers addObject:[package dpkgId]];
        identifiers_ = identifiers;
    }
    return self;
}
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self; table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 80;
    table_.accessibilityIdentifier = @"cydia.recovery.packages"; self.view = table_;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.navigationItem.title = RecoveryText(@"RECOVERY_TITLE");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("TEMPORARY_IGNORE") style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadData)];
    [self reloadData];
}
- (void)close { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (void)reloadData {
    [super reloadData]; NSMutableArray *packages([NSMutableArray array]);
    @synchronized (database_) {
        for (Package *package in [database_ packages])
            if ([package half] && [identifiers_ containsObject:[package dpkgId]]) [packages addObject:package];
    }
    packages_ = packages; [table_ reloadData];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadData]; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return packages_.count; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return RecoveryText(packages_.count == 0 ? @"RECOVERY_EMPTY" : @"RECOVERY_EXPLANATION");
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]); RecoveryStyle(cell);
    Package *package(packages_[path.row]); cell.textLabel.text = [package name]; cell.detailTextLabel.text = [package dpkgId];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES]; Package *package(packages_[path.row]);
    CydiaRecoveryPackageController *controller([[CydiaRecoveryPackageController alloc] initWithDatabase:database_ identifier:[package dpkgId]]);
    [controller setDelegate:self.delegate]; [self.navigationController pushViewController:controller animated:YES];
}
@end
