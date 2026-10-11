/* Copyright (C) 2008-2017 Jay Freeman; Modified work Copyright (C) 2026 Torrekie.
 * SPDX-License-Identifier: GPL-3.0-or-later */
#include "CyteKit/UCPlatform.h"
#import "Cydia/SourceControllers.h"
#import "Cydia/Appearance.h"
#import "Cydia/CydiaDelegate.h"
#import "Cydia/Database.h"
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

/* Source Cell {{{ */
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
    source_ = nil;
    [indicator_ stopAnimating];

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
    if ([fetch boolValue])
        [indicator_ startAnimating];
    else
        [indicator_ stopAnimating];
}

@end
/* }}} */

@interface CydiaSourceDefinitionEditor : CyteViewController <UITextViewDelegate>
- (instancetype)initWithDatabase:(Database *)database expected:(const CydiaSources::StoredDocument &)expected
                            row:(CydiaSourceDefinition *)row contents:(NSString *)contents access:(CydiaSources::Access)access;
@property(nonatomic, copy) void (^saved)(void);
@end
@implementation CydiaSourceDefinitionEditor {
    Database *database_;
    CydiaSources::StoredDocument expected_;
    CydiaSources::Access access_;
    CydiaSourceDefinition *row_;
    NSString *contents_;
    UITextView *text_;
}
- (instancetype)initWithDatabase:(Database *)database expected:(const CydiaSources::StoredDocument &)expected
                            row:(CydiaSourceDefinition *)row contents:(NSString *)contents access:(CydiaSources::Access)access {
    if ((self = [super init]) != nil) { database_ = database; expected_ = expected; row_ = row; contents_ = [contents copy]; access_ = access; }
    return self;
}
- (void)loadView {
    UIView *view([[UIView alloc] initWithFrame:CGRectZero]);
    view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:self.traitCollection];
    UILabel *location([[UILabel alloc] init]); location.numberOfLines = 0;
    location.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    location.adjustsFontForContentSizeCategory = YES;
    location.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
    location.text = [NSString stringWithFormat:@"%@\n%@", [NSString stringWithUTF8String:expected_.document.path.c_str()], SourceUI(@"SOURCE_EDITOR_EXPLANATION")];
    text_ = [[UITextView alloc] init]; text_.delegate = self;
    UIFont *editorFont([UIFont fontWithName:@"Menlo" size:16]);
    text_.font = editorFont != nil ? [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:editorFont] : [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text_.adjustsFontForContentSizeCategory = YES;
    text_.autocorrectionType = UITextAutocorrectionTypeNo; text_.autocapitalizationType = UITextAutocapitalizationTypeNone;
    text_.smartQuotesType = UITextSmartQuotesTypeNo; text_.smartDashesType = UITextSmartDashesTypeNo;
    text_.text = contents_ ?: @""; text_.accessibilityIdentifier = @"cydia.sources.definition";
    text_.backgroundColor = view.backgroundColor;
    text_.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    UIStackView *stack([[UIStackView alloc] initWithArrangedSubviews:@[location, text_]]);
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor constant:-12]]];
    self.view = view;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = row_ == nil ? UCLocalize("ADD_SOURCE") : UCLocalize("EDIT");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:SourceUI(@"SOURCE_SAVE")
        style:UIBarButtonItemStyleDone target:self action:@selector(saveDefinition)];
}
- (void)saveDefinition {
    if (!CydiaCanEditSources(access_)) { SourceReviewRequired(self, database_); return; }
    CydiaSources::Mutation edit(row_ == nil ? CydiaSources::EditKind::AppendDefinition : CydiaSources::EditKind::ReplaceDefinition);
    edit.ordinal = row_ == nil ? 0 : row_.ordinal;
    edit.contents = [text_.text UTF8String] ?: "";
    const auto parsed(CydiaSources::ParseDocument(expected_.document.path, expected_.document.format, edit.contents));
    if (!parsed.valid() || parsed.definitions.size() != 1) { SourceMessage(self, SourceUI(@"SOURCE_DEFINITION_INVALID")); return; }
    CydiaSources::StoredDocument replacement; replacement.document = parsed;
    CydiaSourceDefinition *row([[CydiaSourceDefinition alloc] initWithSnapshot:replacement ordinal:0]);
    NSString *summary([NSString stringWithFormat:@"%@\n%@%@\n%@", [NSString stringWithUTF8String:expected_.document.path.c_str()],
        row_ == nil ? @"" : [NSString stringWithFormat:@"%@\n↓\n", row_.original ?: @""],
        row.original ?: @"", SourceUI(@"SOURCE_WHOLE_DEFINITION")]);
    __weak CydiaSourceDefinitionEditor *weakSelf(self);
    ReviewedSourceCommit(self, database_, expected_, edit, access_, SourceUI(@"SOURCE_SAVE"), summary, ^{
        CydiaSourceDefinitionEditor *strongSelf(weakSelf);
        [strongSelf.navigationController popViewControllerAnimated:NO];
        if (strongSelf.saved != nil) strongSelf.saved();
    });
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
    NSArray<Source *> *browsable_;
}
- (instancetype)initWithDatabase:(Database *)database row:(CydiaSourceDefinition *)row access:(CydiaSources::Access)access {
    if ((self = [super init]) != nil) { database_ = database; row_ = row; access_ = access; }
    return self;
}
- (void)reloadData {
    [super reloadData];
    NSMutableArray *browse([NSMutableArray array]);
    @synchronized (database_) {
        for (Source *source in [database_ sources]) {
            NSString *uri([[source rooturi] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]);
            for (NSString *candidate in row_.uris)
                if ([uri isEqual:[candidate stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]] &&
                    [row_.suites containsObject:[source distribution]]) {
                    if (![browse containsObject:source]) [browse addObject:source];
                }
        }
    }
    browsable_ = browse; [table_ reloadData];
}
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self;
    table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 60; self.view = table_;
}
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.title = UCLocalize("SOURCES"); [self reloadData]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 4 : section == 1 ? browsable_.count : 4;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? SourceUI(@"SOURCE_DEFINITION") : section == 1 ? SourceUI(@"SOURCE_BROWSE_PACKAGES") : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 1 && browsable_.count == 0) return SourceUI(@"SOURCE_INDEX_UNAVAILABLE");
    if (section == 2 && !CydiaSourceDefinitionCanEdit(row_, access_)) return SourceUI(@"SOURCE_PROTECTED_OR_REVIEW");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]);
    StyleSourceCell(cell);
    if (path.section == 0) {
        NSArray *titles(@[SourceUI(@"SOURCE_LOCATION"), SourceUI(@"SOURCE_STATUS"), SourceUI(@"SOURCE_REPOSITORIES"), SourceUI(@"SOURCE_DEFINITION")]);
        NSArray *values(@[[NSString stringWithFormat:@"%@:%lu", row_.filePath, (unsigned long)row_.lineNumber],
            SourceUI(row_.enabled ? @"SOURCE_ENABLED" : @"SOURCE_DISABLED"),
            [[row_.uris arrayByAddingObjectsFromArray:row_.suites] componentsJoinedByString:@"\n"], row_.original ?: @""]);
        cell.textLabel.text = titles[path.row]; cell.detailTextLabel.text = values[path.row];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 1) {
        Source *source(browsable_[path.row]); cell.textLabel.text = [source name];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ %@", [source rooturi], [source distribution]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSArray *titles(@[UCLocalize("EDIT"), SourceUI(row_.enabled ? @"SOURCE_DISABLE" : @"SOURCE_ENABLE"), UCLocalize("REMOVE"), SourceUI(@"SOURCE_ADVANCED_SETTINGS")]);
        cell.textLabel.text = titles[path.row]; cell.accessibilityTraits |= UIAccessibilityTraitButton;
        if (path.row < 3 && !CydiaSourceDefinitionCanEdit(row_, access_)) {
            cell.textLabel.enabled = NO; cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        if (path.row == 3) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1) {
        Source *source(browsable_[path.row]);
        if (![[database_ sources] containsObject:source]) { SourceMessage(self, SourceUI(@"SOURCE_RELOAD_REQUIRED")); return; }
        SectionsController *controller([[SectionsController alloc] initWithDatabase:database_ source:source]);
        [controller setDelegate:self.delegate]; [self.navigationController pushViewController:controller animated:YES]; return;
    }
    if (path.section != 2) return;
    if (path.row == 3) { SourceSettings(self, database_); return; }
    if (!CydiaSourceDefinitionCanEdit(row_, access_)) { SourceReviewRequired(self, database_); return; }
    if (path.row == 0) {
        CydiaSourceDefinitionEditor *editor([[CydiaSourceDefinitionEditor alloc] initWithDatabase:database_ expected:[row_ snapshot] row:row_ contents:row_.original access:access_]);
        [editor setDelegate:self.delegate]; __weak CydiaSourceDefinitionController *weakSelf(self);
        editor.saved = ^{ [weakSelf.navigationController popViewControllerAnimated:YES]; };
        [self.navigationController pushViewController:editor animated:YES]; return;
    }
    CydiaSources::Mutation edit(path.row == 1 ? CydiaSources::EditKind::SetEnabled : CydiaSources::EditKind::RemoveDefinition);
    edit.ordinal = row_.ordinal; edit.enabled = !row_.enabled;
    NSString *action(path.row == 1 ? SourceUI(row_.enabled ? @"SOURCE_DISABLE" : @"SOURCE_ENABLE") : UCLocalize("REMOVE"));
    __weak CydiaSourceDefinitionController *weakSelf(self);
    ReviewedSourceCommit(self, database_, [row_ snapshot], edit, access_, action, DefinitionSummary(row_), ^{
        [weakSelf.navigationController popViewControllerAnimated:YES];
    });
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
    CydiaSources::Access access_;
    NSArray<NSString *> *diagnostics_;
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
- (NSURL *)navigationURL { return access_ == CydiaSources::Access::AdvancedSettings ? nil : [NSURL URLWithString:@"cydia://sources"]; }
- (id)initWithDatabase:(Database *)database { return [self initWithDatabase:database advancedAccess:NO]; }
- (id)initWithDatabase:(Database *)database advancedAccess:(BOOL)advancedAccess {
    if ((self = [super init]) != nil) {
        database_ = database;
        access_ = advancedAccess ? CydiaSources::Access::AdvancedSettings : CydiaSources::Access::Ordinary;
    }
    return self;
}
- (void)loadView {
    list_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    [list_ setDataSource:self]; [list_ setDelegate:self];
    [(UITableView *)list_ setRowHeight:UITableViewAutomaticDimension]; [(UITableView *)list_ setEstimatedRowHeight:64]; self.view = list_;
}
- (void)viewDidLoad { [super viewDidLoad]; self.navigationItem.title = UCLocalize("SOURCES"); [self reloadData]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadData]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self invalidateLegacyCompatibilitySession]; }
- (void)releaseSubviews { list_ = nil; sources_ = nil; definitions_ = nil; diagnostics_ = nil; [super releaseSubviews]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    return path.section == 0 ? 53 : UITableViewAutomaticDimension;
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : section == 1 ? definitions_.count : diagnostics_.count;
}
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? SourceUI(@"SOURCE_DEFINITIONS") : section == 2 && diagnostics_.count != 0 ? SourceUI(@"SOURCE_FILE_ERRORS") : nil;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return section == 1 ? (CydiaCanEditSources(access_) ? SourceUI(@"SOURCE_DEFINITIONS_EXPLANATION") : SourceUI(@"SOURCE_PROTECTED_OR_REVIEW")) : nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == 0) {
        SourceCell *cell([[SourceCell alloc] initWithFrame:CGRectZero reuseIdentifier:nil]);
        [cell setAllSource]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
    }
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]);
    StyleSourceCell(cell);
    if (path.section == 1) {
        CydiaSourceDefinition *row(definitions_[path.row]);
        cell.textLabel.text = [row.uris componentsJoinedByString:@", "];
        if (cell.textLabel.text.length == 0) cell.textLabel.text = SourceUI(@"SOURCE_DISABLED_TEMPLATE");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@:%lu\n%@", SourceUI(row.enabled ? @"SOURCE_ENABLED" : @"SOURCE_DISABLED"),
            row.filePath.lastPathComponent, (unsigned long)row.lineNumber, [row.suites componentsJoinedByString:@" "]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.sources.definition.%lu", (unsigned long)path.row];
    } else {
        cell.textLabel.text = SourceUI(@"SOURCE_FILE_UNAVAILABLE"); cell.detailTextLabel.text = diagnostics_[path.row];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0) {
        SectionsController *controller([[SectionsController alloc] initWithDatabase:database_ source:nil]);
        [controller setDelegate:self.delegate]; [self.navigationController pushViewController:controller animated:YES];
    } else if (path.section == 1) {
        CydiaSourceDefinitionController *controller([[CydiaSourceDefinitionController alloc] initWithDatabase:database_ row:definitions_[path.row] access:access_]);
        [controller setDelegate:self.delegate]; [self.navigationController pushViewController:controller animated:YES];
    }
}
- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    return path.section == 1 && CydiaSourceDefinitionCanEdit(definitions_[path.row], access_);
}
- (void)tableView:(UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete || path.section != 1) return;
    CydiaSourceDefinition *row(definitions_[path.row]);
    CydiaSources::Mutation edit(CydiaSources::EditKind::RemoveDefinition); edit.ordinal = row.ordinal;
    __weak SourcesController *weakSelf(self);
    ReviewedSourceCommit(self, database_, [row snapshot], edit, access_, UCLocalize("REMOVE"), DefinitionSummary(row), ^{ [weakSelf reloadData]; });
}
- (void)reloadData {
    NSString *key([legacyCompatibilitySession_ sourceKey]); [self invalidateLegacyCompatibilitySession]; [super reloadData];
    @synchronized (database_) { era_ = [database_ era]; sources_ = [[database_ sources] mutableCopy]; }
    NSArray<NSString *> *diagnostics(nil);
    definitions_ = CydiaReadSourceDefinitions(&diagnostics); diagnostics_ = diagnostics;
    [list_ reloadData]; [self updateButtonsForEditingStatusAnimated:NO];
    if (key != nil) for (Source *source in (NSArray *)sources_) if ([[source key] isEqual:key]) { [self bindLegacyCompatibilitySessionForSource:source]; break; }
}
- (void)updateButtonsForEditingStatusAnimated:(BOOL)animated {
    id<CydiaDelegate, NSObject> delegate((id)[self delegate]); BOOL updating([delegate respondsToSelector:@selector(updating)] && [delegate updating]);
    UIBarButtonItem *refresh([[UIBarButtonItem alloc] initWithTitle:(updating ? UCLocalize("CANCEL") : UCLocalize("REFRESH"))
        style:UIBarButtonItemStylePlain target:self action:updating ? @selector(cancelButtonClicked) : @selector(refreshButtonClicked)]);
    UIBarButtonItem *add([[UIBarButtonItem alloc] initWithTitle:UCLocalize("ADD") style:UIBarButtonItemStylePlain target:self action:@selector(showAddSourcePrompt)]);
    self.navigationItem.leftBarButtonItem = access_ == CydiaSources::Access::AdvancedSettings ? nil : refresh;
    self.navigationItem.rightBarButtonItems = access_ == CydiaSources::Access::AdvancedSettings ? @[add, refresh] : @[add];
}
- (void)refreshButtonClicked { [(id<CydiaDelegate>)self.delegate requestUpdate]; [self updateButtonsForEditingStatusAnimated:YES]; }
- (void)cancelButtonClicked { [(id<CydiaDelegate>)self.delegate cancelUpdate]; }
- (void)showAddSourcePrompt {
    if (!CydiaCanEditSources(access_)) { SourceReviewRequired(self, database_); return; }
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("ADD_SOURCE") message:SourceUI(@"SOURCE_ENTER_DETAILS") preferredStyle:UIAlertControllerStyleAlert]);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = SourceUI(@"SOURCE_URI"); field.keyboardType = UIKeyboardTypeURL; field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = SourceUI(@"SOURCE_SUITE"); field.text = @"./"; field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = SourceUI(@"SOURCE_COMPONENTS"); field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:SourceUI(@"SOURCE_ENTER_DEFINITION") style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
        [self showAddSourceDefinitionPrompt:@""];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:SourceUI(@"SOURCE_CONTINUE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
        NSString *components(alert.textFields[2].text ?: @"");
        NSArray *words([[components componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]);
        NSString *draft(CydiaSourceDraftForLegacySource(@{@"Type":@"deb", @"URI":alert.textFields[0].text ?: @"", @"Distribution":alert.textFields[1].text ?: @"", @"Sections":words}));
        if (draft == nil) { SourceMessage(self, SourceUI(@"SOURCE_DEFINITION_INVALID")); return; }
        [self showAddSourceDefinitionPrompt:draft];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)editDestination:(const CydiaSources::StoredDocument &)expected draft:(NSString *)draft {
    NSString *contents(draft ?: @"");
    const auto parsed(CydiaSources::ParseDocument("/draft.list", CydiaSources::Format::OneLine, [contents UTF8String] ?: ""));
    if (expected.document.format == CydiaSources::Format::Deb822 && parsed.valid() && parsed.definitions.size() == 1) {
        const auto &definition(parsed.definitions.front());
        NSMutableArray *uris([NSMutableArray array]), *suites([NSMutableArray array]), *types([NSMutableArray array]), *components([NSMutableArray array]);
        for (const auto &value : definition.uris) [uris addObject:[NSString stringWithUTF8String:value.c_str()]];
        for (const auto &value : definition.suites) [suites addObject:[NSString stringWithUTF8String:value.c_str()]];
        for (const auto &value : definition.types) [types addObject:[NSString stringWithUTF8String:value.c_str()]];
        for (const auto &value : definition.components) [components addObject:[NSString stringWithUTF8String:value.c_str()]];
        contents = [NSString stringWithFormat:@"Types: %@\nURIs: %@\nSuites: %@\n%@", [types componentsJoinedByString:@" "], [uris componentsJoinedByString:@" "],
            [suites componentsJoinedByString:@" "], components.count == 0 ? @"" : [NSString stringWithFormat:@"Components: %@\n", [components componentsJoinedByString:@" "]]];
    }
    CydiaSourceDefinitionEditor *editor([[CydiaSourceDefinitionEditor alloc] initWithDatabase:database_ expected:expected row:nil contents:contents access:access_]);
    [editor setDelegate:self.delegate]; __weak SourcesController *weakSelf(self); editor.saved = ^{ [weakSelf reloadData]; };
    [self.navigationController pushViewController:editor animated:YES];
}
- (void)showAddSourceDefinitionPrompt:(NSString *)draft {
    if (!CydiaCanEditSources(access_)) { SourceReviewRequired(self, database_); return; }
    const auto snapshot(CydiaReadSourceDocuments()); const auto locations(CydiaEffectiveSourceLocations());
    UIAlertController *chooser([UIAlertController alertControllerWithTitle:SourceUI(@"SOURCE_CHOOSE_FILE") message:SourceUI(@"SOURCE_DESTINATION_EXPLANATION") preferredStyle:UIAlertControllerStyleActionSheet]);
    BOOL hasMain(NO);
    for (const auto &document : snapshot.documents) {
        hasMain = hasMain || document.document.path == locations.mainFile;
        const auto expected(document);
        [chooser addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:document.document.path.c_str()] style:UIAlertActionStyleDefault handler:^(UIAlertAction *) { [self editDestination:expected draft:draft]; }]];
    }
    if (!hasMain && !locations.mainFile.empty() && locations.mainFile != "/dev/null") {
        const auto expected(CydiaSources::NewDocument(locations.mainFile, locations.mainFile.size() >= 8 && locations.mainFile.substr(locations.mainFile.size() - 8) == ".sources" ? CydiaSources::Format::Deb822 : CydiaSources::Format::OneLine));
        [chooser addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:locations.mainFile.c_str()] style:UIAlertActionStyleDefault handler:^(UIAlertAction *) { [self editDestination:expected draft:draft]; }]];
    }
    if (!locations.partsDirectory.empty() && locations.partsDirectory != "/dev/null")
        [chooser addAction:[UIAlertAction actionWithTitle:SourceUI(@"SOURCE_NEW_FILE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *) { [self chooseNewFile:draft]; }]];
    [chooser addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    chooser.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:chooser animated:YES completion:nil];
}
- (void)chooseNewFile:(NSString *)draft {
    const auto locations(CydiaEffectiveSourceLocations());
    UIAlertController *alert([UIAlertController alertControllerWithTitle:SourceUI(@"SOURCE_NEW_FILE") message:SourceUI(@"SOURCE_NEW_FILE_EXPLANATION") preferredStyle:UIAlertControllerStyleAlert]);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = SourceUI(@"SOURCE_FILENAME"); field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:SourceUI(@"SOURCE_CONTINUE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
        NSString *name(alert.textFields.firstObject.text ?: @"");
        std::string directory(locations.partsDirectory); while (!directory.empty() && directory.back() == '/') directory.pop_back();
        const std::string path(directory + "/" + ([name UTF8String] ?: ""));
        if ([name rangeOfString:@"/"].location != NSNotFound || !CydiaSources::IsEffectiveDestination(locations, path)) { SourceMessage(self, SourceUI(@"SOURCE_FILENAME_INVALID")); return; }
        auto expected(CydiaSources::NewDocument(path, [name hasSuffix:@".sources"] ? CydiaSources::Format::Deb822 : CydiaSources::Format::OneLine));
        const auto current(CydiaSources::ReadDocument(path, expected.document.format));
        if (!current.documents.empty()) { SourceMessage(self, SourceUI(@"SOURCE_FILE_EXISTS")); return; }
        [self editDestination:expected draft:draft];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
// Retired catalogue entry point: callers cannot resurrect assumed repositories.
- (void)showRestoreDefaultSourcePrompt:(NSString *)identifier completion:(void (^)(BOOL))completion { if (completion != nil) completion(NO); }
- (void)cancelDefaultSourceRestoration {}
@end
