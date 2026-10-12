/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SourceAddController_Internal.h"
#import "Cydia/Database.h"
#import "Cydia/CydiaDelegate.h"
#import "Sources.h"
#import "CyteKit/Localize.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/KeyringImport.hpp"
#include "Cydia/PrivilegedClient.h"
#include <sstream>

namespace Src = CydiaSources;
static NSString *S(const std::string &text) { return [NSString stringWithUTF8String:text.c_str()] ?: @""; }
static std::string B(NSString *text) { return [text UTF8String] ?: ""; }
static std::vector<std::string> Words(NSString *text) {
    std::vector<std::string> words; std::istringstream input(B(text));
    for (std::string word; input >> word;) words.push_back(word); return words;
}
static NSString *Joined(const std::vector<std::string> &values) {
    NSMutableArray *parts([NSMutableArray array]); for (const auto &value : values) [parts addObject:S(value)];
    return [parts componentsJoinedByString:@" "];
}
static Src::SourceDraft Imported(NSString *definition, Src::Format format) {
    return Src::ImportSourceDraft(B(definition), format);
}
static NSDictionary *Row(NSString *key, NSString *title, NSString *value = nil) {
    return @{@"key":key, @"title":title, @"value":value ?: @""};
}
static NSString *WarningMessage(CydiaSourceAddSession *session) {
    NSString *notice(CydiaSourceText(@"SOURCE_ADD_UNVERIFIED_WARNING"));
    return session.message.length ? [notice stringByAppendingFormat:@"\n\n%@", session.message] : notice;
}

@implementation CydiaSourceAddController
+ (instancetype)controllerWithDraft:(const Src::SourceDraft &)draft database:(Database *)database
                         presenter:(CyteViewController *)presenter row:(CydiaSourceDefinition *)row access:(Src::Access)access {
    CydiaSourceAddController *controller([[self alloc] init]);
    controller.session = [[CydiaSourceAddSession alloc] initWithDatabase:database draft:draft row:row access:access];
    controller.presenter = presenter; controller.delegate = presenter.delegate;
    return controller;
}
+ (void)showURLPromptWithDatabase:(Database *)database presenter:(CyteViewController *)presenter URL:(NSString *)URL {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("ENTER_APT_URL") message:nil preferredStyle:UIAlertControllerStyleAlert]);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = URL ?: @"https://"; field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.accessibilityIdentifier = @"cydia.sources.add-url";
    }];
    __weak UIAlertController *weakAlert(alert);
    void (^start)(BOOL) = ^(BOOL advanced) {
        NSString *URL([(weakAlert.textFields.firstObject.text ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        Src::SourceDraft draft; draft.uri = B(URL);
        CydiaSourceAddController *controller([self controllerWithDraft:draft database:database presenter:presenter row:nil access:Src::Access::Ordinary]);
        controller.originalURL = URL;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (advanced) [controller showAdvanced]; else [controller checkQuickAdd];
        });
    };
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CydiaSourceText(@"SOURCE_ADD_ADVANCED") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { start(YES); }]];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("ADD_SOURCE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { start(NO); }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}
+ (void)showDefinition:(NSString *)definition database:(Database *)database presenter:(CyteViewController *)presenter access:(Src::Access)access {
    auto format(Src::Format::OneLine);
    if (!Src::ParseDocument("draft.list", format, B(definition)).valid()) format = Src::Format::Deb822;
    CydiaSourceAddController *controller([self controllerWithDraft:Imported(definition, format) database:database presenter:presenter row:nil access:access]);
    [controller showAdvanced];
}
+ (void)showAdvancedWithDatabase:(Database *)database presenter:(CyteViewController *)presenter URL:(NSString *)URL access:(Src::Access)access {
    Src::SourceDraft draft; draft.uri = B(URL);
    [[self controllerWithDraft:draft database:database presenter:presenter row:nil access:access] showAdvanced];
}
+ (void)editDefinition:(CydiaSourceDefinition *)row database:(Database *)database presenter:(CyteViewController *)presenter access:(Src::Access)access {
    auto draft(Imported(row.original, [row snapshot].document.format));
    CydiaSourceAddController *controller([self controllerWithDraft:draft database:database presenter:presenter row:row access:access]);
    [controller showAdvanced];
}
- (void)showAdvanced {
    if (self.cancelled || self.presenter == nil) return;
    UINavigationController *navigation([[UINavigationController alloc] initWithRootViewController:self]);
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    if (@available(iOS 13.0, *)) navigation.modalInPresentation = YES;
    [self.presenter presentViewController:navigation animated:YES completion:nil];
}
- (void)loadView {
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.table.dataSource = self; self.table.delegate = self; self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 64; self.table.accessibilityIdentifier = @"cydia.source-draft.form";
    self.view = self.table; CydiaStyleSourceForm(self.table, self.traitCollection);
}
- (void)viewDidLoad { [super viewDidLoad]; [self refreshForm]; }
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; CydiaStyleSourceForm(self.table, self.traitCollection); [self.table reloadData];
}
- (void)refreshForm {
    if (!self.isViewLoaded) return;
    BOOL busy(self.session.busy || self.finding);
    self.title = CydiaSourceText(self.reviewPage ? @"SOURCE_ADD_REVIEW" : @"SOURCE_ADD_ADVANCED_TITLE");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("CANCEL") style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.leftBarButtonItem.enabled = !self.session.busy || !self.session.ready;
    NSString *action = self.reviewPage && self.session.ready ?
        (self.session.hasSelectedKey ? CydiaSourceText(@"SOURCE_ADD_TRUST_AND_SAVE") : self.session.disabled ? CydiaSourceText(@"SOURCE_ADD_SAVE_DISABLED") :
         self.session.existingSource ? CydiaSourceText(@"SOURCE_SAVE") : UCLocalize("ADD_SOURCE")) : CydiaSourceText(@"SOURCE_ADD_REVIEW");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:action style:UIBarButtonItemStyleDone target:self
        action:self.reviewPage && self.session.ready ? @selector(save) : @selector(check)];
    if (busy) {
        UIActivityIndicatorView *indicator([[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray]);
        indicator.accessibilityLabel = CydiaSourceText(@"SOURCE_ADD_CHECKING"); [indicator startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    }
    self.navigationItem.rightBarButtonItem.enabled = !busy; self.table.userInteractionEnabled = !busy;
    [self.table reloadData];
}
- (void)cancel {
    [self.session cancel]; [self cancelDiscovery]; self.cancelled = YES;
    CyteViewController *presenter(self.presenter); NSString *URL(self.originalURL); Database *database(self.session.database);
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (URL != nil) [CydiaSourceAddController showURLPromptWithDatabase:database presenter:presenter URL:URL];
    }];
}
- (void)changed { [self.session invalidateReview]; self.reviewPage = NO; [self refreshForm]; }
- (void)showMessage:(NSString *)message {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("SOURCES") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)pushText:(NSString *)title value:(NSString *)value help:(NSString *)help URL:(BOOL)URL
      multiline:(BOOL)multiline saved:(void (^)(NSString *))saved {
    CydiaSourceTextController *editor([[CydiaSourceTextController alloc] initWithTitle:title value:value explanation:help URL:URL multiline:multiline saved:saved]);
    editor.delegate = self.delegate; [self.navigationController pushViewController:editor animated:YES];
}
- (NSArray<NSArray<NSDictionary *> *> *)rows {
    const auto &draft([self.session draft]);
    NSString *policy([[NSBundle mainBundle] localizedStringForKey:
        CydiaAPT::GetRepositorySecurityMode() == CydiaAPT::RepositorySecurityMode::Allow ? @"SECURITY_ALLOW" :
        CydiaAPT::GetRepositorySecurityMode() == CydiaAPT::RepositorySecurityMode::Error ? @"SECURITY_ERROR" : @"SECURITY_WARNING"
        value:nil table:@"Settings"]);
    if (self.reviewPage) {
        NSMutableArray *result([NSMutableArray arrayWithObjects:Row(@"status", CydiaSourceText(self.session.ready ? @"SOURCE_ADD_READY" : @"SOURCE_ADD_CHECK_FAILED"),
            self.session.warning ? WarningMessage(self.session) : self.session.message),
            Row(@"definition", CydiaSourceText(@"SOURCE_DEFINITION"), self.session.reviewedDefinition),
            Row(@"policy", CydiaSourceText(@"SOURCE_ADD_SECURITY"), policy), nil]);
        if (!self.session.disabled) [result addObject:Row(@"signature", CydiaSourceText(@"SOURCE_ADD_SIGNATURE"),
            CydiaSourceText([self.session checkResult].authenticated ? @"SOURCE_ADD_VERIFIED" : @"SOURCE_ADD_UNVERIFIED"))];
        if (self.session.hasSelectedKey) [result addObject:Row(@"trust", CydiaSourceText(@"SOURCE_ADD_KEY"),
            [NSString stringWithFormat:@"%@\n%@", self.session.keyProvenance ?: @"", [self.session.fingerprints componentsJoinedByString:@"\n"]])];
        NSMutableArray *actions([NSMutableArray arrayWithObject:Row(@"edit", UCLocalize("EDIT"))]);
        if (!self.session.disabled && ![self.session checkResult].authenticated)
            [actions addObject:Row(@"findkey", CydiaSourceText(@"SOURCE_ADD_FIND_KEY"))];
        if (!self.session.ready) [actions addObject:Row(@"disabled", CydiaSourceText(@"SOURCE_ADD_SAVE_DISABLED"))];
        return @[result, @[Row(@"destination", CydiaSourceText(@"SOURCE_CHOOSE_FILE"), self.session.destinationPath)], actions];
    }
    if (draft.raw) return @[@[Row(@"raw", CydiaSourceText(@"SOURCE_ENTER_DEFINITION"), S(draft.rawContents)),
        Row(@"convert", CydiaSourceText(@"SOURCE_ADD_EDIT_FIELDS"))],
        @[Row(@"key", CydiaSourceText(@"SOURCE_ADD_KEY"), self.session.keyProvenance ?: CydiaSourceText(@"SOURCE_ADD_USE_APT")),
          Row(@"policy", CydiaSourceText(@"SOURCE_ADD_SECURITY"), policy)],
        @[Row(@"destination", CydiaSourceText(@"SOURCE_CHOOSE_FILE"), self.session.destinationPath ?: CydiaSourceText(@"SOURCE_NEW_FILE"))]];
    NSMutableArray *format([NSMutableArray arrayWithObjects:
        Row(@"format", CydiaSourceText(@"SOURCE_ADD_FORMAT"), CydiaSourceText(draft.exactPath ? @"SOURCE_ADD_FLAT" : @"SOURCE_ADD_SUITE_COMPONENTS")),
        Row(@"distribution", CydiaSourceText(draft.exactPath ? @"SOURCE_ADD_PATH" : @"SOURCE_SUITE"), S(draft.distribution)), nil]);
    if (!draft.exactPath) [format addObject:Row(@"components", CydiaSourceText(@"SOURCE_ADD_COMPONENTS"), Joined(draft.components))];
    return @[@[Row(@"uri", CydiaSourceText(@"SOURCE_URI"), S(draft.uri)), Row(@"discover", CydiaSourceText(@"SOURCE_ADD_FIND_OPTIONS"))], format,
        @[Row(@"architectures", CydiaSourceText(@"SOURCE_ADD_ARCHITECTURES"), draft.architectureMode == Src::ArchitectureMode::Inherit ? CydiaSourceText(@"SOURCE_ADD_USE_APT") : Joined(draft.architectures)),
          Row(@"key", CydiaSourceText(@"SOURCE_ADD_KEY"), self.session.keyProvenance ?: (draft.signedBy.empty() ? CydiaSourceText(@"SOURCE_ADD_USE_APT") : S(draft.signedBy))),
          Row(@"sourcecode", CydiaSourceText(@"SOURCE_ADD_SOURCE_CODE")), Row(@"policy", CydiaSourceText(@"SOURCE_ADD_SECURITY"), policy)],
        @[Row(@"raw", CydiaSourceText(@"SOURCE_ENTER_DEFINITION"))],
        @[Row(@"destination", CydiaSourceText(@"SOURCE_CHOOSE_FILE"), self.session.destinationPath ?: CydiaSourceText(@"SOURCE_NEW_FILE"))]];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return [self rows].count; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return [self rows][section].count; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 0) return CydiaSourceText(self.reviewPage ?
        (self.session.hasSelectedKey ? @"SOURCE_ADD_TRUST_NOTICE" : @"SOURCE_ADD_REVIEW_NOTICE") : @"SOURCE_ADD_ADVICE");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *row([self rows][path.section][path.row]); NSString *key(row[@"key"]);
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]);
    CydiaStyleSourceFormCell(cell, self.traitCollection); cell.textLabel.text = row[@"title"]; cell.detailTextLabel.text = row[@"value"];
    cell.accessibilityIdentifier = [@"cydia.source-draft." stringByAppendingString:key];
    if ([key isEqual:@"sourcecode"]) {
        UISwitch *toggle([[UISwitch alloc] init]); toggle.on = [self.session draft].includeSourcePackages;
        toggle.accessibilityLabel = row[@"title"]; [toggle addTarget:self action:@selector(sourceCodeChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([@[@"policy", @"status", @"definition", @"trust", @"signature"] containsObject:key]) cell.selectionStyle = UITableViewCellSelectionStyleNone;
    else { cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.accessibilityTraits |= UIAccessibilityTraitButton; }
    return cell;
}
- (void)sourceCodeChanged:(UISwitch *)toggle { [self.session draft].includeSourcePackages = toggle.on; [self changed]; }
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES]; NSDictionary *row([self rows][path.section][path.row]); NSString *key(row[@"key"]);
    if ([key isEqual:@"uri"] || [key isEqual:@"distribution"] || [key isEqual:@"components"]) {
        __weak CydiaSourceAddController *weakSelf(self);
        [self pushText:row[@"title"] value:row[@"value"] help:CydiaSourceText(@"SOURCE_ADD_ADVICE") URL:[key isEqual:@"uri"] multiline:NO saved:^(NSString *value) {
            CydiaSourceAddController *owner(weakSelf); if (!owner) return; auto &draft([owner.session draft]);
            if ([key isEqual:@"uri"]) draft.uri = B(value);
            else if ([key isEqual:@"distribution"]) draft.distribution = B(value);
            else draft.components = Words(value);
            [owner changed];
        }];
    } else if ([key isEqual:@"format"]) [self chooseFormat];
    else if ([key isEqual:@"architectures"]) [self chooseArchitectures];
    else if ([key isEqual:@"raw"]) [self editRaw];
    else if ([key isEqual:@"convert"]) {
        Src::SourceDraft converted;
        if (!Src::ConvertDraftToStructured([self.session draft], &converted)) [self showMessage:CydiaSourceText(@"SOURCE_ADD_KEEP_RAW")];
        else { [self.session draft] = converted; [self changed]; }
    } else if ([key isEqual:@"key"]) [self chooseKey];
    else if ([key isEqual:@"findkey"]) [self findSigningKey];
    else if ([key isEqual:@"discover"]) [self findOptions];
    else if ([key isEqual:@"destination"]) [self chooseDestination];
    else if ([key isEqual:@"edit"]) { self.reviewPage = NO; [self refreshForm]; }
    else if ([key isEqual:@"disabled"]) [self checkDisabled];
}
- (void)chooseFormat {
    const auto &draft([self.session draft]); __weak CydiaSourceAddController *weakSelf(self);
    NSArray *choices(@[@{@"title":CydiaSourceText(@"SOURCE_ADD_FLAT"), @"value":@"flat"},
        @{@"title":CydiaSourceText(@"SOURCE_ADD_SUITE_COMPONENTS"), @"value":@"suite"}]);
    CydiaSourceChoicesController *choice = [[CydiaSourceChoicesController alloc] initWithTitle:CydiaSourceText(@"SOURCE_ADD_FORMAT") choices:choices
        selected:[NSSet setWithObject:draft.exactPath ? @"flat" : @"suite"] multiple:NO explanation:CydiaSourceText(@"SOURCE_ADD_FORMAT_HELP") saved:^(NSSet<NSString *> *values) {
            CydiaSourceAddController *owner(weakSelf); if (!owner) return; auto &draft([owner.session draft]);
            BOOL flat([values containsObject:@"flat"]); if (flat == draft.exactPath) return;
            draft.exactPath = flat; draft.distribution = flat ? "./" : ""; draft.components.clear(); [owner changed];
        }];
    [self.navigationController pushViewController:choice animated:YES];
}
- (void)chooseArchitectures {
    // Preserve additive/removal filters without silently turning them into a
    // replacement list. The raw editor can express every APT filter.
    if ([self.session draft].architectureMode == Src::ArchitectureMode::Modify) { [self editRaw]; return; }
    NSMutableArray *choices([NSMutableArray arrayWithObject:@{@"title":CydiaSourceText(@"SOURCE_ADD_USE_APT"), @"detail":Joined(CydiaAPT::Architectures()), @"value":@"inherit", @"exclusive":@YES}]);
    for (const auto &architecture : CydiaAPT::RegisteredArchitectures())
        [choices addObject:@{@"title":S(architecture), @"value":S(architecture)}];
    const auto &draft([self.session draft]);
    NSMutableSet *selected([NSMutableSet set]);
    if (draft.architectureMode == Src::ArchitectureMode::Inherit) [selected addObject:@"inherit"];
    else for (const auto &architecture : draft.architectures) [selected addObject:S(architecture)];
    __weak CydiaSourceAddController *weakSelf(self);
    CydiaSourceChoicesController *choice([[CydiaSourceChoicesController alloc] initWithTitle:CydiaSourceText(@"SOURCE_ADD_ARCHITECTURES")
        choices:choices selected:selected multiple:YES explanation:CydiaSourceText(@"SOURCE_ADD_ARCHITECTURE_HELP") saved:^(NSSet<NSString *> *values) {
            CydiaSourceAddController *owner(weakSelf); if (!owner) return; auto &draft([owner.session draft]);
            draft.architectures.clear(); draft.architecturesAdd.clear(); draft.architecturesRemove.clear();
            for (NSString *value in [[values allObjects] sortedArrayUsingSelector:@selector(compare:)])
                if (![value isEqual:@"inherit"]) draft.architectures.push_back(B(value));
            draft.architectureMode = draft.architectures.empty() ? Src::ArchitectureMode::Inherit : Src::ArchitectureMode::Replace;
            [owner changed];
        }]);
    [self.navigationController pushViewController:choice animated:YES];
}
- (void)editRaw {
    const auto &draft([self.session draft]); const auto built(Src::BuildSourceDraft(draft, "draft"));
    NSString *text(draft.raw ? S(draft.rawContents) : S(built.document.bytes)); __weak CydiaSourceAddController *weakSelf(self);
    [self pushText:CydiaSourceText(@"SOURCE_ENTER_DEFINITION") value:text help:CydiaSourceText(@"SOURCE_ADD_RAW_HELP") URL:NO multiline:YES saved:^(NSString *value) {
        CydiaSourceAddController *owner(weakSelf); if (!owner) return;
        auto format(Src::Format::OneLine); const auto classic(Src::ParseDocument("draft.list", format, B(value)));
        if (!classic.valid()) format = Src::Format::Deb822;
        [owner.session draft] = Src::ImportSourceDraft(B(value), format); [owner changed];
    }];
}
- (void)chooseDestination {
    if (self.session.existingSource) { [self showMessage:CydiaSourceText(@"SOURCE_ADD_EXISTING_DESTINATION")]; return; }
    NSMutableArray *choices([NSMutableArray arrayWithObject:@{@"title":CydiaSourceText(@"SOURCE_NEW_FILE"), @"value":@""}]);
    const auto &draft([self.session draft]); const auto built(Src::BuildSourceDraft(draft, "draft"));
    for (const auto &file : CydiaReadSourceDocuments().documents) {
        if (file.readOnly || file.document.format != draft.format) continue;
        Src::Mutation append(Src::EditKind::AppendDefinition); append.contents = built.document.bytes;
        if (!Src::PlanStoredMutation(CydiaEffectiveSourceLocations(), file, append, CydiaReadSourceProtection().selectors).ready()) continue;
        [choices addObject:@{@"title":S(file.document.path), @"value":S(file.document.path)}];
    }
    __weak CydiaSourceAddController *weakSelf(self);
    CydiaSourceChoicesController *choice([[CydiaSourceChoicesController alloc] initWithTitle:CydiaSourceText(@"SOURCE_CHOOSE_FILE") choices:choices
        selected:[NSSet setWithObject:self.session.destinationPath ?: @""] multiple:NO explanation:CydiaSourceText(@"SOURCE_ADD_DESTINATION_HELP") saved:^(NSSet<NSString *> *values) {
            CydiaSourceAddController *owner(weakSelf); if (!owner) return;
            NSString *path(values.anyObject); owner.session.destinationPath = path.length ? path : nil; [owner changed];
        }]);
    [self.navigationController pushViewController:choice animated:YES];
}
- (void)check { [self check:NO]; }
- (void)checkDisabled { [self check:YES]; }
- (void)check:(BOOL)disabled {
    [self.session checkDisabled:disabled completion:^{
        if (self.cancelled) return;
        self.reviewPage = YES; [self refreshForm];
    }]; [self refreshForm];
}
- (void)save {
    [self.session commitWithCompletion:^(BOOL success) {
        if (success) [self finished]; else { [self showMessage:self.session.message]; [self refreshForm]; }
    }]; [self refreshForm];
}
- (void)finished {
    CyteViewController *presenter(self.presenter); id<CydiaDelegate, NSObject> delegate(self.delegate);
    void (^refresh)(void) = ^{
        if (self.session.existingSource != nil) {
            UINavigationController *navigation(presenter.navigationController);
            [navigation popViewControllerAnimated:NO];
            if ([navigation.topViewController respondsToSelector:@selector(reloadData)])
                [(CyteViewController *)navigation.topViewController reloadData];
        } else [presenter reloadData];
        if ([delegate respondsToSelector:@selector(syncData)]) [delegate syncData];
    };
    if (self.navigationController != nil) [self.navigationController dismissViewControllerAnimated:YES completion:refresh];
    else refresh();
}
- (void)checkQuickAdd {
    UIAlertController *progress([UIAlertController alertControllerWithTitle:CydiaSourceText(@"SOURCE_ADD_CHECKING") message:nil preferredStyle:UIAlertControllerStyleAlert]);
    [progress addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { self.cancelled = YES; [self.session cancel]; }]];
    [self.presenter presentViewController:progress animated:YES completion:^{
        [self.session checkDisabled:NO completion:^{
            [progress dismissViewControllerAnimated:YES completion:^{
                if (self.cancelled) return;
                if (self.session.ready && !self.session.warning) {
                    [self.session commitWithCompletion:^(BOOL success) {
                        if (success) [self finished]; else [self quickResult];
                    }];
                } else [self quickResult];
            }];
        }];
    }];
}
- (void)quickResult {
    NSString *message(self.session.warning ? WarningMessage(self.session) : self.session.message);
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("ADD_SOURCE") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CydiaSourceText(@"SOURCE_ADD_ADVANCED") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self showAdvanced]; }]];
    if (self.session.ready) [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("ADD_SOURCE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self.session commitWithCompletion:^(BOOL success) { if (success) [self finished]; else [self quickResult]; }];
    }]];
    [self.presenter presentViewController:alert animated:YES completion:nil];
}
- (void)chooseKey {
    UIAlertController *choices([UIAlertController alertControllerWithTitle:CydiaSourceText(@"SOURCE_ADD_KEY") message:CydiaSourceText(@"SOURCE_ADD_KEY_HELP") preferredStyle:UIAlertControllerStyleActionSheet]);
    [choices addAction:[UIAlertAction actionWithTitle:CydiaSourceText([self.session draft].raw ? @"SOURCE_ADD_KEEP_SIGNING" : @"SOURCE_ADD_USE_APT") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self.session clearSelectedKey]; [self.session draft].signedBy.clear(); [self changed];
    }]];
    [choices addAction:[UIAlertAction actionWithTitle:CydiaSourceText(@"SOURCE_ADD_FIND_KEY") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self findSigningKey]; }]];
    [choices addAction:[UIAlertAction actionWithTitle:CydiaSourceText(@"SOURCE_ADD_KEY_FILE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIDocumentPickerViewController *picker([[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"] inMode:UIDocumentPickerModeImport]);
        picker.delegate = self; picker.allowsMultipleSelection = NO; [self presentViewController:picker animated:YES completion:nil];
    }]];
    [choices addAction:[UIAlertAction actionWithTitle:CydiaSourceText(@"SOURCE_ADD_KEY_PACKAGE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self chooseKeyPackage]; }]];
    [choices addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    choices.popoverPresentationController.sourceView = self.table;
    choices.popoverPresentationController.sourceRect = CGRectMake(self.table.bounds.size.width / 2, 40, 1, 1);
    [self presentViewController:choices animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)URLs {
    if (URLs.count != 1) return; NSURL *URL(URLs.firstObject);
    self.finding = YES; [self refreshForm];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            BOOL scope([URL startAccessingSecurityScopedResource]); NSInputStream *stream([NSInputStream inputStreamWithURL:URL]);
            NSMutableData *data([NSMutableData data]); [stream open]; uint8_t buffer[8192]; BOOL valid(YES);
            while (true) {
                NSInteger count([stream read:buffer maxLength:sizeof(buffer)]);
                if (count == 0) break;
                if (count < 0 || data.length + count > CydiaRuntime::Keyring::MaximumKeyBytes) { valid = NO; break; }
                [data appendBytes:buffer length:count];
            }
            [stream close]; if (scope) [URL stopAccessingSecurityScopedResource];
            CydiaRuntime::Privileged::Error error;
            valid = valid && data.length != 0 && CydiaRuntime::Keyring::CheckPublicKeyPackets(
                std::string(static_cast<const char *>(data.bytes), data.length), nullptr, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.finding = NO; [self refreshForm]; if (self.cancelled) return;
                if (!valid) { [self showMessage:CydiaSourceText(@"SOURCE_ADD_KEY_INVALID")]; return; }
                [self.session selectKey:data provenance:URL.lastPathComponent package:nil path:nil]; [self changed];
            });
        }
    });
}
- (void)chooseKeyPackage {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:CydiaSourceText(@"SOURCE_ADD_KEY_PACKAGE") message:CydiaSourceText(@"SOURCE_ADD_KEY_PACKAGE_HELP") preferredStyle:UIAlertControllerStyleAlert]);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert(alert);
    [alert addAction:[UIAlertAction actionWithTitle:CydiaSourceText(@"SOURCE_CONTINUE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self loadKeyPackage:[weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @""];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)loadKeyPackage:(NSString *)package {
    self.finding = YES; [self refreshForm];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSMutableArray<NSString *> *keys([NSMutableArray array]);
            const BOOL acquired([self.session.database beginSettingsChange]);
            if (acquired) {
                @try { @synchronized(self.session.database) {
                    namespace Client = CydiaRuntime::PrivilegedClient;
                    namespace Wire = CydiaRuntime::Privileged;
                    const auto result(Client::RunNativeCommand("--cydia-key-package-files", Wire::SerializeFields({B(package)})));
                    if (result.succeeded()) for (std::size_t count = 0; count <= 256; ++count) {
                        std::vector<std::string> files; Wire::Error error;
                        if (!Wire::ParseFields(result.output, count, &files, &error)) continue;
                        for (const auto &file : files) [keys addObject:S(file)];
                        break;
                    }
                } } @finally { [self.session.database endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.finding = NO; [self refreshForm]; if (self.cancelled) return;
                if (keys.count == 0) { [self showMessage:CydiaSourceText(@"SOURCE_ADD_KEY_NOT_FOUND")]; return; }
                UIAlertController *chooser([UIAlertController alertControllerWithTitle:CydiaSourceText(@"SOURCE_ADD_KEY_PACKAGE") message:nil preferredStyle:UIAlertControllerStyleActionSheet]);
                for (NSString *path in keys) [chooser addAction:[UIAlertAction actionWithTitle:path style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self loadKeyPackage:package path:path];
                }]];
                [chooser addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
                chooser.popoverPresentationController.sourceView = self.table; chooser.popoverPresentationController.sourceRect = CGRectMake(self.table.bounds.size.width / 2, 40, 1, 1);
                [self presentViewController:chooser animated:YES completion:nil];
            });
        }
    });
}
- (void)loadKeyPackage:(NSString *)package path:(NSString *)path {
    self.finding = YES; [self refreshForm];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSData *bytes(nil); const BOOL acquired([self.session.database beginSettingsChange]);
            if (acquired) {
                @try { @synchronized(self.session.database) {
                    const auto key(CydiaRuntime::PrivilegedClient::RunNativeCommand("--cydia-key-package-read",
                        CydiaRuntime::Privileged::SerializeFields({B(package), B(path)})));
                    if (key.succeeded()) bytes = [NSData dataWithBytes:key.output.data() length:key.output.size()];
                } } @finally { [self.session.database endSettingsChange]; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.finding = NO; [self refreshForm]; if (self.cancelled) return;
                if (bytes.length == 0) { [self showMessage:CydiaSourceText(@"SOURCE_ADD_KEY_NOT_FOUND")]; return; }
                [self.session selectKey:bytes provenance:[NSString stringWithFormat:@"%@\n%@", package, path] package:package path:path];
                [self changed];
            });
        }
    });
}
@end
