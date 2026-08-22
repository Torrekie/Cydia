/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished UIKit work Copyright (C) 2026 Torrekie
 */

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
 */
/* }}} */

#include "Cydia/ConfirmationController.h"

#include "Cydia/AppState.h"
#include "Cydia/Appearance.h"
#include "Cydia/ConfirmationViewModel.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "CyteKit/Localize.h"

#include <dispatch/dispatch.h>

namespace {

NSString *PackageDisplayName(CydiaConfirmationPackageReference *package) {
    if ([[package displayName] isEqualToString:[package identity]])
        return [package displayName];
    return [NSString stringWithFormat:UCLocalize("PARENTHETICAL"),
                                      [package displayName], [package identity]];
}

NSString *ByteCountDescription(uint64_t value) {
    static NSArray<NSString *> *units;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        units = @[@"B", @"kB", @"MB", @"GB", @"TB", @"PB", @"EB"];
    });
    double scaled(static_cast<double>(value));
    NSUInteger power(0);
    while (scaled > 1024.0 && power + 1 < [units count]) {
        scaled /= 1024.0;
        ++power;
    }
    return [NSString stringWithFormat:@"%.1f %@", scaled, [units objectAtIndex:power]];
}

NSString *ClauseStatusDescription(CydiaConfirmationClause *clause) {
    if ([clause status] == CydiaConfirmationClauseStatusInstalled) {
        NSString *installed(UCLocalize("INSTALLED"));
        if ([clause plannedVersion] != nil)
            return [NSString stringWithFormat:UCLocalize("PARENTHETICAL"),
                                              installed, [clause plannedVersion]];
        return installed;
    }

    NSString *raw([clause rawStatusIdentifier]);
    return [raw length] == 0 ? UCLocalize("UNKNOWN") : raw;
}

NSString *ClauseDescription(CydiaConfirmationClause *clause) {
    NSMutableString *description([NSMutableString stringWithString:
        PackageDisplayName([clause package])]);
    if ([clause requiredVersion] != nil) {
        if ([[clause comparisonOperator] length] != 0)
            [description appendFormat:@" %@%@", [clause comparisonOperator],
                                                     [clause requiredVersion]];
        else
            [description appendFormat:@" %@", [clause requiredVersion]];
    }

    NSString *status(ClauseStatusDescription(clause));
    if ([status length] != 0)
        [description appendFormat:@" — %@", status];
    return description;
}

NSString *VisibleClauseDescription(CydiaConfirmationClause *clause) {
    NSMutableString *description([NSMutableString stringWithString:
        [[clause package] displayName]]);
    if ([clause requiredVersion] != nil) {
        if ([[clause comparisonOperator] length] != 0)
            [description appendFormat:@" %@%@", [clause comparisonOperator],
                                                     [clause requiredVersion]];
        else
            [description appendFormat:@" %@", [clause requiredVersion]];
    }
    return description;
}

NSString *NormalizedRelationship(NSString *relationship) {
    return [relationship isEqualToString:@"PreDepends"] ? @"Depends" : relationship;
}

CydiaConfirmationClause *IssueClauseAtRow(CydiaConfirmationIssue *issue,
                                           NSUInteger row,
                                           NSString **relationship) {
    for (CydiaConfirmationReason *reason in [issue reasons]) {
        NSArray<CydiaConfirmationClause *> *clauses([reason clauses]);
        if (row < [clauses count]) {
            if (relationship != nullptr)
                *relationship = NormalizedRelationship([reason relationship]);
            return [clauses objectAtIndex:row];
        }
        row -= [clauses count];
    }
    return nil;
}

} // namespace

typedef NS_ENUM(NSUInteger, CydiaConfirmationCellLayout) {
    CydiaConfirmationCellLayoutColumns,
    CydiaConfirmationCellLayoutMessage,
    CydiaConfirmationCellLayoutAction,
};

@interface CydiaConfirmationTableCell : UITableViewCell
@property(nonatomic, strong, readonly) UILabel *confirmationTitleLabel;
@property(nonatomic, strong, readonly) UILabel *confirmationDetailLabel;
- (void) setConfirmationLayout:(CydiaConfirmationCellLayout)layout
               traitCollection:(UITraitCollection *)traitCollection;
@end

@implementation CydiaConfirmationTableCell {
    UIStackView *confirmationStackView_;
}

- (instancetype) initWithReuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault
                      reuseIdentifier:reuseIdentifier]) != nil) {
        _confirmationTitleLabel = [[UILabel alloc] init];
        _confirmationTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _confirmationTitleLabel.numberOfLines = 0;
        _confirmationTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _confirmationTitleLabel.adjustsFontForContentSizeCategory = YES;
        _confirmationDetailLabel = [[UILabel alloc] init];
        _confirmationDetailLabel.numberOfLines = 0;
        _confirmationDetailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _confirmationDetailLabel.adjustsFontForContentSizeCategory = YES;

        confirmationStackView_ = [[UIStackView alloc]
            initWithArrangedSubviews:@[_confirmationTitleLabel, _confirmationDetailLabel]];
        confirmationStackView_.translatesAutoresizingMaskIntoConstraints = NO;
        confirmationStackView_.spacing = 8.0;
        [self.contentView addSubview:confirmationStackView_];

        UILayoutGuide *margins(self.contentView.layoutMarginsGuide);
        [NSLayoutConstraint activateConstraints:@[
            [confirmationStackView_.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [confirmationStackView_.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [confirmationStackView_.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [confirmationStackView_.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
        ]];
        [_confirmationTitleLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh
                                                  forAxis:UILayoutConstraintAxisHorizontal];
        [_confirmationTitleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh
                                                              forAxis:UILayoutConstraintAxisHorizontal];
        [_confirmationDetailLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                               forAxis:UILayoutConstraintAxisHorizontal];
        [self setConfirmationLayout:CydiaConfirmationCellLayoutColumns
                    traitCollection:[self traitCollection]];
    }
    return self;
}

- (void) setConfirmationLayout:(CydiaConfirmationCellLayout)layout
               traitCollection:(UITraitCollection *)traitCollection {
    BOOL accessibility(UIContentSizeCategoryIsAccessibilityCategory(
        [traitCollection preferredContentSizeCategory]));
    BOOL columns(layout == CydiaConfirmationCellLayoutColumns && !accessibility);
    _confirmationDetailLabel.hidden = layout != CydiaConfirmationCellLayoutColumns;
    confirmationStackView_.axis = columns ? UILayoutConstraintAxisHorizontal :
                                            UILayoutConstraintAxisVertical;
    confirmationStackView_.alignment = columns ? UIStackViewAlignmentFirstBaseline :
                                                 UIStackViewAlignmentFill;
    confirmationStackView_.spacing = columns ? 8.0 :
        (layout == CydiaConfirmationCellLayoutColumns ? 2.0 : 0.0);
    _confirmationTitleLabel.textAlignment =
        layout == CydiaConfirmationCellLayoutAction ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    _confirmationDetailLabel.textAlignment = columns ? NSTextAlignmentRight : NSTextAlignmentLeft;
}

- (void) prepareForReuse {
    [super prepareForReuse];
    _confirmationTitleLabel.text = nil;
    _confirmationDetailLabel.text = nil;
    self.accessibilityLabel = nil;
    self.accessibilityIdentifier = nil;
}

@end


@interface ConfirmationController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) CydiaConfirmationViewModel *viewModel;
@property (nonatomic, strong) CydiaConfirmationActionState *actionState;
@property (nonatomic, copy) NSArray<CydiaConfirmationTableSection *> *sections;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIAlertController *essentialAlert;
- (void) configureWithViewModel:(CydiaConfirmationViewModel *)viewModel;
@end


@implementation ConfirmationController

- (void) applyIssueNoticeAppearanceToCell:(CydiaConfirmationTableCell *)cell {
    UILabel *titleLabel([cell confirmationTitleLabel]);
    NSString *note(UCLocalize("NOTE"));
    NSString *text([NSString stringWithFormat:@"%@: %@", note,
                                               UCLocalize("CANNOT_COMPLY_EX")]);
    NSMutableAttributedString *attributed([[NSMutableAttributedString alloc]
        initWithString:text attributes:@{
            NSFontAttributeName: [titleLabel font],
            NSForegroundColorAttributeName: [titleLabel textColor],
        }]);
    NSRange noteRange([text rangeOfString:note]);
    if (noteRange.location != NSNotFound) {
        [attributed addAttributes:@{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:[[titleLabel font] pointSize]],
            NSForegroundColorAttributeName: [UIColor cydiaColorForRole:
                CydiaColorRoleErrorLabel traitCollection:[self traitCollection]],
        } range:noteRange];
    }
    [titleLabel setAttributedText:attributed];
}

- (void) configureWithViewModel:(CydiaConfirmationViewModel *)viewModel {
    _viewModel = viewModel;
    _actionState = [[CydiaConfirmationActionState alloc]
        initWithBlockingIssues:[viewModel hasBlockingIssues]
        essentialRemovalPolicy:[viewModel essentialRemovalPolicy]];
    _sections = CydiaConfirmationBuildTableSections(viewModel);
}

- (instancetype) initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) {
        const CydiaAPT::TransactionData transaction([database transactionData]);
        CydiaConfirmationPackageNameResolver resolver = ^NSString *(NSString *identity) {
            Package *package([database packageWithName:identity]);
            return [package name];
        };
        CydiaConfirmationViewModel *viewModel([[CydiaConfirmationViewModel alloc]
            initWithTransactionData:transaction
            advancedModeEnabled:Advanced_
            packageNameResolver:resolver]);
        [self configureWithViewModel:viewModel];
    }
    return self;
}

#if TARGET_OS_SIMULATOR
- (instancetype) initWithViewModel:(CydiaConfirmationViewModel *)viewModel
                          delegate:(id<ConfirmationControllerDelegate>)delegate {
    if (viewModel == nil)
        return nil;
    if ((self = [super init]) != nil) {
        [self configureWithViewModel:viewModel];
        [self setDelegate:delegate];
    }
    return self;
}
#endif

- (void) loadView {
    UIView *view([[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]]);
    [view setAutoresizingMask:CydiaAutoresizingFlexibleBoth];
    [self setView:view];

    UITableView *table([[UITableView alloc] initWithFrame:[view bounds]
                                                    style:UITableViewStyleGrouped]);
    [table setAutoresizingMask:CydiaAutoresizingFlexibleBoth];
    [table setDataSource:self];
    [table setDelegate:self];
    [table setEstimatedRowHeight:58.0];
    [table setRowHeight:UITableViewAutomaticDimension];
    [table setEstimatedSectionHeaderHeight:0.0];
    [table setEstimatedSectionFooterHeight:0.0];
    if ([table respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)])
        [table setCellLayoutMarginsFollowReadableWidth:NO];
    [table setAccessibilityIdentifier:@"cydia.confirmation.table"];
    [view addSubview:table];
    _tableView = table;

    [self applyColorAppearance];
}

- (void) viewDidLoad {
    [super viewDidLoad];
    [[self navigationItem] setTitle:UCLocalizeEx([_viewModel hasBlockingIssues] ?
        @"CANNOT_COMPLY" : @"CONFIRM")];
    [[self navigationItem] setHidesBackButton:YES];
    [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("CANCEL")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(cancelButtonClicked)]];

    if ([_viewModel showsConfirmAction])
        [[self navigationItem] setRightBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("CONFIRM")
            style:UIBarButtonItemStyleDone
            target:self
            action:@selector(confirmButtonClicked)]];
}

- (void) viewWillAppear:(BOOL)animated {
    [[[self navigationController] navigationBar] setBarStyle:UIBarStyleDefault];
    [self applyColorAppearance];
    [super viewWillAppear:animated];
}

- (void) reloadData {
    [super reloadData];
    [_tableView reloadData];
}

- (void) releaseSubviews {
    _tableView = nil;
    [super releaseSubviews];
}

- (void) applyCellAppearance:(UITableViewCell *)cell
                  sectionKind:(CydiaConfirmationTableSectionKind)sectionKind {
    UITraitCollection *traits([self traitCollection]);
    CydiaColorRole background(sectionKind == CydiaConfirmationTableSectionKindIssueDetails ?
        CydiaColorRoleRemovingBackground : CydiaColorRoleBackground);
    [cell setBackgroundColor:[UIColor cydiaColorForRole:background
                                         traitCollection:traits]];
    CydiaConfirmationTableCell *confirmationCell((CydiaConfirmationTableCell *) cell);
    CydiaConfirmationCellLayout layout(CydiaConfirmationCellLayoutColumns);
    if (sectionKind == CydiaConfirmationTableSectionKindIssueNotice)
        layout = CydiaConfirmationCellLayoutMessage;
    else if (sectionKind == CydiaConfirmationTableSectionKindQueue)
        layout = CydiaConfirmationCellLayoutAction;
    [confirmationCell setConfirmationLayout:layout traitCollection:traits];
    UIFontTextStyle titleStyle(UIFontTextStyleBody);
    UIFontTextStyle detailStyle(UIFontTextStyleBody);
    if (sectionKind == CydiaConfirmationTableSectionKindQueue)
        titleStyle = UIFontTextStyleSubheadline;
    else if (sectionKind == CydiaConfirmationTableSectionKindIssueNotice)
        titleStyle = detailStyle = UIFontTextStyleFootnote;
    [[confirmationCell confirmationTitleLabel]
        setFont:[UIFont preferredFontForTextStyle:titleStyle
                             compatibleWithTraitCollection:traits]];
    [[confirmationCell confirmationDetailLabel]
        setFont:[UIFont preferredFontForTextStyle:detailStyle
                             compatibleWithTraitCollection:traits]];
    [[confirmationCell confirmationTitleLabel]
        setTextColor:[UIColor cydiaColorForRole:
            sectionKind == CydiaConfirmationTableSectionKindQueue ?
                CydiaColorRoleAccent : CydiaColorRoleLabel
                                traitCollection:traits]];
    [[confirmationCell confirmationDetailLabel]
        setTextColor:[UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                traitCollection:traits]];
    if (sectionKind == CydiaConfirmationTableSectionKindIssueNotice)
        [self applyIssueNoticeAppearanceToCell:confirmationCell];
}

- (void) applyColorAppearance {
    UITraitCollection *traits([self traitCollection]);
    UIColor *grouped([UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                 traitCollection:traits]);
    [[self view] setBackgroundColor:grouped];
    [_tableView setBackgroundColor:grouped];
    [_tableView setSeparatorColor:[UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                               traitCollection:traits]];
    for (UITableViewCell *cell in [_tableView visibleCells]) {
        NSIndexPath *indexPath([_tableView indexPathForCell:cell]);
        if (indexPath == nil || static_cast<NSUInteger>([indexPath section]) >= [_sections count])
            continue;
        CydiaConfirmationTableSection *section([_sections objectAtIndex:[indexPath section]]);
        [self applyCellAppearance:cell sectionKind:[section kind]];
    }
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    BOOL contentSizeChanged(previousTraitCollection != nil &&
        ![[[self traitCollection] preferredContentSizeCategory]
            isEqualToString:[previousTraitCollection preferredContentSizeCategory]]);
    if (contentSizeChanged ||
        CydiaColorAppearanceDidChange([self traitCollection], previousTraitCollection)) {
        [self applyColorAppearance];
        [_tableView reloadData];
    }
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    (void) tableView;
    return static_cast<NSInteger>([_sections count]);
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void) tableView;
    if (section < 0 || static_cast<NSUInteger>(section) >= [_sections count])
        return 0;
    return static_cast<NSInteger>([[_sections objectAtIndex:section] rowCount]);
}

- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void) tableView;
    CydiaConfirmationTableSectionKind kind([[_sections objectAtIndex:section] kind]);
    if (kind == CydiaConfirmationTableSectionKindIssueNotice ||
        kind == CydiaConfirmationTableSectionKindQueue)
        return 9.0;
    UIFont *font([UIFont preferredFontForTextStyle:UIFontTextStyleFootnote
                            compatibleWithTraitCollection:[self traitCollection]]);
    return ceil([font lineHeight] + 15.0);
}

- (CGFloat) tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    (void) tableView;
    (void) section;
    return CGFLOAT_MIN;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void) tableView;
    CydiaConfirmationTableSection *tableSection([_sections objectAtIndex:section]);
    switch ([tableSection kind]) {
        case CydiaConfirmationTableSectionKindIssueNotice:
        case CydiaConfirmationTableSectionKindQueue:
            return nil;
        case CydiaConfirmationTableSectionKindSizes:
            return UCLocalize("STATISTICS");
        case CydiaConfirmationTableSectionKindModifications:
            return UCLocalize("MODIFICATIONS");
        case CydiaConfirmationTableSectionKindIssueDetails:
            return [[tableSection issue] package] == nil ? nil :
                [[[tableSection issue] package] displayName];
    }
    return nil;
}

- (UITableViewCell *) tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier(@"CydiaConfirmationCell");
    CydiaConfirmationTableCell *cell((CydiaConfirmationTableCell *)
        [tableView dequeueReusableCellWithIdentifier:identifier]);
    if (cell == nil)
        cell = [[CydiaConfirmationTableCell alloc] initWithReuseIdentifier:identifier];

    [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
    [cell setAccessoryType:UITableViewCellAccessoryNone];
    UILabel *titleLabel([cell confirmationTitleLabel]);
    UILabel *detailLabel([cell confirmationDetailLabel]);
    [titleLabel setText:nil];
    [detailLabel setText:nil];
    [titleLabel setAttributedText:nil];
    [cell setAccessibilityIdentifier:nil];
    [cell setAccessibilityLabel:nil];
    [cell setAccessibilityValue:nil];
    [cell setAccessibilityTraits:UIAccessibilityTraitNone];

    CydiaConfirmationTableSection *section([_sections objectAtIndex:[indexPath section]]);
    switch ([section kind]) {
        case CydiaConfirmationTableSectionKindIssueNotice: {
            NSString *note(UCLocalize("NOTE"));
            NSString *message(UCLocalize("CANNOT_COMPLY_EX"));
            NSString *text([NSString stringWithFormat:@"%@: %@", note, message]);
            [titleLabel setText:text];
            [cell setAccessibilityIdentifier:@"cydia.confirmation.issue-note"];
            [cell setAccessibilityLabel:text];
            break;
        }

        case CydiaConfirmationTableSectionKindQueue:
            [titleLabel setText:UCLocalize("CONTINUE_QUEUING")];
            [cell setSelectionStyle:UITableViewCellSelectionStyleDefault];
            [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
            [cell setAccessibilityIdentifier:@"cydia.confirmation.continue-queuing"];
            [cell setAccessibilityLabel:UCLocalize("CONTINUE_QUEUING")];
            [cell setAccessibilityTraits:UIAccessibilityTraitButton];
            break;

        case CydiaConfirmationTableSectionKindSizes: {
            BOOL downloading([_viewModel downloadingBytes] != 0 && [indexPath row] == 0);
            NSString *title(downloading ? UCLocalize("DOWNLOADING") :
                                          UCLocalize("RESUMING_AT"));
            uint64_t bytes(downloading ? [_viewModel downloadingBytes] :
                                         [_viewModel resumingBytes]);
            NSString *detail(ByteCountDescription(bytes));
            [titleLabel setText:title];
            [detailLabel setText:detail];
            [cell setAccessibilityIdentifier:downloading ?
                @"cydia.confirmation.sizes.downloading" :
                @"cydia.confirmation.sizes.resuming"];
            [cell setAccessibilityLabel:[NSString stringWithFormat:UCLocalize("COLON_DELIMITED"),
                                         title, detail]];
            break;
        }

        case CydiaConfirmationTableSectionKindModifications: {
            CydiaConfirmationChangeGroup *group(
                [[section changeGroups] objectAtIndex:[indexPath row]]);
            NSMutableArray<NSString *> *names(
                [NSMutableArray arrayWithCapacity:[[group packages] count]]);
            NSMutableArray<NSString *> *identities(
                [NSMutableArray arrayWithCapacity:[[group packages] count]]);
            for (CydiaConfirmationPackageReference *package in [group packages]) {
                [names addObject:[package displayName]];
                [identities addObject:[package identity]];
            }
            NSString *title(UCLocalizeEx([group titleLocalizationKey]));
            NSString *detail([names componentsJoinedByString:@"\n"]);
            [titleLabel setText:title];
            [detailLabel setText:detail];
            [cell setAccessibilityIdentifier:[NSString stringWithFormat:
                @"cydia.confirmation.modifications.%lu",
                static_cast<unsigned long>([group kind])]];
            [cell setAccessibilityLabel:[NSString stringWithFormat:UCLocalize("COLON_DELIMITED"),
                                         title, detail]];
            [cell setAccessibilityValue:[identities componentsJoinedByString:@"\n"]];
            break;
        }

        case CydiaConfirmationTableSectionKindIssueDetails: {
            NSString *relationship(nil);
            CydiaConfirmationClause *clause(IssueClauseAtRow(
                [section issue], [indexPath row], &relationship));
            NSString *visible(clause == nil ? UCLocalize("CANNOT_COMPLY_EX") :
                                              VisibleClauseDescription(clause));
            NSString *accessible(clause == nil ? visible : ClauseDescription(clause));
            [titleLabel setText:relationship];
            [detailLabel setText:visible];
            [cell setAccessibilityIdentifier:[NSString stringWithFormat:
                @"cydia.confirmation.issue.%ld.%ld",
                static_cast<long>([indexPath section]),
                static_cast<long>([indexPath row])]];
            [cell setAccessibilityLabel:[relationship length] == 0 ? accessible :
                [NSString stringWithFormat:UCLocalize("COLON_DELIMITED"),
                                           relationship, accessible]];
            if (clause != nil)
                [cell setAccessibilityValue:[[clause package] identity]];
            break;
        }
    }

    [self applyCellAppearance:cell sectionKind:[section kind]];
    return cell;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    CydiaConfirmationTableSection *section([_sections objectAtIndex:[indexPath section]]);
    if ([section kind] == CydiaConfirmationTableSectionKindQueue)
        [self continueQueuingButtonClicked];
}

- (void) tableView:(UITableView *)tableView
    willDisplayCell:(UITableViewCell *)cell
  forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void) tableView;
    CydiaConfirmationTableSection *section([_sections objectAtIndex:[indexPath section]]);
    [self applyCellAppearance:cell sectionKind:[section kind]];
}

- (void) tableView:(UITableView *)tableView
    willDisplayHeaderView:(UIView *)view
               forSection:(NSInteger)sectionIndex {
    CydiaConfirmationTableSection *section([_sections objectAtIndex:sectionIndex]);
    UITableViewHeaderFooterView *header(
        [view isKindOfClass:[UITableViewHeaderFooterView class]] ?
            (UITableViewHeaderFooterView *) view : nil);
    if (header == nil)
        return;

    NSString *title([self tableView:tableView titleForHeaderInSection:sectionIndex]);
    [header setIsAccessibilityElement:title != nil];
    [header setAccessibilityLabel:title];
    [header setAccessibilityValue:nil];
    CydiaColorRole labelRole(CydiaColorRoleSecondaryLabel);
    if ([section kind] == CydiaConfirmationTableSectionKindIssueDetails) {
        CydiaConfirmationPackageReference *package([[section issue] package]);
        if (package != nil)
            [header setAccessibilityValue:[package identity]];
        labelRole = CydiaColorRoleErrorLabel;
    }
    [[header textLabel] setTextColor:[UIColor cydiaColorForRole:labelRole
                                              traitCollection:[self traitCollection]]];
}

- (void) dismissConfirmation {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void) presentBlockedEssentialAlert {
    UIAlertController *alert([UIAlertController
        alertControllerWithTitle:UCLocalize("UNABLE_TO_COMPLY")
        message:UCLocalize("UNABLE_TO_COMPLY_EX")
        preferredStyle:UIAlertControllerStyleAlert]);
    __weak ConfirmationController *weakSelf(self);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OKAY")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        (void) action;
        ConfirmationController *strongSelf(weakSelf);
        [strongSelf setEssentialAlert:nil];
        [strongSelf handleUserAction:CydiaConfirmationUserActionBlockedEssentialAcknowledged];
    }]];
    _essentialAlert = alert;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void) presentForceRemovalAlert {
    NSString *parenthetical(UCLocalize("PARENTHETICAL"));
    UIAlertController *alert([UIAlertController
        alertControllerWithTitle:UCLocalize("REMOVING_ESSENTIALS")
        message:UCLocalize("REMOVING_ESSENTIALS_EX")
        preferredStyle:UIAlertControllerStyleAlert]);
    __weak ConfirmationController *weakSelf(self);
    [alert addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:parenthetical,
                         UCLocalize("CANCEL_OPERATION"), UCLocalize("SAFE")]
        style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *action) {
            (void) action;
            ConfirmationController *strongSelf(weakSelf);
            [strongSelf setEssentialAlert:nil];
            [strongSelf handleUserAction:CydiaConfirmationUserActionForceRemovalCancelled];
        }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:[NSString stringWithFormat:parenthetical,
                         UCLocalize("FORCE_REMOVAL"), UCLocalize("UNSAFE")]
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            (void) action;
            ConfirmationController *strongSelf(weakSelf);
            [strongSelf setEssentialAlert:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf handleUserAction:CydiaConfirmationUserActionForceRemovalConfirmed];
            });
        }]];
    _essentialAlert = alert;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void) handleUserAction:(CydiaConfirmationUserAction)userAction {
    CydiaConfirmationActionEffect effect([_actionState effectForUserAction:userAction]);
    id<ConfirmationControllerDelegate> delegate((id<ConfirmationControllerDelegate>) [self delegate]);
    switch (effect) {
        case CydiaConfirmationActionEffectNone:
            return;

        case CydiaConfirmationActionEffectCancelAndClear:
            [delegate cancelAndClear:true];
            [self dismissConfirmation];
            return;

        case CydiaConfirmationActionEffectContinueQueuing:
            [delegate cancelAndClear:false];
            [self dismissConfirmation];
            return;

        case CydiaConfirmationActionEffectConfirm:
            if ([_viewModel requiresSubstrateRestart])
                RestartSubstrate_ = true;
            [delegate confirmWithNavigationController:[self navigationController]];
            return;

        case CydiaConfirmationActionEffectDismissWithoutDelegate:
            [self dismissConfirmation];
            return;

        case CydiaConfirmationActionEffectPresentBlockedEssentialAlert:
            [self presentBlockedEssentialAlert];
            return;

        case CydiaConfirmationActionEffectPresentForceRemovalAlert:
            [self presentForceRemovalAlert];
            return;
    }
}

- (void) cancelButtonClicked {
    [self handleUserAction:CydiaConfirmationUserActionCancel];
}

- (void) continueQueuingButtonClicked {
    [self handleUserAction:CydiaConfirmationUserActionContinueQueuing];
}

- (void) confirmButtonClicked {
    [self handleUserAction:CydiaConfirmationUserActionConfirm];
}

@end
