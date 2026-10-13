/* Copyright (C) 2008-2017 Jay Freeman; Modified work Copyright (C) 2026 Torrekie.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "CyteKit/UCPlatform.h"
#import "Cydia/SourceControllers.h"
#import "Cydia/SourceAddController.h"
#import "Cydia/Appearance.h"
#import "Cydia/CydiaDelegate.h"
#import "Cydia/Database.h"
#import "Cydia/RuntimeProviderStatus.h"
#import "Cydia/LegacyUICompatibilityNativeCaller.h"
#import "Cydia/SectionControllers.h"
#import "Cydia/AdvancedSettingsController.h"
#import "Cydia/Source.h"
#import "Sources.h"
#import "CyteKit/Localize.h"
#import "CyteKit/TableViewCell.h"
#import "CyteKit/extern.h"
#import "Menes/Menes.h"
#import "Menes/ObjectHandle.h"
#import "iPhonePrivate.h"
#include <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <algorithm>
#include <cerrno>
#include <sys/stat.h>

static NSString *SourceUI(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Sources"];
}
static void SourceMessage(UIViewController *presenter, NSString *message) {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("SOURCES") message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([presenter.presentedViewController isKindOfClass:[UIAlertController class]])
            [presenter dismissViewControllerAnimated:YES completion:^{ [presenter presentViewController:alert animated:YES completion:nil]; }];
        else [presenter presentViewController:alert animated:YES completion:nil];
    });
}
static void SourceSettings(CyteViewController *presenter, Database *database) {
    // A protected-source review can originate below Advanced Settings. Return
    // to its existing ancestor instead of constructing a second settings tree.
    for (UIViewController *controller in presenter.navigationController.viewControllers)
        if ([controller isKindOfClass:[CydiaAdvancedSettingsController class]]) {
            [presenter.navigationController popToViewController:controller animated:YES];
            return;
        }
    CydiaAdvancedSettingsController *settings([[CydiaAdvancedSettingsController alloc] initWithDatabase:database]);
    [settings setDelegate:[presenter delegate]];
    [presenter.navigationController pushViewController:settings animated:YES];
}
static void SourceReviewRequired(CyteViewController *presenter, Database *database, NSString *message = nil) {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("SOURCES")
        message:message ?: SourceUI(@"SOURCE_PROTECTION_REVIEW_REQUIRED") preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:SourceUI(@"SOURCE_ADVANCED_SETTINGS") style:UIAlertActionStyleDefault handler:^(UIAlertAction *) { SourceSettings(presenter, database); }]];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([presenter.presentedViewController isKindOfClass:[UIAlertController class]])
            [presenter dismissViewControllerAnimated:YES completion:^{ [presenter presentViewController:alert animated:YES completion:nil]; }];
        else [presenter presentViewController:alert animated:YES completion:nil];
    });
}
static void StyleSourceCell(UITableViewCell *cell) {
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:cell.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:cell.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:cell.traitCollection];
}
static UITableViewCell *SourceSettingsCell(UITableView *table) {
    UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"SourceSettingsCell"]);
    if (cell == nil) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SourceSettingsCell"];
    StyleSourceCell(cell);
    cell.textLabel.text = nil; cell.detailTextLabel.text = nil;
    cell.textLabel.enabled = YES; cell.detailTextLabel.enabled = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessibilityIdentifier = nil; cell.accessibilityTraits = UIAccessibilityTraitNone;
    return cell;
}
static void StyleSourceTable(UITableView *table, UITraitCollection *traits) {
    table.backgroundColor = [UIColor cydiaColorForRole:table.style == UITableViewStylePlain ? CydiaColorRoleBackground : CydiaColorRoleGroupedBackground traitCollection:traits];
    table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:traits];
    [table reloadData];
}
static BOOL SourceTraitsChanged(UITraitCollection *current, UITraitCollection *previous) {
    return CydiaColorAppearanceDidChange(current, previous) || ![current.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory];
}
static void ReviewedSourceCommit(CyteViewController *presenter, Database *database,
    const CydiaSources::StoredDocument &expected, const CydiaSources::Mutation &mutation,
    CydiaSources::Access access, NSString *action, NSString *summary, void (^completion)(void)) {
    const auto captured(expected); const auto edit(mutation);
    if (access == CydiaSources::Access::AdvancedSettings && mutation.kind != CydiaSources::EditKind::AppendDefinition &&
        mutation.ordinal < expected.document.definitions.size()) {
        const auto policy(CydiaReadSourceProtection());
        const auto &definition(expected.document.definitions[mutation.ordinal]);
        for (const auto &selector : policy.selectors)
            if (selector.originPath == definition.path && selector.semanticKey == definition.semanticKey) {
                summary = [summary stringByAppendingFormat:@"\n\n%@", SourceUI(@"SOURCE_BOOTSTRAP_CHANGE")];
                break;
            }
    }
    UIAlertController *alert([UIAlertController alertControllerWithTitle:SourceUI(@"SOURCE_REVIEW_CHANGE")
        message:summary preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:action
        style:mutation.kind == CydiaSources::EditKind::RemoveDefinition ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
        handler:^(UIAlertAction *) {
            if (![database beginSettingsChange]) { SourceMessage(presenter, SourceUI(@"SOURCE_WAIT_FOR_OPERATION")); return; }
            NSError *error(nil); bool success(false);
            @try { success = CydiaCommitSourceMutation(captured, edit, &error, access); }
            @finally { [database endSettingsChange]; }
            if (!success) {
                if (error.code == 74) {
                    id<CydiaDelegate, NSObject> delegate((id)[presenter delegate]);
                    if ([delegate respondsToSelector:@selector(syncData)]) [delegate syncData];
                    SourceReviewRequired(presenter, database, error.localizedDescription);
                } else SourceMessage(presenter, error.localizedDescription ?: SourceUI(@"SOURCE_SAVE_FAILED"));
                return;
            }
            if (completion != nil) completion();
            id<CydiaDelegate, NSObject> delegate((id)[presenter delegate]);
            if ([delegate respondsToSelector:@selector(syncData)]) [delegate syncData];
        }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}
static NSString *DefinitionSummary(CydiaSourceDefinition *row) {
    return [NSString stringWithFormat:@"%@:%lu\n%@\n%@", row.filePath, (unsigned long)row.lineNumber,
        row.original ?: @"",
        SourceUI(@"SOURCE_WHOLE_DEFINITION")];
}
static BOOL DefinitionMatchesSource(CydiaSourceDefinition *row, Source *source) {
    if (source == nil || ![row.types containsObject:[source type]] || ![row.suites containsObject:[source distribution]]) return NO;
    NSCharacterSet *slashes([NSCharacterSet characterSetWithCharactersInString:@"/"]);
    NSString *uri([[source rooturi] stringByTrimmingCharactersInSet:slashes]);
    for (NSString *candidate in row.uris)
        if ([uri isEqual:[candidate stringByTrimmingCharactersInSet:slashes]]) return YES;
    return NO;
}
static NSArray<CydiaSourceDefinition *> *DefinitionsForSource(NSArray<CydiaSourceDefinition *> *definitions, Source *source) {
    NSMutableArray *matches([NSMutableArray array]);
    for (CydiaSourceDefinition *row in definitions)
        if (DefinitionMatchesSource(row, source)) [matches addObject:row];
    return matches;
}
static NSString *DefinitionName(Database *database, CydiaSourceDefinition *row) {
    @synchronized (database) {
        for (Source *source in [database sources])
            if (DefinitionMatchesSource(row, source) && [source name].length) return [source name];
    }
    NSString *name([row.uris componentsJoinedByString:@", "]);
    return name.length ? name : SourceUI(@"SOURCE_DISABLED_TEMPLATE");
}
static BOOL DefinitionIsProtected(CydiaSourceDefinition *row, const CydiaSources::PolicySnapshot &policy) {
    const auto &definition([row definition]);
    for (const auto &selector : policy.selectors)
        if (selector.originPath == definition.path && selector.semanticKey == definition.semanticKey) return YES;
    return NO;
}
static NSString *DefinitionScope(CydiaSourceDefinition *row) {
    NSString *scope([NSString stringWithFormat:@"%@\n%@: %@", [row.uris componentsJoinedByString:@"\n"],
        SourceUI(@"SOURCE_SUITE"), [row.suites componentsJoinedByString:@", "]]);
    if (row.components.count) scope = [scope stringByAppendingFormat:@"\n%@: %@", SourceUI(@"SOURCE_COMPONENTS"), [row.components componentsJoinedByString:@" "]];
    if (row.types.count > 1) scope = [scope stringByAppendingFormat:@"\n%@", [row.types componentsJoinedByString:@", "]];
    if (row.uris.count > 1 || row.suites.count > 1 || row.types.count > 1) scope = [scope stringByAppendingFormat:@"\n\n%@", SourceUI(@"SOURCE_WHOLE_DEFINITION")];
    return scope;
}
/* Source Cell {{{ */
@interface Source (CydiaSourceCellDelegateOwnership)
- (BOOL)cydiaSourceCellOwnsDelegate:(id)cell;
@end
@implementation Source (CydiaSourceCellDelegateOwnership)
- (BOOL)cydiaSourceCellOwnsDelegate:(id)cell { return delegate_ == cell; }
@end

@interface SourceCell : CyteTableViewCell <CyteTableViewCellDelegate, SourceDelegate> {
    _H<Source, 1> source_;
    _H<NSURL> url_;
    _H<UIImage> icon_;
    _H<NSString> origin_;
    _H<NSString> label_;
    _H<UIActivityIndicatorView> indicator_;
}

- (void) setSource:(Source *)source;
- (void) setFetch:(NSNumber *)fetch;

@end

@implementation SourceCell

- (void)invalidateSourceBinding {
    if ([source_ cydiaSourceCellOwnsDelegate:self]) [source_ setDelegate:nil];
    source_ = nil; url_ = nil;
    [indicator_ stopAnimating];
}
- (void)prepareForReuse {
    [super prepareForReuse]; [self invalidateSourceBinding];
    icon_ = [UIImage imageNamed:@"unknown.png"]; origin_ = nil; label_ = nil;
    [self.content setNeedsDisplay];
}
- (void)dealloc { [self invalidateSourceBinding]; }

- (void) applyColorAppearance {
    UIColor *color([UIColor cydiaColorForRole:CydiaColorRoleBackground
                              traitCollection:self.traitCollection]);
    [self setBackgroundColor:color];
    [self.content setBackgroundColor:color];
    [indicator_ setColor:[UIColor cydiaColorForRole:CydiaColorRoleFolderLabel
                                    traitCollection:self.traitCollection]];
}

- (void) _setImage:(NSArray *)data {
    if ([url_ isEqual:[data objectAtIndex:0]]) {
        icon_ = [data objectAtIndex:1];
        [self.content setNeedsDisplay];
    }
}

- (void) _setSource:(NSURL *) url {
    @autoreleasepool {

    if (NSData *data = [NSURLConnection
        sendSynchronousRequest:[NSURLRequest
            requestWithURL:url
            cachePolicy:NSURLRequestUseProtocolCachePolicy
            timeoutInterval:10
        ]

        returningResponse:NULL
        error:NULL
    ])
        if (UIImage *image = [UIImage imageWithData:data])
            [self performSelectorOnMainThread:@selector(_setImage:) withObject:[NSArray arrayWithObjects:url, image, nil] waitUntilDone:NO];
    }
}

- (void) setSource:(Source *)source {
    [self invalidateSourceBinding];
    source_ = source;
    [source_ setDelegate:self];

    [self setFetch:[NSNumber numberWithBool:[source_ fetch]]];

    icon_ = [UIImage imageNamed:@"unknown.png"];

    origin_ = [source name];
    label_ = [source rooturi];

    [self.content setNeedsDisplay];

    url_ = [source iconURL];
    if (url_ != nil)
        [NSThread detachNewThreadSelector:@selector(_setSource:) toTarget:self withObject:url_];
}

- (void) setAllSource {
    [self invalidateSourceBinding];

    icon_ = [UIImage imageNamed:@"folder.png"];
    origin_ = UCLocalize("ALL_SOURCES");
    label_ = UCLocalize("ALL_SOURCES_EX");
    [self.content setNeedsDisplay];
}

- (SourceCell *) initWithFrame:(CGRect)frame reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithFrame:frame reuseIdentifier:reuseIdentifier]) != nil) {
        [self applyColorAppearance];
        [self.content setOpaque:YES];

        indicator_ = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGraySmall];
        [indicator_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin];// | UIViewAutoresizingFlexibleBottomMargin];
        [[self contentView] addSubview:indicator_];

        [self applyColorAppearance];

        [[self.content layer] setContentsGravity:kCAGravityTopLeft];
    } return self;
}

- (void) layoutSubviews {
    [super layoutSubviews];

    UIView *content([self contentView]);
    CGRect bounds([content bounds]);

    CGRect frame([indicator_ frame]);
    frame.origin.x = bounds.size.width - frame.size.width;
    frame.origin.y = Retina((bounds.size.height - frame.size.height) / 2);

    if (kCFCoreFoundationVersionNumber < 800)
        frame.origin.x -= 8;
    [indicator_ setFrame:frame];
}

- (NSString *) accessibilityLabel {
    return origin_;
}

- (void) drawContentRect:(CGRect)rect {
    bool highlighted(self.highlighted);
    float width(rect.size.width);

    if (icon_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) icon_ size];

        while (rect.size.width > 32 || rect.size.height > 32) {
            rect.size.width /= 2;
            rect.size.height /= 2;
        }

        rect.origin.x = 26 - rect.size.width / 2;
        rect.origin.y = 26 - rect.size.height / 2;

        [icon_ drawInRect:Retina(rect)];
    }

    if (highlighted && kCFCoreFoundationVersionNumber < 800)
        CydiaSetColor(CydiaColorRoleSelectedLabel, self.traitCollection);

    if (!highlighted)
        CydiaSetColor(CydiaColorRoleLabel, self.traitCollection);
    [origin_ drawAtPoint:CGPointMake(52, 8) forWidth:(width - 49) withFont:Font18Bold_ lineBreakMode:NSLineBreakByTruncatingTail];

    if (!highlighted)
        CydiaSetColor(CydiaColorRoleSecondaryLabel, self.traitCollection);
    [label_ drawAtPoint:CGPointMake(52, 29) forWidth:(width - 49) withFont:Font12_ lineBreakMode:NSLineBreakByTruncatingTail];
}

- (void) setFetch:(NSNumber *)fetch {
    // A callback queued before reuse belongs to the old source. Always read
    // the currently bound source so it cannot animate another row.
    if (source_ != nil && [source_ fetch])
        [indicator_ startAnimating];
    else
        [indicator_ stopAnimating];
}

@end
/* }}} */

@interface CydiaSourceDefinitionDetailsController : CyteViewController <UITableViewDataSource>
- (instancetype)initWithRow:(CydiaSourceDefinition *)row;
- (instancetype)initWithDiagnostic:(NSString *)diagnostic;
@end
@implementation CydiaSourceDefinitionDetailsController {
    CydiaSourceDefinition *row_;
    NSString *diagnostic_;
    UITableView *table_;
}
- (instancetype)initWithRow:(CydiaSourceDefinition *)row { if ((self = [super init]) != nil) row_ = row; return self; }
- (instancetype)initWithDiagnostic:(NSString *)diagnostic { if ((self = [super init]) != nil) diagnostic_ = [diagnostic copy]; return self; }
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 80; self.view = table_;
    StyleSourceTable(table_, self.traitCollection);
}
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.title = SourceUI(diagnostic_ != nil ? @"SOURCE_FILE_ERRORS" : @"SOURCE_DEFINITION_DETAILS"); }
- (void)traitCollectionDidChange:(UITraitCollection *)previous { [super traitCollectionDidChange:previous]; if (SourceTraitsChanged(self.traitCollection, previous)) StyleSourceTable(table_, self.traitCollection); }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return diagnostic_ != nil ? 1 : 2; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell(SourceSettingsCell(table));
    cell.textLabel.text = SourceUI(diagnostic_ != nil ? @"SOURCE_FILE_UNAVAILABLE" : path.row == 0 ? @"SOURCE_LOCATION" : @"SOURCE_DEFINITION");
    cell.detailTextLabel.text = diagnostic_ != nil ? diagnostic_ : path.row == 0 ? [NSString stringWithFormat:@"%@:%lu", row_.filePath, (unsigned long)row_.lineNumber] : row_.original;
    cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.accessibilityTraits = UIAccessibilityTraitStaticText; return cell;
}
@end

@interface CydiaSourceDefinitionController : CyteViewController <UITableViewDataSource, UITableViewDelegate>
- (instancetype)initWithDatabase:(Database *)database row:(CydiaSourceDefinition *)row access:(CydiaSources::Access)access;
@end
@implementation CydiaSourceDefinitionController {
    Database *database_;
    CydiaSourceDefinition *row_;
    CydiaSources::Access access_;
    UITableView *table_;
    BOOL editable_;
    BOOL protected_, showsAdvanced_;
    NSArray<NSString *> *detailTitles_, *detailValues_, *actionTitles_;
}
- (instancetype)initWithDatabase:(Database *)database row:(CydiaSourceDefinition *)row access:(CydiaSources::Access)access {
    if ((self = [super init]) != nil) {
        database_ = database; row_ = row; access_ = access;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(runtimeStatusDidChange:)
            name:CydiaRuntimeProviderStatusDidChangeNotification object:database];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)runtimeStatusDidChange:(NSNotification *)notification {
    if (self.isViewLoaded && self.navigationController.topViewController == self) [self reloadData];
}
- (void)reloadData {
    [self reloadDataAnimated:NO];
}
- (void)reloadDataAnimated:(BOOL)animated {
    [super reloadData];
    // Row rendering must not reread every APT source file/protection selector.
    // Actions below and the privileged commit still revalidate current state.
    editable_ = [CydiaReadSourceDisplayEditability(@[row_], access_) containsIndex:0];
    protected_ = DefinitionIsProtected(row_, CydiaReadSourceProtection());
    showsAdvanced_ = access_ == CydiaSources::Access::Ordinary && protected_ && ![row_ snapshot].readOnly;
    self.navigationItem.prompt = access_ == CydiaSources::Access::AdvancedSettings ? SourceUI(@"SOURCE_REPOSITORY_SETTINGS_ADVANCED") : nil;
    detailTitles_ = @[SourceUI(@"SOURCE_STATUS"), SourceUI(@"SOURCE_REPOSITORIES"), SourceUI(@"SOURCE_COMPONENTS"), SourceUI(@"SOURCE_DEFINITION_DETAILS")];
    detailValues_ = @[SourceUI(row_.enabled ? @"SOURCE_ENABLED" : @"SOURCE_DISABLED"),
        [[row_.uris arrayByAddingObjectsFromArray:row_.suites] componentsJoinedByString:@"\n"], [row_.components componentsJoinedByString:@" "], @""];
    actionTitles_ = @[UCLocalize("EDIT"), SourceUI(row_.enabled ? @"SOURCE_DISABLE" : @"SOURCE_ENABLE"), SourceUI(@"SOURCE_REMOVE")];
    if (animated) [table_ reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
    else [table_ reloadData];
}
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self;
    table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 60; self.view = table_;
    StyleSourceTable(table_, self.traitCollection);
}
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.title = DefinitionName(database_, row_); }
- (void)viewWillAppear:(BOOL)animated {
    const BOOL loaded([self hasLoaded]); [super viewWillAppear:animated];
    if (loaded) [self reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous { [super traitCollectionDidChange:previous]; if (SourceTraitsChanged(self.traitCollection, previous)) StyleSourceTable(table_, self.traitCollection); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4;
    if (showsAdvanced_) return 1;
    return editable_ ? 3 : 0;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 1 && [row_ snapshot].readOnly) return SourceUI(@"SOURCE_READ_ONLY_ALIAS");
    if (section == 1 && showsAdvanced_) return SourceUI(@"SOURCE_PROTECTED");
    if (section == 1 && !editable_ && access_ == CydiaSources::Access::AdvancedSettings) return SourceUI(@"SOURCE_ADVANCED_UNAVAILABLE");
    if (section == 1 && !editable_) return SourceUI(@"SOURCE_PROTECTED_OR_REVIEW");
    if (section == 1 && protected_) return SourceUI(@"SOURCE_BOOTSTRAP_CHANGE");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell(SourceSettingsCell(table));
    if (path.section == 0) {
        cell.textLabel.text = detailTitles_[path.row]; cell.detailTextLabel.text = detailValues_[path.row];
        if (path.row == 3) { cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.accessibilityTraits = UIAccessibilityTraitButton; }
        else { cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.accessibilityTraits = UIAccessibilityTraitStaticText; }
    } else {
        cell.textLabel.text = showsAdvanced_ ? SourceUI(@"SOURCE_REPOSITORY_SETTINGS_ADVANCED") : actionTitles_[path.row];
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        if (showsAdvanced_) {
            cell.accessibilityIdentifier = @"cydia.settings.repository.advanced";
            cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
        } else if (path.row == 2) cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleErrorLabel traitCollection:self.traitCollection];
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0 && path.row == 3) {
        CydiaSourceDefinitionDetailsController *controller([[CydiaSourceDefinitionDetailsController alloc] initWithRow:row_]);
        controller.delegate = self.delegate; [self.navigationController pushViewController:controller animated:YES]; return;
    }
    if (path.section != 1) return;
    if (showsAdvanced_) {
        // Advanced controls belong to this definition, not the global settings
        // tree. Keep the source and back destination while entering that mode.
        if (!DefinitionIsProtected(row_, CydiaReadSourceProtection())) {
            [self reloadData]; return;
        }
        if (!CydiaSourceDefinitionCanEdit(row_, CydiaSources::Access::AdvancedSettings)) {
            SourceMessage(self, SourceUI(@"SOURCE_ADVANCED_UNAVAILABLE")); [self reloadData]; return;
        }
        access_ = CydiaSources::Access::AdvancedSettings;
        [self reloadDataAnimated:YES]; return;
    }
    if (!CydiaSourceDefinitionCanEdit(row_, access_)) { SourceReviewRequired(self, database_); return; }
    if (path.row == 0) {
        [CydiaSourceAddController editDefinition:row_ database:database_ presenter:self access:access_];
        return;
    }
    CydiaSources::Mutation edit(path.row == 1 ? CydiaSources::EditKind::SetEnabled : CydiaSources::EditKind::RemoveDefinition);
    edit.ordinal = row_.ordinal; edit.enabled = !row_.enabled;
    NSString *action(path.row == 1 ? SourceUI(row_.enabled ? @"SOURCE_DISABLE" : @"SOURCE_ENABLE") : SourceUI(@"SOURCE_REMOVE"));
    __weak CydiaSourceDefinitionController *weakSelf(self);
    ReviewedSourceCommit(self, database_, [row_ snapshot], edit, access_, action, DefinitionSummary(row_), ^{
        [weakSelf.navigationController popViewControllerAnimated:YES];
    });
}
@end

@interface CydiaRepositorySettingsController () <UITableViewDataSource, UITableViewDelegate>
@end
@implementation CydiaRepositorySettingsController {
    Database *database_;
    UITableView *list_;
    NSArray<CydiaSourceDefinition *> *definitions_;
    NSArray<NSString *> *diagnostics_;
    CydiaSources::Access access_;
    NSArray<NSString *> *names_, *summaries_;
    BOOL editable_;
    BOOL protectionNeedsReview_;
}
- (id)initWithDatabase:(Database *)database advancedAccess:(BOOL)advancedAccess {
    if ((self = [super init]) != nil) {
        database_ = database; access_ = advancedAccess ? CydiaSources::Access::AdvancedSettings : CydiaSources::Access::Ordinary;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(runtimeStatusDidChange:)
            name:CydiaRuntimeProviderStatusDidChangeNotification object:database];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)runtimeStatusDidChange:(NSNotification *)notification {
    if (self.isViewLoaded && self.navigationController.topViewController == self) [self reloadData];
}
- (NSURL *)navigationURL { return nil; }
- (void)loadView {
    list_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    list_.dataSource = self; list_.delegate = self;
    list_.rowHeight = UITableViewAutomaticDimension; list_.estimatedRowHeight = 64;
    list_.accessibilityIdentifier = access_ == CydiaSources::Access::AdvancedSettings ? @"cydia.settings.protected-repositories" : @"cydia.settings.repositories"; self.view = list_;
    StyleSourceTable(list_, self.traitCollection);
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.navigationItem.title = access_ == CydiaSources::Access::AdvancedSettings ?
        [[NSBundle mainBundle] localizedStringForKey:@"PROTECTED_REPOSITORY_SETTINGS" value:nil table:@"Settings"] : SourceUI(@"SOURCE_REPOSITORY_SETTINGS");
    if (access_ == CydiaSources::Access::Ordinary)
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:UCLocalize("ADD") style:UIBarButtonItemStylePlain target:self action:@selector(showAddSourcePrompt)];
}
- (void)viewWillAppear:(BOOL)animated {
    const BOOL loaded([self hasLoaded]); [super viewWillAppear:animated];
    if (loaded) [self reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous { [super traitCollectionDidChange:previous]; if (SourceTraitsChanged(self.traitCollection, previous)) StyleSourceTable(list_, self.traitCollection); }
- (void)reloadData {
    [super reloadData]; NSArray<NSString *> *diagnostics(nil);
    definitions_ = CydiaReadSourceDefinitions(&diagnostics); diagnostics_ = diagnostics;
    if (access_ == CydiaSources::Access::AdvancedSettings) {
        const auto policy(CydiaReadSourceProtection());
        protectionNeedsReview_ = !policy.valid;
        for (const auto &selector : policy.selectors) {
            BOOL found(NO);
            for (CydiaSourceDefinition *row in definitions_) {
                const auto &definition([row definition]);
                if (selector.originPath == definition.path && selector.semanticKey == definition.semanticKey) { found = YES; break; }
            }
            if (!found) protectionNeedsReview_ = YES;
        }
        NSMutableArray *protectedDefinitions([NSMutableArray array]);
        for (CydiaSourceDefinition *row in definitions_)
            if (DefinitionIsProtected(row, policy)) [protectedDefinitions addObject:row];
        definitions_ = protectedDefinitions;
    }
    editable_ = CydiaCanEditSources(access_);
    self.navigationItem.rightBarButtonItem.enabled = editable_;
    NSMutableArray *names([NSMutableArray arrayWithCapacity:definitions_.count]);
    NSMutableArray *summaries([NSMutableArray arrayWithCapacity:definitions_.count]);
    for (CydiaSourceDefinition *row in definitions_) {
        NSString *name(DefinitionName(database_, row)); [names addObject:name];
        NSString *uris([row.uris componentsJoinedByString:@", "]);
        NSMutableArray *summary([NSMutableArray arrayWithObject:SourceUI(row.enabled ? @"SOURCE_ENABLED" : @"SOURCE_DISABLED")]);
        if (uris.length && ![name isEqual:uris]) [summary addObject:uris];
        if (row.suites.count) [summary addObject:[row.suites componentsJoinedByString:@", "]];
        [summaries addObject:[summary componentsJoinedByString:@" · "]];
    }
    names_ = names; summaries_ = summaries;
    [list_ reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 ? definitions_.count : diagnostics_.count; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 1 && diagnostics_.count != 0 ? SourceUI(@"SOURCE_FILE_ERRORS") : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 0 && access_ == CydiaSources::Access::AdvancedSettings) {
        NSMutableArray *messages([NSMutableArray array]);
        if (protectionNeedsReview_) [messages addObject:SourceUI(@"SOURCE_PROTECTION_REVIEW_REQUIRED")];
        else if (!editable_) [messages addObject:SourceUI(@"SOURCE_ADVANCED_UNAVAILABLE")];
        else if (definitions_.count == 0 && diagnostics_.count == 0) [messages addObject:SourceUI(@"SOURCE_NO_PROTECTED_SOURCES")];
        [messages addObject:SourceUI(@"SOURCE_PROTECTED_SETTINGS_HELP")];
        return [messages componentsJoinedByString:@"\n\n"];
    }
    return section == 0 && !editable_ ? SourceUI(@"SOURCE_PROTECTED_OR_REVIEW") : nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell(SourceSettingsCell(table));
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    if (path.section == 0) {
        cell.textLabel.text = names_[path.row];
        cell.detailTextLabel.text = summaries_[path.row];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.settings.repository.%lu", (unsigned long)path.row];
    } else {
        cell.textLabel.text = SourceUI(@"SOURCE_FILE_UNAVAILABLE");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1) {
        CydiaSourceDefinitionDetailsController *controller([[CydiaSourceDefinitionDetailsController alloc] initWithDiagnostic:diagnostics_[path.row]]);
        controller.delegate = self.delegate; [self.navigationController pushViewController:controller animated:YES]; return;
    }
    CydiaSourceDefinitionController *controller([[CydiaSourceDefinitionController alloc] initWithDatabase:database_ row:definitions_[path.row] access:access_]);
    controller.delegate = self.delegate; [self.navigationController pushViewController:controller animated:YES];
}
- (void)showAddSourcePrompt {
    if (!CydiaCanEditSources(access_)) { SourceReviewRequired(self, database_); return; }
    [CydiaSourceAddController showAdvancedWithDatabase:database_ presenter:self URL:@"https://" access:access_];
}
- (void)showAddSourceDefinitionPrompt:(NSString *)draft {
    [CydiaSourceAddController showDefinition:draft database:database_ presenter:self access:access_];
}

@end

@protocol SourcesControllerApplicationDelegate <CydiaDelegate, NSObject>
- (CydiaLegacyUICompatibilityNativeSession *)legacyUICompatibilitySessionForSource:(Source *)source presenter:(id)presenter;
@end
@interface SourcesController () <UITableViewDataSource, UITableViewDelegate>
@end
@implementation SourcesController {
    __weak Database *database_;
    unsigned era_;
    _H<UITableView, 2> list_;
    _H<NSMutableArray> sources_;
    NSArray<CydiaSourceDefinition *> *definitions_;
    NSArray<NSString *> *sourceDiagnostics_;
    NSIndexSet *editableSourceIndexes_;
    BOOL appeared_, pendingAddPrompt_;
    NSString *pendingAddDefinition_;
    __strong CydiaLegacyUICompatibilityNativeSession *legacyCompatibilitySession_;
}
- (void) invalidateLegacyCompatibilitySession {
    [legacyCompatibilitySession_ invalidate];
    legacyCompatibilitySession_ = nil;
}

- (BOOL) sourceIsCanonical:(Source *)source {
    BOOL exactSource(object_getClass(source) == [Source class]);
    if (database_ == nil || !exactSource)
        return NO;
    @synchronized (database_) {
        if ([database_ era] != era_)
            return NO;
        for (id candidate in [database_ sources])
            if (candidate == source)
                return YES;
    }
    return NO;
}

- (void) bindLegacyCompatibilitySessionForSource:(Source *)source {
    id delegate([self delegate]);
    NSString *sourceKey([source key]);
    BOOL validKey([sourceKey isKindOfClass:[NSString class]] &&
        [sourceKey length] != 0 &&
        [sourceKey rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound);
    if (!validKey || ![self sourceIsCanonical:source] || delegate == nil ||
        ![delegate respondsToSelector:@selector(
            legacyUICompatibilitySessionForSource:presenter:)]) {
        [self invalidateLegacyCompatibilitySession];
        return;
    }

    if (legacyCompatibilitySession_ != nil &&
        [legacyCompatibilitySession_ isActive] &&
        [legacyCompatibilitySession_ target] == source &&
        [[legacyCompatibilitySession_ sourceKey] isEqualToString:sourceKey])
        return;

    [self invalidateLegacyCompatibilitySession];
    CydiaLegacyUICompatibilityNativeSession *session(
        [(id<SourcesControllerApplicationDelegate>)delegate
            legacyUICompatibilitySessionForSource:source presenter:nil]);
    if (session == nil || ![session isActive] || [session target] != source) {
        [session invalidate];
        return;
    }

    id identity([session invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    if (![identity isKindOfClass:[NSString class]] ||
        ![identity isEqualToString:sourceKey] ||
        ![[session sourceKey] isEqualToString:sourceKey]) {
        [session invalidate];
        return;
    }
    legacyCompatibilitySession_ = session;
}

- (NSDictionary *) cydiaNativeCompatibilitySourceSessionDiagnosticWithDelegate:(id)delegate {
    Source *source(nil);
    for (id candidate in [database_ sources])
        if (object_getClass(candidate) == [Source class]) {
            source = (Source *)candidate;
            break;
        }
    if (source == nil || delegate == nil ||
        ![delegate respondsToSelector:@selector(
            legacyUICompatibilitySessionForSource:presenter:)])
        return @{
            @"sourceControllerCaller": NSStringFromClass([self class]),
            @"sourceControllerTarget": @NO,
            @"sourceControllerTypedRead": @NO,
            @"sourceControllerRetained": @NO,
            @"sourceControllerReloadInvalidationDenied": @NO,
            @"sourceControllerDisappearanceInvalidationDenied": @NO,
            @"sourceControllerDeallocInvalidationDenied": @NO,
        };

    SourcesController *controller([[SourcesController alloc] initWithDatabase:database_]);
    [controller setDelegate:delegate];
    [controller reloadData];
    [controller bindLegacyCompatibilitySessionForSource:source];
    CydiaLegacyUICompatibilityNativeSession *initialSession(
        controller->legacyCompatibilitySession_);
    id initialKey([initialSession invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    BOOL initialRead([initialKey isKindOfClass:[NSString class]] &&
        [initialKey isEqualToString:[source key]]);
    BOOL retained(initialSession != nil && [initialSession isActive] &&
        [initialSession target] == source);

    [controller reloadData];
    id reloadedKey([initialSession invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    BOOL reloadInvalidationDenied(![initialSession isActive] &&
        reloadedKey == [CydiaLegacyUIUndefinedValue value] &&
        [initialSession lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability);

    CydiaLegacyUICompatibilityNativeSession *reboundSession(
        controller->legacyCompatibilitySession_);
    [controller bindLegacyCompatibilitySessionForSource:nil];
    id disappearedKey([reboundSession invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    BOOL disappearanceInvalidationDenied(reboundSession != nil &&
        ![reboundSession isActive] &&
        disappearedKey == [CydiaLegacyUIUndefinedValue value] &&
        [reboundSession lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability);

    /* Keep the lifetime probe in its own scope.  ARC may otherwise extend a
     * strong Objective-C++ local through the rest of this diagnostic method,
     * making the weak check observe the probe's own compiler lifetime rather
     * than the controller's actual teardown.  Explicitly invalidate the
     * session and view before the scope ends, then inspect only the weak
     * identity and the caller-retained session. */
    __weak SourcesController *weakController(nil);
    CydiaLegacyUICompatibilityNativeSession *deallocSession(nil);
    @autoreleasepool {
        SourcesController *probe([[SourcesController alloc]
            initWithDatabase:database_]);
        probe->era_ = [database_ era];
        [probe setDelegate:delegate];
        [probe bindLegacyCompatibilitySessionForSource:source];
        deallocSession = probe->legacyCompatibilitySession_;
        weakController = probe;
        [probe setDelegate:nil];
        [probe invalidateLegacyCompatibilitySession];
        [probe setView:nil];
        probe = nil;
    }
    BOOL controllerDeallocated(weakController == nil);
    id deallocatedKey([deallocSession invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    BOOL deallocInvalidationDenied(controllerDeallocated && deallocSession != nil &&
        ![deallocSession isActive] &&
        deallocatedKey == [CydiaLegacyUIUndefinedValue value] &&
        [deallocSession lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability);

    return @{
        @"sourceControllerCaller": NSStringFromClass([self class]),
        @"sourceControllerTarget": @YES,
        @"sourceControllerTypedRead": @(initialRead),
        @"sourceControllerRetained": @(retained),
        @"sourceControllerReloadInvalidationDenied": @(reloadInvalidationDenied),
        @"sourceControllerDisappearanceInvalidationDenied": @(disappearanceInvalidationDenied),
        @"sourceControllerDeallocInvalidationDenied": @(deallocInvalidationDenied),
        @"sourceControllerDeallocControllerDeallocated": @(controllerDeallocated),
        @"sourceControllerDeallocSessionAvailable": @(deallocSession != nil),
        @"sourceControllerDeallocSessionActive": @(
            deallocSession != nil && [deallocSession isActive]),
        @"sourceControllerDeallocUndefinedRead": @(
            deallocatedKey == [CydiaLegacyUIUndefinedValue value]),
        @"sourceControllerDeallocDenialReason": @(deallocSession == nil ?
            CydiaLegacyUICompatibilityNativeDenialReasonNone :
            [deallocSession lastDenialReason]),
    };
}


- (void)dealloc { [self invalidateLegacyCompatibilitySession]; }
- (NSURL *)navigationURL { return [NSURL URLWithString:@"cydia://sources"]; }
- (id)initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) database_ = database;
    return self;
}
- (void)loadView {
    list_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    [list_ setDataSource:self]; [list_ setDelegate:self]; [list_ setRowHeight:53];
    if ([list_ respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)]) [list_ setCellLayoutMarginsFollowReadableWidth:NO];
    self.view = list_;
}
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.title = UCLocalize("SOURCES"); }
- (void)viewWillAppear:(BOOL)animated {
    const BOOL loaded([self hasLoaded]); [super viewWillAppear:animated]; [list_ setEditing:NO];
    if (loaded) [self reloadData];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated]; appeared_ = YES;
    [list_ deselectRowAtIndexPath:[list_ indexPathForSelectedRow] animated:animated];
    NSString *draft(pendingAddDefinition_); BOOL prompt(pendingAddPrompt_);
    pendingAddDefinition_ = nil; pendingAddPrompt_ = NO;
    if (draft != nil) [self showAddSourceDefinitionPrompt:draft];
    else if (prompt) [self showAddSourcePrompt];
}
- (void)viewWillDisappear:(BOOL)animated { appeared_ = NO; [super viewWillDisappear:animated]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self invalidateLegacyCompatibilitySession]; }
- (void)releaseSubviews { list_ = nil; sources_ = nil; definitions_ = nil; sourceDiagnostics_ = nil; editableSourceIndexes_ = nil; [super releaseSubviews]; }
- (NSInteger)sourceSection { return sourceDiagnostics_.count == 0 ? 1 : 2; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return [self sourceSection] + 1; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (sourceDiagnostics_.count != 0 && section == 0) return 2;
    return section == [self sourceSection] ? [sources_ count] : 1;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    if (sourceDiagnostics_.count != 0 && section == 0) return SourceUI(@"SOURCE_FILE_ERRORS");
    return section == [self sourceSection] ? UCLocalize("INDIVIDUAL_SOURCES") : nil;
}
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return sourceDiagnostics_.count != 0 && path.section == 0 ? UITableViewAutomaticDimension : 53;
}
- (CGFloat)tableView:(UITableView *)table estimatedHeightForRowAtIndexPath:(NSIndexPath *)path {
    return sourceDiagnostics_.count != 0 && path.section == 0 && path.row == 0 ? 100 : 53;
}
- (Source *)sourceAtIndexPath:(NSIndexPath *)path {
    @synchronized (database_) {
        if ([database_ era] != era_ || path.section != [self sourceSection] || path.row >= [sources_ count]) return nil;
        return [sources_ objectAtIndex:path.row];
    }
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (sourceDiagnostics_.count != 0 && path.section == 0) {
        UITableViewCell *cell([table dequeueReusableCellWithIdentifier:@"SourceFailureCell"]);
        if (cell == nil) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SourceFailureCell"];
        StyleSourceCell(cell);
        cell.textLabel.text = path.row == 0 ? SourceUI(@"SOURCE_FILE_ERRORS") : SourceUI(@"SOURCE_REPOSITORY_SETTINGS");
        cell.detailTextLabel.text = path.row == 0 ? SourceUI(@"SOURCE_FILE_UNAVAILABLE") : nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    SourceCell *cell((SourceCell *)[table dequeueReusableCellWithIdentifier:@"SourceCell"]);
    if (cell == nil) cell = [[SourceCell alloc] initWithFrame:CGRectZero reuseIdentifier:@"SourceCell"];
    Source *source([self sourceAtIndexPath:path]);
    if (source == nil) [cell setAllSource]; else [cell setSource:source];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    if (sourceDiagnostics_.count != 0 && path.section == 0) {
        CyteViewController *controller;
        if (path.row == 0)
            controller = [[CydiaSourceDefinitionDetailsController alloc] initWithDiagnostic:[sourceDiagnostics_ componentsJoinedByString:@"\n\n"]];
        else
            controller = [[CydiaRepositorySettingsController alloc] initWithDatabase:database_ advancedAccess:NO];
        controller.delegate = self.delegate; [self.navigationController pushViewController:controller animated:YES];
        return;
    }
    Source *source([self sourceAtIndexPath:path]);
    if (path.section == [self sourceSection] && source == nil) { SourceMessage(self, SourceUI(@"SOURCE_RELOAD_REQUIRED")); [self reloadData]; return; }
    [self bindLegacyCompatibilitySessionForSource:source];
    SectionsController *controller([[SectionsController alloc] initWithDatabase:database_ source:source]);
    controller.delegate = self.delegate; [self.navigationController pushViewController:controller animated:YES];
}
- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    return [self sourceAtIndexPath:path] != nil && [editableSourceIndexes_ containsIndex:path.row];
}
- (void)removeDefinition:(CydiaSourceDefinition *)row {
    if (!CydiaSourceDefinitionCanEdit(row, CydiaSources::Access::Ordinary)) { SourceReviewRequired(self, database_); return; }
    CydiaSources::Mutation edit(CydiaSources::EditKind::RemoveDefinition); edit.ordinal = row.ordinal;
    __weak SourcesController *weakSelf(self);
    ReviewedSourceCommit(self, database_, [row snapshot], edit, CydiaSources::Access::Ordinary,
        SourceUI(@"SOURCE_REMOVE"), DefinitionScope(row), ^{ [weakSelf reloadData]; });
}
- (void)tableView:(UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete) return;
    Source *source([self sourceAtIndexPath:path]);
    if (source == nil) { SourceMessage(self, SourceUI(@"SOURCE_RELOAD_REQUIRED")); return; }
    NSArray<CydiaSourceDefinition *> *rows(DefinitionsForSource(CydiaReadSourceDefinitions(), source));
    if (rows.count == 1) { [self removeDefinition:rows.firstObject]; return; }
    NSMutableSet *scopes([NSMutableSet set]); BOOL ambiguous(NO);
    for (CydiaSourceDefinition *row in rows) {
        NSString *scope([NSString stringWithFormat:@"%@\n%@", SourceUI(row.enabled ? @"SOURCE_ENABLED" : @"SOURCE_DISABLED"), DefinitionScope(row)]);
        if ([scopes containsObject:scope]) ambiguous = YES;
        [scopes addObject:scope];
    }
    if (rows.count == 0 || ambiguous) {
        UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("SOURCES") message:SourceUI(@"SOURCE_DELETE_UNAVAILABLE") preferredStyle:UIAlertControllerStyleAlert]);
        [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:SourceUI(@"SOURCE_REPOSITORY_SETTINGS") style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
            CydiaRepositorySettingsController *controller([[CydiaRepositorySettingsController alloc] initWithDatabase:database_ advancedAccess:NO]);
            controller.delegate = self.delegate; [self.navigationController pushViewController:controller animated:YES];
        }]];
        [self presentViewController:alert animated:YES completion:nil]; return;
    }
    UIAlertController *chooser([UIAlertController alertControllerWithTitle:SourceUI(@"SOURCE_REMOVE") message:SourceUI(@"SOURCE_DELETE_CHOOSE_DEFINITION") preferredStyle:UIAlertControllerStyleActionSheet]);
    for (CydiaSourceDefinition *row in rows) {
        UIAlertAction *action([UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@\n%@", SourceUI(row.enabled ? @"SOURCE_ENABLED" : @"SOURCE_DISABLED"), DefinitionScope(row)]
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *) { [self removeDefinition:row]; }]);
        action.enabled = CydiaSourceDefinitionCanEdit(row, CydiaSources::Access::Ordinary); [chooser addAction:action];
    }
    [chooser addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    chooser.popoverPresentationController.sourceView = list_;
    chooser.popoverPresentationController.sourceRect = [table rectForRowAtIndexPath:path];
    [self presentViewController:chooser animated:YES completion:nil];
}
- (void)tableView:(UITableView *)table didEndEditingRowAtIndexPath:(NSIndexPath *)path { [self updateButtonsForEditingStatusAnimated:YES]; }
- (void)reloadData {
    NSString *key([legacyCompatibilitySession_ sourceKey]); [self invalidateLegacyCompatibilitySession]; [super reloadData];
    BOOL sourceLoadFailed(NO); NSString *sourceLoadDiagnostic(nil);
    @synchronized (database_) {
        era_ = [database_ era]; sources_ = [[database_ sources] mutableCopy];
        [sources_ sortUsingSelector:@selector(compareByName:)];
        sourceLoadFailed = [database_ sourceLoadFailed]; sourceLoadDiagnostic = [database_ sourceLoadDiagnostic];
    }
    NSArray<NSString *> *documentDiagnostics(nil);
    definitions_ = CydiaReadSourceDefinitions(&documentDiagnostics);
    NSIndexSet *editableDefinitions(CydiaReadSourceDisplayEditability(definitions_));
    NSMutableIndexSet *editableSources([NSMutableIndexSet indexSet]);
    @synchronized (database_) {
        if ([database_ era] == era_) {
            for (NSUInteger sourceIndex = 0; sourceIndex != [sources_ count]; ++sourceIndex)
                for (NSUInteger index = editableDefinitions.firstIndex; index != NSNotFound; index = [editableDefinitions indexGreaterThanIndex:index])
                    if (DefinitionMatchesSource(definitions_[index], [sources_ objectAtIndex:sourceIndex])) {
                        [editableSources addIndex:sourceIndex]; break;
                    }
        }
    }
    editableSourceIndexes_ = editableSources;
    NSMutableArray<NSString *> *diagnostics([documentDiagnostics mutableCopy]);
    if (sourceLoadFailed)
        [diagnostics addObject:sourceLoadDiagnostic.length != 0 ? sourceLoadDiagnostic : SourceUI(@"SOURCE_FILE_UNAVAILABLE")];
    sourceDiagnostics_ = diagnostics;
    [list_ reloadData]; [self updateButtonsForEditingStatusAnimated:NO];
    if (key != nil) for (Source *source in (NSArray *)sources_) if ([[source key] isEqual:key]) { [self bindLegacyCompatibilitySessionForSource:source]; break; }
}
- (void)updateButtonsForEditingStatusAnimated:(BOOL)animated {
    id<CydiaDelegate, NSObject> delegate((id)[self delegate]); BOOL updating([delegate respondsToSelector:@selector(updating)] && [delegate updating]);
    const BOOL editable(CydiaCanEditSources(CydiaSources::Access::Ordinary) && !updating);
    if (!editable) [list_ setEditing:NO animated:animated];
    const BOOL editing([list_ isEditing]);
    UIBarButtonItem *left([[UIBarButtonItem alloc] initWithTitle:editing ? UCLocalize("ADD") : updating ? UCLocalize("CANCEL") : UCLocalize("REFRESH")
        style:updating ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain target:self
        action:editing ? @selector(showAddSourcePrompt) : updating ? @selector(cancelButtonClicked) : @selector(refreshButtonClicked)]);
    UIBarButtonItem *edit([[UIBarButtonItem alloc] initWithTitle:editing ? UCLocalize("DONE") : UCLocalize("EDIT")
        style:editing ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain target:self action:@selector(editButtonClicked)]);
    edit.enabled = editable;
    self.navigationItem.rightBarButtonItems = nil;
    [self.navigationItem setLeftBarButtonItem:left animated:animated]; [self.navigationItem setRightBarButtonItem:edit animated:animated];
}
- (void)editButtonClicked {
    if (!CydiaCanEditSources(CydiaSources::Access::Ordinary)) { SourceReviewRequired(self, database_); return; }
    [list_ setEditing:![list_ isEditing] animated:YES]; [self updateButtonsForEditingStatusAnimated:YES];
}
- (void)refreshButtonClicked { if ([(id<CydiaDelegate>)self.delegate requestUpdate]) [self updateButtonsForEditingStatusAnimated:YES]; }
- (void)cancelButtonClicked { [(id<CydiaDelegate>)self.delegate cancelUpdate]; [self updateButtonsForEditingStatusAnimated:YES]; }
- (void)showAddSourcePrompt {
    if (!appeared_ || self.presentedViewController != nil) { pendingAddPrompt_ = YES; pendingAddDefinition_ = nil; return; }
    if (!CydiaCanEditSources(CydiaSources::Access::Ordinary)) { SourceReviewRequired(self, database_); return; }
    [CydiaSourceAddController showURLPromptWithDatabase:database_ presenter:self URL:nil];
}
- (void)showAddSourceDefinitionPrompt:(NSString *)draft {
    if (!appeared_ || self.presentedViewController != nil) { pendingAddDefinition_ = [draft copy]; pendingAddPrompt_ = NO; return; }
    [CydiaSourceAddController showDefinition:draft database:database_ presenter:self access:CydiaSources::Access::Ordinary];
}
// Retired catalogue entry point: callers cannot resurrect assumed repositories.
- (void)showRestoreDefaultSourcePrompt:(NSString *)identifier completion:(void (^)(BOOL))completion { if (completion != nil) completion(NO); }
- (void)cancelDefaultSourceRestoration {}
@end
