/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/AdvancedSettingsController.h"
#import "Cydia/Database.h"
#import "Cydia/SourceControllers.h"
#import "Cydia/RuntimeAccessController.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/PrivilegedClient.h"
#include "Cydia/SourceDocumentCommit.hpp"
#include <algorithm>

namespace {
NSString *Text(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"];
}
NSString *String(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}
std::string PolicyPath() {
    return CydiaRuntime::PackageDatabasePaths::Current().CydiaStateDirectory() + "/source-protection";
}
NSString *DisplayURI(const std::string &value) {
    NSURLComponents *url([NSURLComponents componentsWithString:String(value)]);
    if (url == nil) return String(value);
    url.user = nil; url.password = nil;
    return url.string ?: @"";
}
UITableViewCell *Cell(UITableView *table) {
    UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"advanced"]);
    if (cell == nil) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"advanced"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:table.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:table.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:table.traitCollection];
    cell.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:table.traitCollection];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    return cell;
}
void Message(UIViewController *controller, NSString *message) {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("SETTINGS") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
}

@interface CydiaBootstrapRepositoriesController : CyteViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithDatabase:(Database *)database;
@end

@implementation CydiaBootstrapRepositoriesController {
    Database *database_;
    UITableView *table_;
    CydiaSources::StoreSnapshot snapshot_;
    CydiaSources::PolicySnapshot policy_;
    std::vector<CydiaSources::Definition> definitions_;
    std::vector<CydiaSources::ProtectionSelector> orphans_;
    std::vector<bool> selected_, retained_;
}
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) database_ = database;
    return self;
}
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self;
    table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 72;
    table_.accessibilityIdentifier = @"cydia.settings.bootstrap-repositories";
    self.view = table_;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = Text(@"BOOTSTRAP_REPOSITORIES");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("DONE") style:UIBarButtonItemStyleDone target:self action:@selector(reviewSave)];
    [self reloadSources];
}
- (void)reloadSources {
    CydiaSources::EffectiveLocations locations{CydiaAPT::SourceListPath(), CydiaAPT::SourcePartsDirectory()};
    snapshot_ = CydiaSources::ReadEffectiveDocuments(locations);
    policy_ = CydiaSources::ReadProtectionPolicy(PolicyPath());
    definitions_.clear(); selected_.clear(); orphans_.clear(); retained_.clear();
    for (const auto &stored : snapshot_.documents)
        for (const auto &definition : stored.document.definitions) definitions_.push_back(definition);
    selected_.resize(definitions_.size(), false);
    for (const auto &selector : policy_.selectors) {
        bool found(false);
        for (std::size_t index = 0; index != definitions_.size(); ++index)
            if (selector.originPath == definitions_[index].path && selector.semanticKey == definitions_[index].semanticKey) {
                selected_[index] = true; found = true;
            }
        if (!found) { orphans_.push_back(selector); retained_.push_back(true); }
    }
    self.navigationItem.rightBarButtonItem.enabled = snapshot_.ready() && CydiaAPT::MutationEnvironmentValid();
    [table_ reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return orphans_.empty() ? 1 : 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? definitions_.size() : orphans_.size();
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? UCLocalize("SOURCES") : Text(@"SOURCE_REVIEW_REQUIRED");
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section != 0) return Text(@"BOOTSTRAP_MISSING_REFERENCE");
    if (!snapshot_.ready()) return Text(@"SOURCE_REVIEW_REQUIRED");
    if (!policy_.valid) return [Text(@"SOURCE_REVIEW_REQUIRED") stringByAppendingFormat:@"\n%@", Text(@"BOOTSTRAP_REPOSITORIES_HELP")];
    return Text(@"BOOTSTRAP_REPOSITORIES_HELP");
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell(Cell(table));
    bool selected;
    if (path.section == 0) {
        const auto &definition(definitions_[path.row]);
        NSMutableArray *uris([NSMutableArray array]);
        for (const std::string &uri : definition.uris) [uris addObject:DisplayURI(uri)];
        cell.textLabel.text = [uris componentsJoinedByString:@"\n"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", String(definition.path), String(definition.original)];
        selected = selected_[path.row];
    } else {
        const auto &selector(orphans_[path.row]);
        NSMutableArray *uris([NSMutableArray array]);
        for (const std::string &uri : selector.uris) [uris addObject:DisplayURI(uri)];
        cell.textLabel.text = [uris componentsJoinedByString:@"\n"];
        cell.detailTextLabel.text = String(selector.originPath);
        selected = retained_[path.row];
    }
    cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessibilityTraits |= selected ? UIAccessibilityTraitSelected : 0;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0) selected_[path.row] = !selected_[path.row];
    else retained_[path.row] = !retained_[path.row];
    [table reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)reviewSave {
    if (!snapshot_.ready()) { Message(self, Text(@"SOURCE_REVIEW_REQUIRED")); return; }
    CydiaSources::CommitRequest request;
    request.kind = CydiaSources::CommitKind::SetProtectionPolicy;
    request.access = CydiaSources::Access::AdvancedSettings;
    request.expectedPolicy = policy_.bytes;
    request.initializePolicy = !policy_.valid;
    NSMutableArray *review([NSMutableArray array]);
    for (std::size_t index = 0; index != definitions_.size(); ++index)
        if (selected_[index]) {
            // Retain the user's existing set identity when its exact definition survives.
            std::string identifier("bootstrap");
            for (const auto &selector : policy_.selectors)
                if (selector.originPath == definitions_[index].path && selector.semanticKey == definitions_[index].semanticKey)
                    identifier = selector.setIdentifier;
            request.selectors.push_back(CydiaSources::SelectorForDefinition(identifier, definitions_[index]));
            for (const auto &uri : definitions_[index].uris) [review addObject:DisplayURI(uri)];
        }
    for (std::size_t index = 0; index != orphans_.size(); ++index)
        if (retained_[index]) {
            Message(self, Text(@"BOOTSTRAP_MISSING_REFERENCE")); return;
        }
    NSString *detail([review count] == 0 ? Text(@"BOOTSTRAP_NONE_SELECTED") : [review componentsJoinedByString:@"\n"]);
    UIAlertController *alert([UIAlertController alertControllerWithTitle:Text(@"BOOTSTRAP_REPOSITORIES")
        message:[NSString stringWithFormat:@"%@\n\n%@", Text(@"BOOTSTRAP_REPOSITORIES_HELP"), detail] preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    const std::string payload(CydiaSources::SerializeCommitRequest(request));
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CONFIRM") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self savePayload:payload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)savePayload:(const std::string &)payload {
    table_.userInteractionEnabled = NO; self.navigationItem.rightBarButtonItem.enabled = NO;
    const std::string copy(payload);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (![database_ beginSettingsChange]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                table_.userInteractionEnabled = YES; [self reloadSources]; Message(self, Text(@"SETTINGS_WAIT_FOR_OPERATION"));
            });
            return;
        }
        CydiaRuntime::PrivilegedClient::Result result;
        @try { result = CydiaRuntime::PrivilegedClient::RunNativeCommand("--cydia-source-advanced", copy); }
        @finally { [database_ endSettingsChange]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            table_.userInteractionEnabled = YES; [self reloadSources];
            Message(self, Text(result.succeeded() ? @"SETTINGS_SAVED" : @"SOURCE_SAVE_FAILED"));
        });
    });
}
@end

@interface CydiaAdvancedSettingsController () <UITableViewDataSource, UITableViewDelegate>
@end
@implementation CydiaAdvancedSettingsController {
    Database *database_;
    UITableView *table_;
    NSDictionary *overrides_;
}
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) database_ = database;
    return self;
}
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self;
    table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 72;
    table_.accessibilityIdentifier = @"cydia.settings.advanced";
    self.view = table_;
}
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.title = Text(@"ADVANCED_SETTINGS"); }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    std::map<std::string, std::string> overrides;
    CydiaRuntime::Privileged::Evidence evidence; CydiaRuntime::Privileged::Error error;
    const auto &paths(CydiaRuntime::PackageDatabasePaths::Current());
    NSMutableDictionary *values([NSMutableDictionary dictionary]);
    if (CydiaRuntime::Privileged::ReadExecutableOverrides(paths, &overrides, &evidence, &error))
        for (const auto &value : overrides) values[String(value.first)] = String(value.second);
    overrides_ = values;
    [table_ reloadData];
}
- (NSArray *)tools { return @[@"dpkg", @"dpkg-query", @"dpkg-deb", @"uicache", @"apt-key", @"gpgv", @"gpg"]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 ? 2 : section == 1 ? [[self tools] count] : 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? Text(@"BOOTSTRAP_REPOSITORIES") : section == 1 ? Text(@"EXTERNAL_EXECUTABLES") : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 2) return nil;
    return Text(section == 0 ? @"BOOTSTRAP_REPOSITORIES_HELP" : @"EXTERNAL_EXECUTABLES_HELP");
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell(Cell(table));
    if (path.section == 0) {
        cell.textLabel.text = path.row == 0 ? Text(@"BOOTSTRAP_REPOSITORIES") : UCLocalize("SOURCES");
        cell.detailTextLabel.text = nil;
        cell.accessibilityIdentifier = path.row == 0 ? @"cydia.settings.bootstrap" : @"cydia.settings.advanced-sources";
    } else if (path.section == 1) {
        NSString *tool([self tools][path.row]);
        cell.textLabel.text = tool; cell.detailTextLabel.text = overrides_[tool];
        cell.accessibilityIdentifier = [@"cydia.settings.executable." stringByAppendingString:tool];
    } else {
        cell.textLabel.text = [[NSBundle mainBundle] localizedStringForKey:@"ACCESS_CHECK_TITLE" value:nil table:@"RuntimeAccess"];
        cell.detailTextLabel.text = nil;
        cell.accessibilityIdentifier = @"cydia.settings.runtime-access";
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 2) {
        CydiaRuntimeAccessController *controller([[CydiaRuntimeAccessController alloc] initWithDatabase:database_]);
        controller.delegate = self.delegate;
        [self.navigationController pushViewController:controller animated:YES]; return;
    }
    if (path.section == 0) {
        CyteViewController *controller(path.row == 0 ?
            [[CydiaBootstrapRepositoriesController alloc] initWithDatabase:database_] :
            [[SourcesController alloc] initWithDatabase:database_ advancedAccess:YES]);
        controller.delegate = self.delegate;
        [self.navigationController pushViewController:controller animated:YES]; return;
    }
    NSString *tool([self tools][path.row]);
    UIAlertController *alert([UIAlertController alertControllerWithTitle:tool message:Text(@"EXTERNAL_EXECUTABLES_HELP") preferredStyle:UIAlertControllerStyleAlert]);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.text = overrides_[tool]; field.placeholder = @"/";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CONFIRM") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        const std::string purpose([tool UTF8String]);
        const std::string path([alert.textFields.firstObject.text UTF8String] ?: "");
        [self saveExecutable:purpose path:path];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)saveExecutable:(const std::string &)purpose path:(const std::string &)path {
    table_.userInteractionEnabled = NO;
    const std::string payload(CydiaRuntime::Privileged::SerializeFields({purpose, path}));
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (![database_ beginSettingsChange]) {
            dispatch_async(dispatch_get_main_queue(), ^{ table_.userInteractionEnabled = YES; Message(self, Text(@"SETTINGS_WAIT_FOR_OPERATION")); }); return;
        }
        CydiaRuntime::PrivilegedClient::Result result;
        @try { result = CydiaRuntime::PrivilegedClient::RunNativeCommand("--cydia-set-executable", payload); }
        @finally { [database_ endSettingsChange]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            table_.userInteractionEnabled = YES;
            Message(self, Text(result.succeeded() ? @"SETTING_RESTART_REQUIRED" : @"SETTINGS_SAVE_FAILED"));
            [self viewWillAppear:NO];
        });
    });
}
@end
