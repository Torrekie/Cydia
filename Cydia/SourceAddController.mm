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
#include <algorithm>

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
static BOOL EmptyRaw(const Src::SourceDraft &draft) {
    return draft.raw && [S(draft.rawContents) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0;
}
static BOOL TextInFormat(const Src::SourceDraft &draft, Src::Format format, Src::SourceDraft *converted) {
    if (EmptyRaw(draft)) { *converted = Src::ImportSourceDraft("", format); return YES; }
    if (Src::ConvertDraftFormat(draft, format, converted)) return YES;
    // A pasted definition may already use the other syntax. Selecting that
    // editor reparses the same bytes; it never overwrites them with old fields.
    if (draft.raw) {
        auto imported(Src::ImportSourceDraft(draft.rawContents, format));
        if (Src::BuildSourceDraft(imported, "draft").valid()) { *converted = imported; return YES; }
    }
    return NO;
}
static BOOL DraftReady(const Src::SourceDraft &draft) {
    const auto built(Src::BuildSourceDraft(draft, "draft"));
    if (!built.valid()) return NO;
    for (const auto &definition : built.document.definitions) for (const auto &uri : definition.uris) {
        NSURL *URL([NSURL URLWithString:S(uri)]);
        if ([@[@"http", @"https"] containsObject:URL.scheme.lowercaseString] && URL.host.length == 0) return NO;
    }
    return YES;
}
static BOOL ValidFilename(NSString *filename, Src::Format format) {
    if (filename.length == 0 || [filename hasPrefix:@"."] || ![filename hasSuffix:format == Src::Format::Deb822 ? @".sources" : @".list"]) return NO;
    std::string bytes(B(filename)); if (bytes.size() > 255) return NO;
    for (char c : bytes) if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) return NO;
    return YES;
}
static NSString *WarningMessage(CydiaSourceAddSession *session) {
    NSString *notice(CydiaSourceText(@"SOURCE_ADD_UNVERIFIED_WARNING"));
    return session.message.length ? [notice stringByAppendingFormat:@"\n\n%@", session.message] : notice;
}

@implementation CydiaSourceAddController {
    Src::SourceDraft fieldBase_, pendingFields_;
    BOOL hasPendingFields_;
}
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
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.table.estimatedRowHeight = 64; self.table.accessibilityIdentifier = @"cydia.source-draft.form";
    self.view = self.table; CydiaStyleSourceForm(self.table, self.traitCollection);
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillHideNotification object:nil];
    [self refreshForm];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)keyboard:(NSNotification *)notification {
    if (self.view.window == nil) return;
    CGRect frame([self.view convertRect:[notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil]);
    CGRect overlap(CGRectIntersection(self.view.bounds, frame));
    CGFloat height([notification.name isEqual:UIKeyboardWillHideNotification] || CGRectIsNull(overlap) ? 0 : overlap.size.height);
    UIEdgeInsets insets(self.table.contentInset); insets.bottom = MAX(0, height - self.view.safeAreaInsets.bottom);
    [UIView animateWithDuration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] animations:^{
        self.table.contentInset = insets; self.table.scrollIndicatorInsets = insets;
    }];
}
- (void)finishEditing { [self.view endEditing:YES]; }
- (UIToolbar *)editingToolbar {
    UIToolbar *bar([[UIToolbar alloc] init]); [bar sizeToFit];
    bar.items = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithTitle:UCLocalize("DONE") style:UIBarButtonItemStyleDone target:self action:@selector(finishEditing)]];
    return bar;
}
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
    BOOL valid(DraftReady([self.session draft]));
    BOOL destination(self.session.destinationPath.length || ValidFilename(self.session.sourceFilename, [self.session draft].format));
    self.navigationItem.rightBarButtonItem.enabled = !busy && (self.reviewPage && self.session.ready ? YES : valid && destination);
    if (!busy && !self.reviewPage && (!valid || !destination)) self.navigationItem.rightBarButtonItem = nil;
    self.table.userInteractionEnabled = !busy;
    [self updateRows];
}
- (void)cancel {
    [self.session cancel]; [self cancelDiscovery]; self.cancelled = YES;
    CyteViewController *presenter(self.presenter); NSString *URL(self.originalURL); Database *database(self.session.database);
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (URL != nil) [CydiaSourceAddController showURLPromptWithDatabase:database presenter:presenter URL:URL];
    }];
}
- (void)changed {
    [self.session invalidateReview]; self.reviewPage = NO;
    [self.session refreshSuggestedFilename]; [self refreshForm];
}
- (BOOL)formFields:(Src::SourceDraft *)fields {
    if (hasPendingFields_) { *fields = pendingFields_; return YES; }
    return Src::ProjectDraftFields([self.session draft], fields);
}
- (BOOL)applyFields:(const Src::SourceDraft &)fields {
    if (!hasPendingFields_) fieldBase_ = [self.session draft];
    Src::SourceDraft updated;
    if (!Src::ApplyDraftFields(fieldBase_, fields, &updated)) {
        [self.view endEditing:YES]; [self refreshForm];
        [self showMessage:CydiaSourceText(@"SOURCE_DEFINITION_INVALID")]; return NO;
    }
    pendingFields_ = fields; hasPendingFields_ = YES; [self.session draft] = updated;
    [self changed]; return YES;
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("SOURCES") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
        if (!self.session.disabled && self.session.reviewed) [result addObject:Row(@"signature", CydiaSourceText(@"SOURCE_ADD_SIGNATURE"),
            CydiaSourceText([self.session checkResult].authenticated ? @"SOURCE_ADD_VERIFIED" : @"SOURCE_ADD_UNVERIFIED"))];
        if (self.session.hasSelectedKey) [result addObject:Row(@"trust", CydiaSourceText(@"SOURCE_ADD_KEY"),
            [NSString stringWithFormat:@"%@\n%@", self.session.keyProvenance ?: @"", [self.session.fingerprints componentsJoinedByString:@"\n"]])];
        NSMutableArray *actions([NSMutableArray arrayWithObject:Row(@"edit", UCLocalize("EDIT"))]);
        if (!self.session.disabled && ![self.session checkResult].authenticated && ![self.session checkResult].repositories.empty())
            [actions addObject:Row(@"findkey", CydiaSourceText(@"SOURCE_ADD_FIND_KEY"))];
        if (!self.session.ready && DraftReady(draft))
            [actions addObject:Row(@"disabled", CydiaSourceText(@"SOURCE_ADD_SAVE_DISABLED"))];
        return @[result, @[Row(@"savedpath", CydiaSourceText(@"SOURCE_CHOOSE_FILE"), self.session.reviewedDestinationPath)], actions, @[]];
    }
    Src::SourceDraft fields; BOOL projected([self formFields:&fields]);
    BOOL valid(DraftReady(draft));
    NSMutableArray *basic([NSMutableArray array]), *options([NSMutableArray array]), *destination([NSMutableArray array]);
    if (projected) {
        [basic addObject:Row(@"uri", CydiaSourceText(@"SOURCE_URI"), S(fields.uri))];
        Src::SourceDraft address; address.uri = fields.uri;
        NSURL *URL([NSURL URLWithString:S(fields.uri)]);
        BOOL web([@[@"http", @"https"] containsObject:URL.scheme.lowercaseString]);
        BOOL hasAddress(Src::BuildSourceDraft(address, "draft").valid() && (!web || URL.host.length));
        if (hasAddress) {
            [basic addObject:Row(@"distribution", CydiaSourceText(@"SOURCE_SUITE"), S(fields.distribution))];
            if (!fields.distribution.empty()) [basic addObject:Row(@"components", CydiaSourceText(@"SOURCE_ADD_COMPONENTS"), Joined(fields.components))];
            if (web) [basic addObject:Row(@"discover", CydiaSourceText(@"SOURCE_ADD_FIND_OPTIONS"))];
        }
        if (valid) [options addObject:Row(@"architectures", CydiaSourceText(@"SOURCE_ADD_ARCHITECTURES"),
            fields.architectureMode == Src::ArchitectureMode::Inherit ? CydiaSourceText(@"SOURCE_ADD_USE_APT") :
            fields.architectureMode == Src::ArchitectureMode::Modify || !fields.architecturesAdd.empty() || !fields.architecturesRemove.empty() ?
            [NSString stringWithFormat:@"%@%@%@", fields.architectures.empty() ? @"" : [@"arch=" stringByAppendingString:Joined(fields.architectures)],
                fields.architecturesAdd.empty() ? @"" : [@" arch+=" stringByAppendingString:Joined(fields.architecturesAdd)],
                fields.architecturesRemove.empty() ? @"" : [@" arch-=" stringByAppendingString:Joined(fields.architecturesRemove)]] : Joined(fields.architectures))];
    }
    if (valid) {
        [options addObject:Row(@"key", CydiaSourceText(@"SOURCE_ADD_KEY"), self.session.keyProvenance ?:
            (projected && !fields.signedBy.empty() ? (fields.signedBy.find("-----BEGIN PGP") == std::string::npos ? S(fields.signedBy) : CydiaSourceText(@"SOURCE_ENTER_DEFINITION")) : CydiaSourceText(@"SOURCE_ADD_USE_APT")))];
        [options addObject:Row(@"policy", CydiaSourceText(@"SOURCE_ADD_SECURITY"), policy)];
        [destination addObject:Row(self.session.existingSource ? @"savedpath" : @"destination", CydiaSourceText(@"SOURCE_CHOOSE_FILE"),
            self.session.destinationPath ?: CydiaSourceText(@"SOURCE_NEW_FILE"))];
        if (!self.session.existingSource && self.session.destinationPath.length == 0) {
            [destination addObject:Row(@"filename", CydiaSourceText(@"SOURCE_ADD_FILENAME"), self.session.sourceFilename)];
            if (!ValidFilename(self.session.sourceFilename, draft.format))
                [destination addObject:Row(@"filenameerror", CydiaSourceText(@"SOURCE_FILENAME_INVALID"))];
        }
    }
    NSMutableArray *text([NSMutableArray arrayWithObject:Row(@"textformat", CydiaSourceText(@"SOURCE_ADD_TEXT_FORMAT"))]);
    [text addObject:Row(draft.format == Src::Format::OneLine ? @"oneline" : @"deb822",
        CydiaSourceText(draft.format == Src::Format::OneLine ? @"SOURCE_ADD_ONE_LINE" : @"SOURCE_ADD_DEB822"), S(Src::SerializeSourceDraft(draft)))];
    if (draft.raw && !projected) [text addObject:Row(@"textnotice", CydiaSourceText(valid ? @"SOURCE_ADD_TEXT_FIELDS_UNAVAILABLE" : @"SOURCE_ADD_TEXT_INVALID"))];
    if (self.session.existingSource || self.session.destinationPath.length)
        [text addObject:Row(@"fixedformatnotice", CydiaSourceText(@"SOURCE_ADD_EXISTING_DESTINATION"))];
    Src::SourceDraft converted;
    if (draft.raw && !TextInFormat(draft, draft.format == Src::Format::OneLine ? Src::Format::Deb822 : Src::Format::OneLine, &converted))
        [text addObject:Row(@"conversionnotice", CydiaSourceText(@"SOURCE_ADD_TEXT_CONVERSION_UNAVAILABLE"))];
    return @[basic, options, text, destination];
}
- (void)updateRows {
    NSArray *next([self rows]), *previous(self.displayedRows);
    BOOL reload(previous == nil || self.displayedReview != self.reviewPage);
    self.displayedRows = next; self.displayedReview = self.reviewPage;
    if (reload) { [self.table reloadData]; return; }
    NSMutableArray *removed([NSMutableArray array]), *inserted([NSMutableArray array]);
    for (NSUInteger section = 0; section < next.count; ++section) {
        NSArray *oldKeys([previous[section] valueForKey:@"key"]), *newKeys([next[section] valueForKey:@"key"]);
        for (NSUInteger row = 0; row < oldKeys.count; ++row)
            if (![newKeys containsObject:oldKeys[row]]) [removed addObject:[NSIndexPath indexPathForRow:row inSection:section]];
        for (NSUInteger row = 0; row < newKeys.count; ++row)
            if (![oldKeys containsObject:newKeys[row]]) [inserted addObject:[NSIndexPath indexPathForRow:row inSection:section]];
    }
    // Stable section/row identities keep the active input and caret intact.
    // UIKit animates prerequisite-dependent rows in both directions.
    [self.table beginUpdates];
    [self.table deleteRowsAtIndexPaths:removed withRowAnimation:UITableViewRowAnimationAutomatic];
    [self.table insertRowsAtIndexPaths:inserted withRowAnimation:UITableViewRowAnimationAutomatic];
    [self.table endUpdates];
    for (NSIndexPath *path in self.table.indexPathsForVisibleRows) {
        if (path.section >= self.displayedRows.count || path.row >= self.displayedRows[path.section].count) continue;
        NSDictionary *row(self.displayedRows[path.section][path.row]);
        UITableViewCell *cell([self.table cellForRowAtIndexPath:path]);
        if ([cell isKindOfClass:[CydiaSourceFieldCell class]]) {
            UITextField *field([(CydiaSourceFieldCell *)cell field]); if (!field.isFirstResponder) field.text = row[@"value"];
        } else if ([cell isKindOfClass:[CydiaSourceTextCell class]]) {
            UITextView *editor([(CydiaSourceTextCell *)cell editor]); if (!editor.isFirstResponder) editor.text = row[@"value"];
        } else if ([cell isKindOfClass:[CydiaSourceFormatCell class]]) [self configureTextFormat:[(CydiaSourceFormatCell *)cell control]];
        else { cell.textLabel.text = row[@"title"]; cell.detailTextLabel.text = row[@"value"]; }
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return self.displayedRows.count; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return self.displayedRows[section].count; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (self.displayedRows[section].count == 0) return nil;
    if (self.reviewPage) return section == 0 ? CydiaSourceText(self.session.hasSelectedKey ? @"SOURCE_ADD_TRUST_NOTICE" : @"SOURCE_ADD_REVIEW_NOTICE") : nil;
    if (section == 0) return [NSString stringWithFormat:@"%@\n\n%@\n%@", CydiaSourceText(@"SOURCE_ADD_ADVICE"),
        CydiaSourceText(@"SOURCE_ADD_SUITE_HELP"), CydiaSourceText(@"SOURCE_ADD_COMPONENTS_HELP")];
    if (section == 2) return CydiaSourceText(@"SOURCE_ADD_TEXT_SYNC");
    if (section == 3) return CydiaSourceText(@"SOURCE_ADD_DESTINATION_HELP");
    return nil;
}
- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return self.displayedRows[section].count ? UITableViewAutomaticDimension : 0.01;
}
- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return self.displayedRows[section].count ? UITableViewAutomaticDimension : 0.01;
}
- (void)configureTextFormat:(UISegmentedControl *)control {
    const auto &draft([self.session draft]); Src::SourceDraft converted;
    control.selectedSegmentIndex = draft.format == Src::Format::OneLine ? 0 : 1;
    BOOL convertible(TextInFormat(draft,
        draft.format == Src::Format::OneLine ? Src::Format::Deb822 : Src::Format::OneLine, &converted));
    // Existing files keep their actual format. Choosing New Source File unlocks
    // the format selection for additions that were targeting an existing file.
    BOOL fixed(self.session.existingSource != nil || self.session.destinationPath.length != 0);
    [control setEnabled:YES forSegmentAtIndex:control.selectedSegmentIndex];
    [control setEnabled:convertible && !fixed forSegmentAtIndex:1 - control.selectedSegmentIndex];
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *row(self.displayedRows[path.section][path.row]); NSString *key(row[@"key"]);
    NSString *identifier([@"cydia.source-draft." stringByAppendingString:key]);
    if ([@[@"uri", @"distribution", @"components", @"filename"] containsObject:key]) {
        NSString *placeholder([key isEqual:@"uri"] ? @"https://" : [key isEqual:@"distribution"] ? @"./" :
            [key isEqual:@"components"] ? @"" : CydiaSourceText(@"SOURCE_FILENAME"));
        CydiaSourceFieldCell *cell([[CydiaSourceFieldCell alloc] initWithTitle:row[@"title"] value:row[@"value"]
            placeholder:placeholder URL:[key isEqual:@"uri"] traits:self.traitCollection]);
        cell.field.accessibilityIdentifier = identifier; cell.field.delegate = self; cell.field.inputAccessoryView = [self editingToolbar];
        [cell.field addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
        return cell;
    }
    if ([key isEqual:@"oneline"] || [key isEqual:@"deb822"]) {
        CydiaSourceTextCell *cell([[CydiaSourceTextCell alloc] initWithText:row[@"value"] title:row[@"title"] traits:self.traitCollection]);
        cell.editor.accessibilityIdentifier = identifier; cell.editor.delegate = self; cell.editor.inputAccessoryView = [self editingToolbar];
        return cell;
    }
    if ([key isEqual:@"textformat"]) {
        CydiaSourceFormatCell *cell([[CydiaSourceFormatCell alloc] initWithTitle:row[@"title"] traits:self.traitCollection]);
        cell.control.accessibilityIdentifier = identifier;
        [self configureTextFormat:cell.control];
        [cell.control addTarget:self action:@selector(textFormatChanged:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]);
    CydiaStyleSourceFormCell(cell, self.traitCollection); cell.textLabel.text = row[@"title"]; cell.detailTextLabel.text = row[@"value"];
    cell.accessibilityIdentifier = identifier;
    if ([@[@"policy", @"status", @"definition", @"trust", @"signature", @"savedpath", @"textnotice", @"conversionnotice", @"filenameerror", @"fixedformatnotice"] containsObject:key])
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    else { cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.accessibilityTraits |= UIAccessibilityTraitButton; }
    return cell;
}
- (void)fieldChanged:(UITextField *)field {
    NSString *key(field.accessibilityIdentifier.pathExtension);
    NSString *value(field.text ?: @"");
    if ([key isEqual:@"filename"]) { self.session.sourceFilename = value; [self changed]; return; }
    Src::SourceDraft fields; if (![self formFields:&fields]) return;
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([key isEqual:@"uri"]) fields.uri = B(value);
    else if ([key isEqual:@"distribution"]) { fields.distribution = B(value); fields.exactPath = [value hasSuffix:@"/"]; }
    else fields.components = Words(value);
    [self applyFields:fields];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field { [field resignFirstResponder]; return YES; }
- (void)textFieldDidBeginEditing:(UITextField *)field { self.editingKey = field.accessibilityIdentifier.pathExtension; }
- (void)textFieldDidEndEditing:(UITextField *)field { self.editingKey = nil; [self refreshForm]; }
- (void)textViewDidBeginEditing:(UITextView *)textView { self.editingKey = textView.accessibilityIdentifier.pathExtension; }
- (void)textViewDidEndEditing:(UITextView *)textView { self.editingKey = nil; [self refreshForm]; }
- (void)textViewDidChange:(UITextView *)textView {
    hasPendingFields_ = NO; [self.session clearSelectedKey];
    [self.session draft] = Src::ImportSourceDraft(B(textView.text ?: @""),
        [textView.accessibilityIdentifier hasSuffix:@"oneline"] ? Src::Format::OneLine : Src::Format::Deb822);
    [self changed];
}
- (void)textFormatChanged:(UISegmentedControl *)control {
    Src::Format format(control.selectedSegmentIndex == 0 ? Src::Format::OneLine : Src::Format::Deb822);
    [self.view endEditing:YES];
    Src::SourceDraft converted;
    if (!TextInFormat([self.session draft], format, &converted)) {
        [self showMessage:CydiaSourceText(@"SOURCE_ADD_TEXT_CONVERSION_UNAVAILABLE")]; [self refreshForm]; return;
    }
    Src::Format previous([self.session draft].format);
    [self.session draft] = converted; [self.session draftFormatDidChangeFrom:previous];
    hasPendingFields_ = NO; [self changed];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES]; NSDictionary *row(self.displayedRows[path.section][path.row]); NSString *key(row[@"key"]);
    [self.view endEditing:YES];
    if ([key isEqual:@"architectures"]) [self chooseArchitectures];
    else if ([key isEqual:@"key"]) [self chooseKey];
    else if ([key isEqual:@"findkey"]) [self findSigningKey];
    else if ([key isEqual:@"discover"]) [self findOptions];
    else if ([key isEqual:@"destination"]) [self chooseDestination];
    else if ([key isEqual:@"edit"]) { self.reviewPage = NO; [self refreshForm]; }
    else if ([key isEqual:@"disabled"]) [self checkDisabled];
}
- (void)chooseArchitectures {
    Src::SourceDraft fields; if (![self formFields:&fields]) return;
    if (fields.architectureMode == Src::ArchitectureMode::Modify || !fields.architecturesAdd.empty() || !fields.architecturesRemove.empty()) { [self editRaw]; return; }
    NSMutableArray *choices([NSMutableArray arrayWithObject:@{@"title":CydiaSourceText(@"SOURCE_ADD_USE_APT"), @"detail":Joined(CydiaAPT::Architectures()), @"value":@"inherit", @"exclusive":@YES}]);
    std::vector<std::string> available(CydiaAPT::RegisteredArchitectures());
    for (const auto &architecture : fields.architectures)
        if (std::find(available.begin(), available.end(), architecture) == available.end()) available.push_back(architecture);
    for (const auto &architecture : available) [choices addObject:@{@"title":S(architecture), @"value":S(architecture)}];
    NSMutableSet *selected([NSMutableSet set]);
    if (fields.architectureMode == Src::ArchitectureMode::Inherit) [selected addObject:@"inherit"];
    else for (const auto &architecture : fields.architectures) [selected addObject:S(architecture)];
    __weak CydiaSourceAddController *weakSelf(self);
    CydiaSourceChoicesController *choice([[CydiaSourceChoicesController alloc] initWithTitle:CydiaSourceText(@"SOURCE_ADD_ARCHITECTURES")
        choices:choices selected:selected multiple:YES explanation:CydiaSourceText(@"SOURCE_ADD_ARCHITECTURE_HELP") saved:^(NSSet<NSString *> *values) {
            CydiaSourceAddController *owner(weakSelf); if (!owner) return; Src::SourceDraft draft; if (![owner formFields:&draft]) return;
            draft.architectures.clear(); draft.architecturesAdd.clear(); draft.architecturesRemove.clear();
            for (NSString *value in [[values allObjects] sortedArrayUsingSelector:@selector(compare:)])
                if (![value isEqual:@"inherit"]) draft.architectures.push_back(B(value));
            draft.architectureMode = draft.architectures.empty() ? Src::ArchitectureMode::Inherit : Src::ArchitectureMode::Replace;
            [owner applyFields:draft];
        }]);
    [self.navigationController pushViewController:choice animated:YES];
}
- (void)editRaw {
    self.reviewPage = NO; [self refreshForm];
    for (NSUInteger row = 0; row < self.displayedRows[2].count; ++row) {
        NSString *key(self.displayedRows[2][row][@"key"]);
        if (![key isEqual:@"oneline"] && ![key isEqual:@"deb822"]) continue;
        NSIndexPath *path([NSIndexPath indexPathForRow:row inSection:2]);
        [self.table scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        [self.table layoutIfNeeded];
        CydiaSourceTextCell *cell((CydiaSourceTextCell *)[self.table cellForRowAtIndexPath:path]);
        [cell.editor becomeFirstResponder]; break;
    }
}
- (void)chooseDestination {
    if (self.session.existingSource) return;
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
    [self.view endEditing:YES];
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
        [self.session clearSelectedKey];
        if (![self.session draft].raw) { Src::SourceDraft fields; if ([self formFields:&fields]) { fields.signedBy.clear(); [self applyFields:fields]; } }
        [self changed];
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
