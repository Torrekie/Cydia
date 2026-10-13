/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/BootstrapAccessController.h"
#import "Cydia/Database.h"
#import "Cydia/RuntimeAccessController.h"
#import "Cydia/UIColor+Cydia.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/PrivilegedClient.h"
#include "Cydia/SourceDocumentCommit.hpp"
#include <cerrno>
#include <string>
#include <vector>

namespace {
NSString *AccessText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"BootstrapAccess"];
}
NSString *RuntimeAccessText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"RuntimeAccess"];
}
NSString *AccessString(const std::string &bytes) {
    return [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
}
NSString *StatusKey(const std::string &status) {
    if (status == "strict") return @"BOOTSTRAP_ACCESS_STRICT";
    if (status == "approved") return @"BOOTSTRAP_ACCESS_APPROVED";
    return @"BOOTSTRAP_ACCESS_PENDING";
}
struct Review {
    std::string token;
    std::string admin;
    std::string descriptions;
    std::string status;
};
bool ParseReview(const std::string &bytes, Review *review) {
    if (bytes.size() > 65536 || review == nullptr) return false;
    std::vector<std::string> fields;
    CydiaRuntime::Privileged::Error error;
    if (!CydiaRuntime::Privileged::ParseFields(bytes, 4, &fields, &error) ||
        fields[1].empty() || fields[1][0] != '/' || fields[1].find('\0') != std::string::npos ||
        fields[1].find('\n') != std::string::npos || fields[1].find('\r') != std::string::npos ||
        AccessString(fields[1]) == nil || AccessString(fields[2]) == nil ||
        (fields[3] != "strict" && fields[3] != "pending" && fields[3] != "approved") ||
        (fields[3] == "strict" && !fields[0].empty()) ||
        (fields[3] != "strict" && (fields[0].empty() || fields[2].empty()))) return false;
    review->token = fields[0]; review->admin = fields[1];
    review->descriptions = fields[2]; review->status = fields[3];
    return true;
}
std::string FailureDetails(const char *command, const CydiaRuntime::PrivilegedClient::Result &result) {
    return std::string(command) + ": exit=" + std::to_string(result.exitCode) +
        ", launch=" + std::to_string(result.launchError) + ", signal=" + std::to_string(result.termSignal) +
        ", output_limit=" + (result.outputLimitExceeded ? "1" : "0") + "\n" + result.error;
}
}

@interface CydiaBootstrapAccessController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation CydiaBootstrapAccessController {
    Database *database_;
    UITableView *table_;
    BOOL busy_;
    BOOL reviewed_;
    BOOL revocable_;
    BOOL checkAvailable_;
    NSString *message_;
    std::string details_;
    Review review_;
    CydiaRuntime::Privileged::Request reviewedRequest_;
}
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) database_ = database;
    return self;
}
- (NSURL *)navigationURL { return nil; }
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self;
    table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 72;
    table_.accessibilityIdentifier = @"cydia.settings.bootstrap-access";
    self.view = table_;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.navigationItem.title = AccessText(@"BOOTSTRAP_ACCESS_TITLE");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:AccessText(@"BOOTSTRAP_ACCESS_REVIEW")
        style:UIBarButtonItemStylePlain target:self action:@selector(loadReview)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"cydia.settings.bootstrap-access.review";
    [self applyAppearance];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self loadReview]; }
- (void)applyAppearance {
    table_.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    table_.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
    [table_ reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) [self applyAppearance];
}
- (void)updateControls {
    self.navigationItem.rightBarButtonItem.enabled = !busy_;
    [table_ reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 4; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return reviewed_ || !review_.admin.empty() ? 2 : 0;
    if (section == 1) return review_.descriptions.empty() ? 0 : 1;
    if (section == 2) return ([self canApprove] ? 1 : 0) + (checkAvailable_ ? 1 : 0) + (revocable_ ? 1 : 0);
    return details_.empty() ? 0 : 1;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 1 && !review_.descriptions.empty() ? AccessText(@"BOOTSTRAP_ACCESS_GROUPS") : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        NSString *explanation(AccessText(@"BOOTSTRAP_ACCESS_EXPLANATION"));
        NSString *status(reviewed_ && review_.status == "strict" ? AccessText(@"BOOTSTRAP_ACCESS_NOT_REQUIRED") : nil);
        if (status.length) explanation = [explanation stringByAppendingFormat:@"\n\n%@", status];
        if (message_.length) explanation = [explanation stringByAppendingFormat:@"\n\n%@", message_];
        return explanation;
    }
    return section == 1 && !review_.descriptions.empty() ?
        [NSString stringWithFormat:@"%@\n\n%@", AccessText(@"BOOTSTRAP_ACCESS_WARNING"), AccessText(@"BOOTSTRAP_ACCESS_SCOPE")] : nil;
}
- (BOOL)canApprove { return reviewed_ && review_.status == "pending" && !review_.token.empty(); }
- (BOOL)isCheckRow:(NSInteger)row { return checkAvailable_ && row == ([self canApprove] ? 1 : 0); }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]);
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
    cell.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (path.section == 0) {
        cell.textLabel.text = AccessText(path.row == 0 ? @"BOOTSTRAP_ACCESS_DATABASE" : @"BOOTSTRAP_ACCESS_STATUS");
        // A retained database location is useful while rereviewing, but an
        // earlier policy must not look freshly verified during or after a
        // failed access operation.
        cell.detailTextLabel.text = path.row == 0 ? AccessString(review_.admin) :
            AccessText(busy_ ? @"BOOTSTRAP_ACCESS_REVIEWING" : reviewed_ ?
                StatusKey(review_.status) : @"BOOTSTRAP_ACCESS_FAILED");
    } else if (path.section == 1) cell.textLabel.text = AccessString(review_.descriptions);
    else if (path.section == 2) {
        const BOOL check([self isCheckRow:path.row]);
        const BOOL revoke(!check && (![self canApprove] || path.row != 0));
        cell.textLabel.text = check ? RuntimeAccessText(@"ACCESS_CHECK_TITLE") :
            AccessText(revoke ? @"BOOTSTRAP_ACCESS_REVOKE" : @"BOOTSTRAP_ACCESS_ALLOW");
        if (check) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.textColor = busy_ ? [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection] : cell.tintColor;
        cell.selectionStyle = busy_ ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits = busy_ ? UIAccessibilityTraitButton | UIAccessibilityTraitNotEnabled : UIAccessibilityTraitButton;
        cell.accessibilityIdentifier = check ? @"cydia.settings.bootstrap-access.check" :
            revoke ? @"cydia.settings.bootstrap-access.revoke" : @"cydia.settings.bootstrap-access.allow";
    } else {
        cell.textLabel.text = AccessText(@"BOOTSTRAP_ACCESS_DETAILS");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 3) { [self showDetails]; return; }
    if (path.section != 2 || busy_) return;
    if ([self isCheckRow:path.row]) {
        CydiaRuntimeAccessController *controller([[CydiaRuntimeAccessController alloc] initWithDatabase:database_]);
        controller.delegate = self.delegate;
        [self.navigationController pushViewController:controller animated:YES]; return;
    }
    if (![self canApprove] || path.row != 0) { if (revocable_) [self confirmRevoke]; return; }
    const CydiaRuntime::Privileged::Request request(reviewedRequest_);
    NSString *message([NSString stringWithFormat:@"%@\n\n%@\n\n%@", AccessText(@"BOOTSTRAP_ACCESS_CONFIRM"),
        AccessString(review_.admin), AccessString(review_.descriptions)]);
    UIAlertController *alert([UIAlertController alertControllerWithTitle:AccessText(@"BOOTSTRAP_ACCESS_TITLE")
        message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:AccessText(@"BOOTSTRAP_ACCESS_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:AccessText(@"BOOTSTRAP_ACCESS_ALLOW") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self applyRequest:request revoke:NO];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmRevoke {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:AccessText(@"BOOTSTRAP_ACCESS_REVOKE")
        message:AccessText(@"BOOTSTRAP_ACCESS_REVOKE_CONFIRM") preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:AccessText(@"BOOTSTRAP_ACCESS_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:AccessText(@"BOOTSTRAP_ACCESS_REVOKE") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self applyRequest:CydiaRuntime::Privileged::Request() revoke:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showDetails {
    UIViewController *controller([[UIViewController alloc] init]); controller.navigationItem.title = AccessText(@"BOOTSTRAP_ACCESS_DETAILS");
    UITextView *text([[UITextView alloc] init]); text.editable = NO;
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; text.adjustsFontForContentSizeCategory = YES;
    text.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:self.traitCollection];
    text.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    text.text = AccessString(details_) ?: @""; controller.view = text;
    [self.navigationController pushViewController:controller animated:YES];
}
- (void)loadReview {
    [self loadReviewWithMessage:nil];
}
- (void)loadReviewWithMessage:(NSString *)outcome {
    if (busy_) return;
    busy_ = YES; reviewed_ = NO; checkAvailable_ = NO;
    NSString *reviewing(AccessText(@"BOOTSTRAP_ACCESS_REVIEWING"));
    message_ = outcome.length ? [outcome stringByAppendingFormat:@"\n\n%@", reviewing] : reviewing;
    details_.clear(); [self updateControls];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            namespace Client = CydiaRuntime::PrivilegedClient;
            CydiaSources::ProtectedFileSnapshot savedApproval;
            const BOOL savedApprovalReadable(CydiaSources::ReadProtectedFile(
                CydiaRuntime::PackageDatabasePaths::Current().CydiaStateDirectory() + "/admin-access.conf", &savedApproval));
            // A strict database can retain an inactive approval. Hide revoke
            // only after a trusted read confirms there is nothing to clear;
            // an unreadable policy must still permit recovery clearing.
            const BOOL canRevoke(!savedApprovalReadable || !savedApproval.bytes.empty());
            CydiaRuntime::Privileged::Request request;
            Client::Result result = {}; Review review;
            const BOOL acquired([database_ beginSettingsChange]);
            if (acquired) {
                @try {
                    request = Client::RuntimeRequest("");
                    result = Client::Run(CydiaAPT::PrivilegedHelperPath(), "--cydia-admin-access-review", request, 65536, 4000);
                }
                @finally { [database_ endSettingsChange]; }
            }
            const BOOL valid(acquired && result.succeeded() && ParseReview(result.output, &review));
            dispatch_async(dispatch_get_main_queue(), ^{
                busy_ = NO; reviewed_ = valid; revocable_ = canRevoke;
                if (valid) {
                    review_ = review;
                    checkAvailable_ = review.status == "strict" || review.status == "approved";
                    reviewedRequest_ = request; reviewedRequest_.payload = review.token;
                    message_ = outcome;
                } else {
                    message_ = AccessText(!acquired ? @"BOOTSTRAP_ACCESS_BUSY" : result.launchError == ETIMEDOUT ? @"BOOTSTRAP_ACCESS_TIMEOUT" : @"BOOTSTRAP_ACCESS_FAILED");
                    if (acquired) details_ = FailureDetails("--cydia-admin-access-review", result) +
                        (result.succeeded() ? "\nInvalid access review response.\n" : "");
                    // A failed database review does not establish whether a
                    // saved approval exists. Use only the trusted policy read
                    // above for revoke visibility and discard any old status.
                    review_ = Review();
                    reviewedRequest_ = CydiaRuntime::Privileged::Request();
                    if (outcome.length) message_ = [outcome stringByAppendingFormat:@"\n\n%@", message_];
                }
                [self updateControls];
            });
        }
    });
}
- (void)applyRequest:(const CydiaRuntime::Privileged::Request &)request revoke:(BOOL)revoke {
    if (busy_) return;
    const CydiaRuntime::Privileged::Request copy(request);
    busy_ = YES; reviewed_ = NO; checkAvailable_ = NO; details_.clear(); [self updateControls];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            namespace Client = CydiaRuntime::PrivilegedClient;
            Client::Result result = {};
            const BOOL acquired([database_ beginSettingsChange]);
            const char *command(revoke ? "--cydia-admin-access-revoke" : "--cydia-admin-access-approve");
            if (acquired) {
                @try {
                    const auto operation(revoke ? Client::RuntimeRequest("") : copy);
                    result = Client::Run(CydiaAPT::PrivilegedHelperPath(), command, operation, 65536, 4000);
                }
                @finally { [database_ endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                busy_ = NO; review_.token.clear();
                const BOOL saved(acquired && result.succeeded());
                if (saved) {
                    // Refresh the real status and token after either write.
                    // A successful revoke must offer a new explicit approval
                    // without making users discover the manual review button.
                    review_ = Review(); revocable_ = YES;
                    reviewedRequest_ = CydiaRuntime::Privileged::Request();
                    [self loadReviewWithMessage:AccessText(revoke ? @"BOOTSTRAP_ACCESS_REVOKED" : @"BOOTSTRAP_ACCESS_SAVED")];
                    return;
                } else {
                    message_ = AccessText(!acquired ? @"BOOTSTRAP_ACCESS_BUSY" : result.launchError == ETIMEDOUT ? @"BOOTSTRAP_ACCESS_TIMEOUT" : @"BOOTSTRAP_ACCESS_FAILED");
                    if (acquired) details_ = FailureDetails(command, result);
                }
                [self updateControls];
            });
        }
    });
}
@end
