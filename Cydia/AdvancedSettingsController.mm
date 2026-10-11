/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/AdvancedSettingsController.h"
#import "Cydia/Database.h"
#import "Cydia/SourceControllers.h"
#import "Cydia/RuntimeAccessController.h"
#import "Cydia/BootstrapAccessController.h"
#import "Cydia/CapabilityController.h"
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
UITableView *GroupedTable(id<UITableViewDataSource, UITableViewDelegate> controller) {
    UITableViewStyle style(UITableViewStyleGrouped);
    if (@available(iOS 13.0, *)) style = UITableViewStyleInsetGrouped;
    UITableView *table([[UITableView alloc] initWithFrame:CGRectZero style:style]);
    table.dataSource = controller; table.delegate = controller;
    table.rowHeight = UITableViewAutomaticDimension; table.estimatedRowHeight = 64;
    table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:table.traitCollection];
    table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:table.traitCollection];
    return table;
}
void RefreshGroupedAppearance(UITableView *table, UITraitCollection *traits, UITraitCollection *previous) {
    if (!CydiaColorAppearanceDidChange(traits, previous) &&
        [traits.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) return;
    table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:traits];
    table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:traits];
    [table reloadData];
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
    std::vector<bool> initialSelected_, initialRetained_;
    BOOL saving_;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; RefreshGroupedAppearance(table_, self.traitCollection, previous);
}
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) database_ = database;
    return self;
}
- (void)loadView {
    table_ = GroupedTable(self);
    table_.accessibilityIdentifier = @"cydia.settings.bootstrap-repositories";
    self.view = table_;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = Text(@"BOOTSTRAP_REPOSITORIES");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:Text(@"SETTINGS_SAVE") style:UIBarButtonItemStyleDone target:self action:@selector(reviewSave)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("CANCEL") style:UIBarButtonItemStylePlain target:self action:@selector(cancelEditing)];
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
    initialSelected_ = selected_; initialRetained_ = retained_;
    [self updateSave];
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
        NSMutableArray *suites([NSMutableArray array]);
        for (const auto &suite : definition.suites) [suites addObject:String(suite)];
        cell.detailTextLabel.text = [suites componentsJoinedByString:@" · "];
        selected = selected_[path.row];
    } else {
        const auto &selector(orphans_[path.row]);
        NSMutableArray *uris([NSMutableArray array]);
        for (const std::string &uri : selector.uris) [uris addObject:DisplayURI(uri)];
        cell.textLabel.text = [uris componentsJoinedByString:@"\n"];
        cell.detailTextLabel.text = Text(@"SOURCE_REVIEW_REQUIRED");
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
    [self updateSave];
    [table reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}
- (BOOL)hasChanges { return selected_ != initialSelected_ || retained_ != initialRetained_; }
- (void)updateSave {
    self.navigationItem.rightBarButtonItem.enabled = !saving_ && snapshot_.ready() &&
        CydiaAPT::MutationEnvironmentValid() && ([self hasChanges] || !policy_.valid);
    self.navigationItem.leftBarButtonItem.enabled = !saving_;
}
- (void)cancelEditing {
    if (saving_) return;
    if (![self hasChanges]) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    UIAlertController *alert([UIAlertController alertControllerWithTitle:Text(@"DISCARD_SETTINGS_TITLE")
        message:Text(@"DISCARD_SETTINGS_MESSAGE") preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:Text(@"DISCARD_SETTINGS_ACTION") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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
    saving_ = YES; table_.userInteractionEnabled = NO; [self updateSave];
    const std::string copy(payload);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (![database_ beginSettingsChange]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                saving_ = NO; table_.userInteractionEnabled = YES; [self updateSave]; Message(self, Text(@"SETTINGS_WAIT_FOR_OPERATION"));
            });
            return;
        }
        CydiaRuntime::PrivilegedClient::Result result;
        @try { result = CydiaRuntime::PrivilegedClient::RunNativeCommand("--cydia-source-advanced", copy); }
        @finally { [database_ endSettingsChange]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            saving_ = NO; table_.userInteractionEnabled = YES;
            if (result.succeeded()) [self dismissViewControllerAnimated:YES completion:nil];
            else { [self updateSave]; Message(self, Text(@"SOURCE_SAVE_FAILED")); }
        });
    });
}
@end

@interface CydiaExecutablePathController : CyteViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithDatabase:(Database *)database tool:(NSString *)tool path:(NSString *)path;
@end
@implementation CydiaExecutablePathController {
    Database *database_;
    NSString *tool_, *savedPath_;
    UITableView *table_;
    UITextField *field_;
    UISwitch *useDefault_;
    BOOL saving_;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; RefreshGroupedAppearance(table_, self.traitCollection, previous);
}
- (instancetype)initWithDatabase:(Database *)database tool:(NSString *)tool path:(NSString *)path {
    if ((self = [super init]) != nil) { database_ = database; tool_ = [tool copy]; savedPath_ = [path copy] ?: @""; }
    return self;
}
- (void)loadView {
    table_ = GroupedTable(self); self.view = table_;
    useDefault_ = [[UISwitch alloc] init]; useDefault_.on = savedPath_.length == 0;
    [useDefault_ addTarget:self action:@selector(defaultChanged:) forControlEvents:UIControlEventValueChanged];
    field_ = [[UITextField alloc] init]; field_.text = savedPath_; field_.placeholder = @"/";
    field_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; field_.adjustsFontForContentSizeCategory = YES;
    field_.autocorrectionType = UITextAutocorrectionTypeNo; field_.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field_.smartQuotesType = UITextSmartQuotesTypeNo; field_.smartDashesType = UITextSmartDashesTypeNo;
    field_.clearButtonMode = UITextFieldViewModeWhileEditing;
    field_.accessibilityLabel = Text(@"TOOL_CUSTOM_PATH"); field_.accessibilityIdentifier = @"cydia.settings.executable.path";
    [field_ addTarget:self action:@selector(updateSave) forControlEvents:UIControlEventEditingChanged];
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.navigationItem.title = tool_;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:Text(@"SETTINGS_SAVE")
        style:UIBarButtonItemStyleDone target:self action:@selector(savePath)];
    [self updateSave];
}
- (NSString *)selectedPath {
    return useDefault_.on ? @"" : [field_.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
- (void)updateSave {
    NSString *path([self selectedPath]);
    self.navigationItem.rightBarButtonItem.enabled = !saving_ && (useDefault_.on || [path hasPrefix:@"/"]) && ![path isEqual:savedPath_];
}
- (void)defaultChanged:(UISwitch *)sender { [field_ resignFirstResponder]; [table_ reloadData]; [self updateSave]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 || !useDefault_.on ? 1 : 0; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { return section == 1 && !useDefault_.on ? Text(@"TOOL_CUSTOM_PATH") : nil; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section { return section == 1 ? Text(@"TOOL_PATH_HELP") : nil; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]);
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (path.section == 0) {
        cell.textLabel.text = Text(@"TOOL_USE_DEFAULT"); cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
        cell.accessoryView = useDefault_;
    } else {
        field_.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
        field_.translatesAutoresizingMaskIntoConstraints = NO; [cell.contentView addSubview:field_];
        [NSLayoutConstraint activateConstraints:@[
            [field_.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [field_.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [field_.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [field_.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
            [field_.heightAnchor constraintGreaterThanOrEqualToConstant:34]]];
    }
    return cell;
}
- (void)savePath {
    if (!self.navigationItem.rightBarButtonItem.enabled) return;
    [field_ resignFirstResponder]; saving_ = YES; table_.userInteractionEnabled = NO; [self updateSave];
    const std::string payload(CydiaRuntime::Privileged::SerializeFields({[tool_ UTF8String], [[self selectedPath] UTF8String]}));
    __weak UINavigationController *reviewedNavigation(self.navigationController);
    NSArray *stack(self.navigationController.viewControllers);
    __weak UIViewController *reviewedParent(stack.count >= 2 ? stack[stack.count - 2] : nil);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CydiaRuntime::PrivilegedClient::Result result;
        const BOOL acquired([database_ beginSettingsChange]);
        if (acquired) {
            @try { result = CydiaRuntime::PrivilegedClient::RunPrivateSettingsCommand("--cydia-set-executable", payload); }
            @finally { [database_ endSettingsChange]; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            saving_ = NO; table_.userInteractionEnabled = YES; [self updateSave];
            UINavigationController *navigation(reviewedNavigation); UIViewController *parent(reviewedParent);
            if (navigation.topViewController != self || self.viewIfLoaded.window == nil || self.presentedViewController != nil) return;
            if (!acquired || !result.succeeded()) { Message(self, Text(acquired ? @"SETTINGS_SAVE_FAILED" : @"SETTINGS_WAIT_FOR_OPERATION")); return; }
            NSArray *current(navigation.viewControllers);
            if (current.count < 2 || current[current.count - 2] != parent) return;
            [navigation popViewControllerAnimated:YES];
            void (^notify)(void) = ^{
                if (navigation.topViewController == parent && parent.viewIfLoaded.window != nil && parent.presentedViewController == nil)
                    Message(parent, Text(@"SETTING_RESTART_REQUIRED"));
            };
            if (navigation.transitionCoordinator != nil)
                [navigation.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) { notify(); }];
            else dispatch_async(dispatch_get_main_queue(), notify);
        });
    });
}
@end

@interface CydiaExternalToolsController : CyteViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithDatabase:(Database *)database;
@end
@implementation CydiaExternalToolsController {
    Database *database_;
    UITableView *table_;
    NSDictionary *overrides_;
    BOOL available_;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; RefreshGroupedAppearance(table_, self.traitCollection, previous);
}
- (instancetype)initWithDatabase:(Database *)database { if ((self = [super init]) != nil) database_ = database; return self; }
- (void)loadView { table_ = GroupedTable(self); table_.accessibilityIdentifier = @"cydia.settings.external-tools"; self.view = table_; }
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.title = Text(@"EXTERNAL_EXECUTABLES"); }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    std::map<std::string, std::string> overrides;
    CydiaRuntime::Privileged::Evidence evidence; CydiaRuntime::Privileged::Error error;
    const auto &paths(CydiaRuntime::PackageDatabasePaths::Current());
    NSMutableDictionary *values([NSMutableDictionary dictionary]);
    available_ = CydiaRuntime::Privileged::ReadExecutableOverrideSettings(paths, &overrides, &evidence, &error);
    if (available_) for (const auto &value : overrides) values[String(value.first)] = String(value.second);
    overrides_ = values; [table_ reloadData];
}
- (NSArray *)tools { return @[@"dpkg", @"dpkg-query", @"dpkg-deb", @"uicache", @"apt-key", @"gpgv", @"gpg"]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 1; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return [[self tools] count]; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section { return Text(available_ ? @"TOOL_PATH_HELP" : @"TOOL_OVERRIDES_UNAVAILABLE"); }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell(Cell(table)); NSString *tool([self tools][path.row]);
    cell.textLabel.text = tool;
    cell.detailTextLabel.text = available_ ? (overrides_[tool] ?: Text(@"BOOTSTRAP_DEFAULT")) : Text(@"TOOL_OVERRIDES_UNAVAILABLE");
    cell.accessoryType = available_ ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = available_ ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessibilityIdentifier = [@"cydia.settings.executable." stringByAppendingString:tool];
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES]; if (!available_) return;
    NSString *tool([self tools][path.row]);
    CydiaExecutablePathController *controller([[CydiaExecutablePathController alloc] initWithDatabase:database_ tool:tool path:overrides_[tool]]);
    controller.delegate = self.delegate; [self.navigationController pushViewController:controller animated:YES];
}
@end

@interface CydiaAdvancedSettingsController () <UITableViewDataSource, UITableViewDelegate>
@end
@implementation CydiaAdvancedSettingsController {
    Database *database_;
    UITableView *table_;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; RefreshGroupedAppearance(table_, self.traitCollection, previous);
}
- (instancetype)initWithDatabase:(Database *)database { if ((self = [super init]) != nil) database_ = database; return self; }
- (void)loadView { table_ = GroupedTable(self); table_.accessibilityIdentifier = @"cydia.settings.advanced"; self.view = table_; }
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.title = Text(@"ADVANCED_SETTINGS"); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : section == 1 ? 2 : 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return Text(@[@"BOOTSTRAP_CONFIGURATION", @"COMPATIBILITY", @"DIAGNOSTICS"][section]);
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section { return nil; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell(Cell(table));
    if (path.section == 0) {
        cell.textLabel.text = Text(@[@"BOOTSTRAP_REPOSITORIES", @"PROTECTED_REPOSITORY_SETTINGS", @"BOOTSTRAP_DATABASE_ACCESS"][path.row]);
        cell.accessibilityIdentifier = @[@"cydia.settings.bootstrap", @"cydia.settings.advanced-sources", @"cydia.settings.bootstrap-access"][path.row];
    } else if (path.section == 1) {
        cell.textLabel.text = Text(path.row == 0 ? @"CAPABILITIES" : @"EXTERNAL_EXECUTABLES");
        cell.accessibilityIdentifier = path.row == 0 ? @"cydia.settings.capabilities" : @"cydia.settings.external-tools";
    } else {
        cell.textLabel.text = [[NSBundle mainBundle] localizedStringForKey:@"ACCESS_CHECK_TITLE" value:nil table:@"RuntimeAccess"];
        cell.accessibilityIdentifier = @"cydia.settings.runtime-access";
    }
    cell.detailTextLabel.text = nil; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES]; CyteViewController *controller;
    if (path.section == 0 && path.row == 0) {
        controller = [[CydiaBootstrapRepositoriesController alloc] initWithDatabase:database_]; controller.delegate = self.delegate;
        UINavigationController *navigation([[UINavigationController alloc] initWithRootViewController:controller]);
        navigation.modalPresentationStyle = UIModalPresentationFormSheet;
        if (@available(iOS 13.0, *)) navigation.modalInPresentation = YES;
        [self presentViewController:navigation animated:YES completion:nil]; return;
    }
    if (path.section == 0) controller = path.row == 1 ?
        [[CydiaRepositorySettingsController alloc] initWithDatabase:database_ advancedAccess:YES] :
        [[CydiaBootstrapAccessController alloc] initWithDatabase:database_];
    else if (path.section == 1) controller = path.row == 0 ?
        [[CydiaCapabilityController alloc] initWithDatabase:database_] : [[CydiaExternalToolsController alloc] initWithDatabase:database_];
    else controller = [[CydiaRuntimeAccessController alloc] initWithDatabase:database_];
    controller.delegate = self.delegate; [self.navigationController pushViewController:controller animated:YES];
}
@end
