/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/KeyringImportController.h"
#import "Cydia/Database.h"
#import "Cydia/CydiaDelegate.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"
#import "Sources.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/KeyringImport.hpp"
#include "Cydia/PrivilegedClient.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace Keys = CydiaRuntime::Keyring;
namespace Client = CydiaRuntime::PrivilegedClient;
static NSString *KeyText(NSString *key) { return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"]; }
static NSString *KeyString(const std::string &bytes) {
    return [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding] ?:
        [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSISOLatin1StringEncoding];
}
static std::string KeyBytes(NSString *text) { return text.UTF8String ? text.UTF8String : ""; }
static NSString *KeySourceSummary(CydiaSourceDefinition *source) {
    NSMutableArray *uris([NSMutableArray array]);
    for (NSString *uri in source.uris) {
        NSURLComponents *url([NSURLComponents componentsWithString:uri]);
        if (url != nil) { url.user = nil; url.password = nil; }
        [uris addObject:url.string ?: uri];
    }
    return [NSString stringWithFormat:@"%@\n%@", [uris componentsJoinedByString:@"\n"], [source.suites componentsJoinedByString:@" · "]];
}
static NSData *BoundedKey(NSURL *url) {
    if (!url.isFileURL) return nil;
    const BOOL scoped([url startAccessingSecurityScopedResource]);
    const int fd(open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    NSMutableData *data(nil); struct stat before, after;
    if (fd >= 0 && fstat(fd, &before) == 0 && S_ISREG(before.st_mode) && before.st_size > 0 &&
        static_cast<std::size_t>(before.st_size) <= Keys::MaximumKeyBytes) {
        data = [NSMutableData data]; char bytes[16384];
        for (;;) {
            const ssize_t count(read(fd, bytes, sizeof(bytes)));
            if (count < 0 && errno == EINTR) continue;
            if (count < 0 || (count > 0 && data.length + count > Keys::MaximumKeyBytes)) { data = nil; break; }
            if (count == 0) break;
            [data appendBytes:bytes length:count];
        }
        if (fstat(fd, &after) || before.st_dev != after.st_dev || before.st_ino != after.st_ino || before.st_size != after.st_size ||
            before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
            before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec ||
            data.length != static_cast<NSUInteger>(before.st_size)) data = nil;
    }
    if (fd >= 0) close(fd); if (scoped) [url stopAccessingSecurityScopedResource]; return data;
}
static bool KeyFields(const std::string &bytes, std::vector<std::string> *fields) {
    if (bytes.size() > 4 * 1024 * 1024) return false;
    std::size_t count(0), offset(0);
    while (offset < bytes.size()) {
        std::size_t length(0), digits(0);
        while (offset < bytes.size() && bytes[offset] >= '0' && bytes[offset] <= '9') {
            if (++digits > 8) return false;
            length = length * 10 + bytes[offset++] - '0';
        }
        if (!digits || offset == bytes.size() || bytes[offset++] != ':' || length >= bytes.size() - offset) return false;
        offset += length;
        if (bytes[offset++] != ',' || ++count > 256) return false;
    }
    CydiaRuntime::Privileged::Error error;
    return CydiaRuntime::Privileged::ParseFields(bytes, count, fields, &error);
}

@interface CydiaKeyringImportController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate> {
    Keys::Input _input;
    Keys::Review _review;
    CydiaRuntime::Privileged::Request _reviewedRequest;
}
@property(nonatomic, strong) Database *database;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) UIBarButtonItem *reviewButton;
@property(nonatomic, strong) NSURL *initialURL;
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic, copy) NSArray<CydiaSourceDefinition *> *sources;
@property(nonatomic, copy) NSIndexSet *editableSources;
@property(nonatomic, strong) CydiaSourceDefinition *selectedSource;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL reviewed;
@end

@implementation CydiaKeyringImportController
- (instancetype)initWithDatabase:(Database *)database { if ((self = [super init])) _database = database; return self; }
- (instancetype)initWithDatabase:(Database *)database importURL:(NSURL *)url {
    if ((self = [self initWithDatabase:database])) _initialURL = url; return self;
}
- (NSURL *)navigationURL { return [NSURL URLWithString:@"cydia://home/settings/key-import"]; }
- (void)loadView {
    UITableViewStyle style(UITableViewStyleGrouped);
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:style];
    self.table.dataSource = self; self.table.delegate = self; self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 88; self.table.accessibilityIdentifier = @"cydia.settings.key-import"; self.view = self.table;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.navigationItem.title = KeyText(@"KEY_IMPORT");
    self.reviewButton = [[UIBarButtonItem alloc] initWithTitle:KeyText(@"KEY_IMPORT_REVIEW") style:UIBarButtonItemStyleDone target:self action:@selector(reviewOrApply)];
    self.reviewButton.accessibilityIdentifier = @"cydia.settings.key-import.review"; self.navigationItem.rightBarButtonItem = self.reviewButton;
    [self applyAppearance]; [self updateControls];
}
- (void)reloadSources {
    self.sources = CydiaReadSourceDefinitions();
    self.editableSources = CydiaReadSourceDisplayEditability(self.sources, CydiaSources::Access::AdvancedSettings);
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.initialURL) { NSURL *url(self.initialURL); self.initialURL = nil; [self stageURL:url]; }
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.busy) return;
    CydiaSourceDefinition *selected(self.selectedSource); [self reloadSources]; self.selectedSource = nil;
    for (CydiaSourceDefinition *source in self.sources)
        if ([source.filePath isEqual:selected.filePath] && source.ordinal == selected.ordinal &&
            [source.original isEqual:selected.original] && CydiaSourceDefinitionCanEdit(source, CydiaSources::Access::AdvancedSettings)) {
            self.selectedSource = source; break;
        }
    if (selected != nil && self.selectedSource == nil) [self clearReview];
    [self updateControls];
}
- (void)applyAppearance {
    self.table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    self.table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection]; [self.table reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) || ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) [self applyAppearance];
}
- (BOOL)available {
    id<CydiaDelegate, NSObject> delegate([self delegate]);
    if (self.busy || ([delegate respondsToSelector:@selector(updating)] && [delegate updating])) {
        [self showMessage:KeyText(@"SETTINGS_WAIT_FOR_OPERATION")]; return NO;
    }
    return YES;
}
- (void)updateControls {
    self.reviewButton.enabled = !self.busy && !_input.bytes.empty() && self.selectedSource != nil;
    self.reviewButton.title = KeyText(self.reviewed ? @"KEY_IMPORT_ACTION" : @"KEY_IMPORT_REVIEW_ACTION");
    self.table.userInteractionEnabled = !self.busy; [self.table reloadData];
}
- (void)clearReview { self.reviewed = NO; _input.token.clear(); _review = Keys::Review(); [self updateControls]; }
- (void)acceptBytes:(const std::string &)bytes name:(NSString *)name {
    CydiaRuntime::Privileged::Error error;
    if (!Keys::CheckPublicKeyPackets(bytes, nullptr, &error)) { [self showMessage:KeyText(@"KEY_IMPORT_PUBLIC_ONLY")]; return; }
    _input.bytes = bytes; self.fileName = name; [self clearReview];
}
- (void)stageURL:(NSURL *)url {
    if (![self available]) return;
    NSData *data(BoundedKey(url));
    if (!data) { [self showMessage:KeyText(@"KEY_IMPORT_PUBLIC_ONLY")]; return; }
    const std::string bytes(static_cast<const char *>(data.bytes), data.length);
    [self acceptBytes:bytes name:url.lastPathComponent];
}
- (void)chooseFile {
    if (![self available]) return;
    UIDocumentPickerViewController *picker([[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"] inMode:UIDocumentPickerModeImport]);
    picker.delegate = self; picker.allowsMultipleSelection = NO; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 1) [self stageURL:urls.firstObject];
}
- (void)choosePackage {
    if (![self available]) return;
    UIAlertController *alert([UIAlertController alertControllerWithTitle:KeyText(@"KEY_IMPORT_PACKAGE") message:KeyText(@"KEY_IMPORT_PACKAGE_PROMPT") preferredStyle:UIAlertControllerStyleAlert]);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo;
        [field addTarget:self action:@selector(packageNameChanged:) forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *choose([UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self loadPackage:[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @""];
    }]); choose.enabled = NO; [alert addAction:choose];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)packageNameChanged:(UITextField *)field {
    if ([self.presentedViewController isKindOfClass:[UIAlertController class]])
        ((UIAlertController *)self.presentedViewController).actions.lastObject.enabled =
            [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length != 0;
}
- (void)loadPackage:(NSString *)package {
    self.busy = YES; [self updateControls];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            Client::Result result; std::vector<std::string> files;
            const BOOL acquired([self.database beginSettingsChange]);
            if (acquired) {
                @try { result = Client::RunNativeCommand("--cydia-key-package-files", CydiaRuntime::Privileged::SerializeFields({KeyBytes(package)})); }
                @finally { [self.database endSettingsChange]; }
            }
            const BOOL valid(acquired && result.succeeded() && KeyFields(result.output, &files));
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO; [self updateControls];
                if (!valid) { [self showFailure:result]; return; }
                if (files.empty()) { [self showMessage:KeyText(@"KEY_IMPORT_UNAVAILABLE")]; return; }
                UIAlertController *picker([UIAlertController alertControllerWithTitle:KeyText(@"KEY_IMPORT_PACKAGE") message:nil preferredStyle:UIAlertControllerStyleActionSheet]);
                for (const auto &file : files) {
                    NSString *path(KeyString(file));
                    [picker addAction:[UIAlertAction actionWithTitle:path style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self readPackage:package path:path]; }]];
                }
                [picker addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
                picker.popoverPresentationController.sourceView = self.table; picker.popoverPresentationController.sourceRect = CGRectMake(self.table.bounds.size.width / 2, 40, 1, 1);
                [self presentViewController:picker animated:YES completion:nil];
            });
        }
    });
}
- (void)readPackage:(NSString *)package path:(NSString *)path {
    self.busy = YES; [self updateControls];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            Client::Result result; const BOOL acquired([self.database beginSettingsChange]);
            if (acquired) {
                @try { result = Client::RunNativeCommand("--cydia-key-package-read", CydiaRuntime::Privileged::SerializeFields({KeyBytes(package), KeyBytes(path)})); }
                @finally { [self.database endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO; [self updateControls];
                if (!acquired || !result.succeeded()) [self showFailure:result];
                else [self acceptBytes:result.output name:[NSString stringWithFormat:@"%@: %@", package, path.lastPathComponent]];
            });
        }
    });
}
- (void)reviewOrApply {
    if (![self available] || !self.selectedSource || _input.bytes.empty()) return;
    if (self.reviewed) { [self confirmImport]; return; }
    _input.source = CydiaSources::CommitRequest(); _input.source.expected = [self.selectedSource snapshot];
    _input.source.mutation = CydiaSources::Mutation(CydiaSources::EditKind::ReplaceDefinition);
    _input.source.mutation.ordinal = self.selectedSource.ordinal; _input.source.mutation.contents = KeyBytes(self.selectedSource.original);
    _input.source.access = CydiaSources::Access::AdvancedSettings;
    self.busy = YES; [self updateControls];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            Client::Result result; Keys::Review review; CydiaRuntime::Privileged::Request request;
            BOOL valid(NO); const BOOL acquired([self.database beginSettingsChange]);
            if (acquired) {
                @try {
                    _input.source.expectedPolicy = CydiaReadSourceProtection().bytes;
                    request = Client::RuntimeRequest(Keys::SerializeInput(_input));
                    result = Client::Run(CydiaAPT::PrivilegedHelperPath(), "--cydia-key-preview", request);
                    CydiaRuntime::Privileged::Error error; valid = result.succeeded() && Keys::ParseReview(result.output, &review, &error);
                } @finally { [self.database endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO; self.reviewed = valid;
                if (valid) {
                    _review = review; _input.source = review.source; _input.token = review.token;
                    _reviewedRequest = request; _reviewedRequest.payload = Keys::SerializeInput(_input);
                } else { [self reloadSources]; self.selectedSource = nil; [self showFailure:result]; }
                [self updateControls];
            });
        }
    });
}
- (void)confirmImport {
    NSString *fingerprints(KeyString([&]() { std::string value; for (const auto &f : _review.fingerprints) value += f + '\n'; return value; }()));
    NSString *scope(KeySourceSummary(self.selectedSource));
    UIAlertController *alert([UIAlertController alertControllerWithTitle:KeyText(@"KEY_IMPORT") message:[NSString stringWithFormat:@"%@\n\n%@\n%@", KeyText(@"KEY_IMPORT_CONFIRM"), fingerprints, scope] preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:KeyText(@"KEY_IMPORT") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self applyImport]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)applyImport {
    self.busy = YES; [self updateControls];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            Client::Result result; const BOOL acquired([self.database beginSettingsChange]);
            if (acquired) {
                @try { result = Client::Run(CydiaAPT::PrivilegedHelperPath(), "--cydia-key-import", _reviewedRequest); }
                @finally { [self.database endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO; [self clearReview]; [self reloadSources]; self.selectedSource = nil;
                id<CydiaDelegate, NSObject> delegate([self delegate]);
                if ([delegate respondsToSelector:@selector(reloadDataWithInvocation:)]) [delegate reloadDataWithInvocation:nil];
                if (!acquired || !result.succeeded()) [self showFailure:result]; else [self showMessage:KeyText(@"KEY_IMPORT_DONE")];
                [self updateControls];
            });
        }
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return self.reviewed ? 3 : 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 3 : section == 1 ? MAX(self.sources.count, 1) : _review.fingerprints.size() + 1;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return KeyText(section == 0 ? @"KEY_IMPORT" : section == 1 ? @"KEY_IMPORT_SELECT_SOURCE" : @"KEY_IMPORT_FINGERPRINTS");
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section { return section == 0 ? KeyText(@"KEY_IMPORT_PUBLIC_ONLY") : nil; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"key"]);
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"key"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; cell.detailTextLabel.text = nil;
    cell.textLabel.enabled = YES; cell.accessoryView = nil;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessibilityTraits = UIAccessibilityTraitStaticText;
    if (path.section == 0) {
        if (path.row == 0) {
            cell.textLabel.text = self.busy ? UCLocalize("LOADING") : self.fileName ?
                [NSString stringWithFormat:KeyText(@"KEY_IMPORT_SELECTED"), self.fileName] : KeyText(@"KEY_IMPORT_NO_FILE");
            if (self.busy) {
                UIActivityIndicatorView *spinner([[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray]);
                spinner.color = cell.textLabel.textColor; [spinner startAnimating]; cell.accessoryView = spinner;
            } else cell.accessoryView = nil;
        }
        else { cell.textLabel.text = KeyText(path.row == 1 ? @"KEY_IMPORT_CHOOSE_FILE" : @"KEY_IMPORT_PACKAGE"); cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault; cell.accessibilityTraits = UIAccessibilityTraitButton; }
        cell.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.settings.key-import.input.%ld", (long)path.row];
    } else if (path.section == 1) {
        cell.accessoryView = nil;
        if (self.sources.count == 0) { cell.textLabel.text = KeyText(@"KEY_IMPORT_NO_SOURCES"); return cell; }
        CydiaSourceDefinition *source(self.sources[path.row]); cell.textLabel.text = KeySourceSummary(source);
        const BOOL editable([self.editableSources containsIndex:path.row]);
        cell.textLabel.enabled = editable;
        if (!editable) cell.detailTextLabel.text = [[NSBundle mainBundle] localizedStringForKey:
            [source snapshot].readOnly ? @"SOURCE_READ_ONLY_ALIAS" : @"SOURCE_PROTECTED_OR_REVIEW" value:nil table:@"Sources"];
        cell.accessoryType = source == self.selectedSource ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = editable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.accessibilityTraits = UIAccessibilityTraitButton | (editable ? 0 : UIAccessibilityTraitNotEnabled) | (source == self.selectedSource ? UIAccessibilityTraitSelected : 0);
        cell.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.settings.key-import.source.%ld", (long)path.row];
    } else {
        if ((std::size_t)path.row < _review.fingerprints.size()) cell.textLabel.text = KeyString(_review.fingerprints[path.row]);
        else { cell.textLabel.text = KeyString(_review.destination); cell.detailTextLabel.text = [NSString stringWithFormat:KeyText(@"KEY_IMPORT_BINDING"), self.selectedSource.original, KeyString(_review.source.mutation.contents)]; }
        cell.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.settings.key-import.review.%ld", (long)path.row];
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES]; if (![self available]) return;
    if (path.section == 0 && path.row == 1) [self chooseFile];
    else if (path.section == 0 && path.row == 2) [self choosePackage];
    else if (path.section == 1 && self.sources.count != 0 &&
        CydiaSourceDefinitionCanEdit(self.sources[path.row], CydiaSources::Access::AdvancedSettings)) {
        self.selectedSource = self.sources[path.row]; [self clearReview];
    }
}
- (void)showFailure:(const Client::Result &)result {
    NSString *message(KeyText(@"KEY_IMPORT_FAILED"));
    if (result.error.find("key_verifier_unavailable") != std::string::npos) message = KeyText(@"KEY_IMPORT_VERIFIER");
    else if (result.error.find("key_source_policy_review_required") != std::string::npos) message = KeyText(@"KEY_IMPORT_POLICY_REVIEW");
    else if (result.error.find("key_source_review_required") != std::string::npos) message = KeyText(@"SOURCE_REVIEW_REQUIRED");
    else if (result.error.find("key_source_commit_failed") != std::string::npos) message = KeyText(@"KEY_IMPORT_PARTIAL");
    else if (result.error.find("stale_key_source") != std::string::npos || result.error.find("stale_key_review") != std::string::npos)
        message = KeyText(@"KEY_IMPORT_SOURCE_CHANGED");
    UIAlertController *alert([UIAlertController alertControllerWithTitle:KeyText(@"KEY_IMPORT") message:message preferredStyle:UIAlertControllerStyleAlert]);
    if (!result.error.empty()) {
        NSString *details(KeyString(result.error));
        NSString *title([[NSBundle mainBundle] localizedStringForKey:@"ACCESS_CHECK_DETAILS" value:nil table:@"RuntimeAccess"]);
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
            UIViewController *controller([[UIViewController alloc] init]); controller.navigationItem.title = title;
            UITextView *view([[UITextView alloc] init]); view.editable = NO;
            view.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; view.adjustsFontForContentSizeCategory = YES;
            view.text = details; view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:self.traitCollection];
            view.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
            controller.view = view; [self.navigationController pushViewController:controller animated:YES];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:KeyText(@"KEY_IMPORT") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
