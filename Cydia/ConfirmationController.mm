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

#include <climits>
#include <dispatch/dispatch.h>

namespace {

NSString *PackageDisplayName(CydiaConfirmationPackageReference *package) {
    if ([[package displayName] isEqualToString:[package identity]])
        return [package displayName];
    return [NSString stringWithFormat:UCLocalize("PARENTHETICAL"),
                                      [package displayName], [package identity]];
}

NSString *ByteCountDescription(uint64_t value) {
    if (value <= static_cast<uint64_t>(LLONG_MAX))
        return [NSByteCountFormatter stringFromByteCount:static_cast<long long>(value)
                                               countStyle:NSByteCountFormatterCountStyleFile];

    NSNumberFormatter *formatter([[NSNumberFormatter alloc] init]);
    [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
    NSString *number([formatter stringFromNumber:[NSNumber numberWithUnsignedLongLong:value]]);
    return [NSString stringWithFormat:@"%@ B", number ?: [NSNumber numberWithUnsignedLongLong:value]];
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
            [description appendFormat:@" %@", [clause comparisonOperator]];
        [description appendFormat:@" %@", [clause requiredVersion]];
    }

    NSString *status(ClauseStatusDescription(clause));
    if ([status length] != 0)
        [description appendFormat:@" — %@", status];
    return description;
}

NSString *IssueDescription(CydiaConfirmationIssue *issue) {
    NSMutableArray<NSString *> *reasons([NSMutableArray arrayWithCapacity:[[issue reasons] count]]);
    for (CydiaConfirmationReason *reason in [issue reasons]) {
        NSMutableArray<NSString *> *clauses(
            [NSMutableArray arrayWithCapacity:[[reason clauses] count]]);
        for (CydiaConfirmationClause *clause in [reason clauses])
            [clauses addObject:ClauseDescription(clause)];

        NSString *body([clauses componentsJoinedByString:@" OR "]);
        NSString *relationship([reason relationship]);
        if ([relationship isEqualToString:@"PreDepends"])
            relationship = @"Depends";
        if ([relationship length] == 0)
            [reasons addObject:body];
        else
            [reasons addObject:[NSString stringWithFormat:@"%@: %@",
                                relationship, body]];
    }

    NSString *description([reasons componentsJoinedByString:@"\n"]);
    return [description length] == 0 ? UCLocalize("CANNOT_COMPLY_EX") : description;
}

} // namespace


@interface ConfirmationController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) CydiaConfirmationViewModel *viewModel;
@property (nonatomic, strong) CydiaConfirmationActionState *actionState;
@property (nonatomic, copy) NSArray<CydiaConfirmationTableSection *> *sections;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIButton *continueButton;
@property (nonatomic, strong) UIAlertController *essentialAlert;
- (void) configureWithViewModel:(CydiaConfirmationViewModel *)viewModel;
@end


@implementation ConfirmationController

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
    if ([table respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)])
        [table setCellLayoutMarginsFollowReadableWidth:NO];
    [table setAccessibilityIdentifier:@"cydia.confirmation.table"];
    [view addSubview:table];
    _tableView = table;

    const CGFloat headerHeight(58.0);
    UIView *header([[UIView alloc] initWithFrame:CGRectMake(0, 0,
        CGRectGetWidth([table bounds]), headerHeight)]);
    [header setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    UIButton *continueButton([UIButton buttonWithType:UIButtonTypeSystem]);
    [continueButton setFrame:CGRectInset([header bounds], 16.0, 7.0)];
    [continueButton setAutoresizingMask:CydiaAutoresizingFlexibleBoth];
    [continueButton setTitle:UCLocalize("CONTINUE_QUEUING") forState:UIControlStateNormal];
    [[continueButton titleLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
    [[continueButton titleLabel] setAdjustsFontForContentSizeCategory:YES];
    [[continueButton titleLabel] setNumberOfLines:0];
    [[continueButton titleLabel] setTextAlignment:NSTextAlignmentCenter];
    [continueButton addTarget:self
                       action:@selector(continueQueuingButtonClicked)
             forControlEvents:UIControlEventTouchUpInside];
    [continueButton setAccessibilityIdentifier:@"cydia.confirmation.continue-queuing"];
    [header addSubview:continueButton];
    [table setTableHeaderView:header];
    _continueButton = continueButton;

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

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    UIView *header([_tableView tableHeaderView]);
    if (header == nil)
        return;

    const CGFloat horizontalInset(16.0);
    const CGFloat verticalInset(7.0);
    CGFloat availableWidth(MAX(0.0, CGRectGetWidth([_tableView bounds]) -
                                      horizontalInset * 2.0));
    CGSize fitting([_continueButton sizeThatFits:CGSizeMake(availableWidth, CGFLOAT_MAX)]);
    CGFloat height(MAX(58.0, fitting.height + verticalInset * 2.0));
    CGRect frame([header frame]);
    if (CGRectGetWidth(frame) != CGRectGetWidth([_tableView bounds]) ||
        CGRectGetHeight(frame) != height) {
        frame.size.width = CGRectGetWidth([_tableView bounds]);
        frame.size.height = height;
        [header setFrame:frame];
        [_tableView setTableHeaderView:header];
    }
    [_continueButton setFrame:CGRectInset([header bounds], horizontalInset, verticalInset)];
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
    _continueButton = nil;
    [super releaseSubviews];
}

- (void) applyCellAppearance:(UITableViewCell *)cell
                  sectionKind:(CydiaConfirmationTableSectionKind)sectionKind {
    UITraitCollection *traits([self traitCollection]);
    CydiaColorRole background(sectionKind == CydiaConfirmationTableSectionKindIssue ?
        CydiaColorRoleRemovingBackground : CydiaColorRoleBackground);
    [cell setBackgroundColor:[UIColor cydiaColorForRole:background
                                         traitCollection:traits]];
    [[cell textLabel] setTextColor:[UIColor cydiaColorForRole:CydiaColorRoleLabel
                                              traitCollection:traits]];
    [[cell detailTextLabel] setTextColor:[UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                                    traitCollection:traits]];
}

- (void) applyColorAppearance {
    UITraitCollection *traits([self traitCollection]);
    UIColor *grouped([UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                 traitCollection:traits]);
    [[self view] setBackgroundColor:grouped];
    [_tableView setBackgroundColor:grouped];
    [_tableView setSeparatorColor:[UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                               traitCollection:traits]];
    [_continueButton setTitleColor:[UIColor cydiaColorForRole:CydiaColorRoleAccent
                                              traitCollection:traits]
                            forState:UIControlStateNormal];
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
    if (CydiaColorAppearanceDidChange([self traitCollection], previousTraitCollection)) {
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

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void) tableView;
    CydiaConfirmationTableSection *tableSection([_sections objectAtIndex:section]);
    switch ([tableSection kind]) {
        case CydiaConfirmationTableSectionKindIssue:
            return UCLocalize("CANNOT_COMPLY");
        case CydiaConfirmationTableSectionKindChanges:
            return UCLocalizeEx([[tableSection changeGroup] titleLocalizationKey]);
        case CydiaConfirmationTableSectionKindSizes:
            return UCLocalize("STATISTICS");
    }
    return nil;
}

- (UITableViewCell *) tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier(@"CydiaConfirmationCell");
    UITableViewCell *cell([tableView dequeueReusableCellWithIdentifier:identifier]);
    if (cell == nil)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];

    [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
    [cell setAccessoryType:UITableViewCellAccessoryNone];
    [[cell imageView] setImage:nil];
    [[cell textLabel] setNumberOfLines:1];
    [[cell detailTextLabel] setNumberOfLines:1];
    [[cell textLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]];
    [[cell detailTextLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]];
    [[cell textLabel] setAdjustsFontForContentSizeCategory:YES];
    [[cell detailTextLabel] setAdjustsFontForContentSizeCategory:YES];
    [cell setAccessibilityIdentifier:nil];
    [cell setAccessibilityValue:nil];

    CydiaConfirmationTableSection *section([_sections objectAtIndex:[indexPath section]]);
    switch ([section kind]) {
        case CydiaConfirmationTableSectionKindIssue: {
            CydiaConfirmationIssue *issue([section issue]);
            NSString *title([issue package] == nil ? UCLocalize("CANNOT_COMPLY") :
                PackageDisplayName([issue package]));
            NSString *detail(IssueDescription(issue));
            [[cell textLabel] setText:title];
            [[cell textLabel] setNumberOfLines:0];
            [[cell detailTextLabel] setText:detail];
            [[cell detailTextLabel] setNumberOfLines:0];
            [cell setAccessibilityIdentifier:[NSString stringWithFormat:
                @"cydia.confirmation.issue.%ld", static_cast<long>([indexPath section])]];
            [cell setAccessibilityLabel:[NSString stringWithFormat:UCLocalize("COLON_DELIMITED"),
                                         title, detail]];
            break;
        }

        case CydiaConfirmationTableSectionKindChanges: {
            CydiaConfirmationChangeGroup *group([section changeGroup]);
            CydiaConfirmationPackageReference *package(
                [[group packages] objectAtIndex:[indexPath row]]);
            [[cell textLabel] setText:[package displayName]];
            if ([[package displayName] isEqualToString:[package identity]])
                [[cell detailTextLabel] setText:nil];
            else
                [[cell detailTextLabel] setText:[package identity]];
            [cell setAccessibilityIdentifier:[@"cydia.confirmation.package."
                stringByAppendingString:[package identity]]];
            [cell setAccessibilityLabel:[NSString stringWithFormat:@"%@, %@, %@",
                UCLocalizeEx([group titleLocalizationKey]), [package displayName],
                [package identity]]];
            break;
        }

        case CydiaConfirmationTableSectionKindSizes: {
            BOOL downloading([_viewModel downloadingBytes] != 0 && [indexPath row] == 0);
            NSString *title(downloading ? UCLocalize("DOWNLOADING") :
                                          UCLocalize("RESUMING_AT"));
            uint64_t bytes(downloading ? [_viewModel downloadingBytes] :
                                         [_viewModel resumingBytes]);
            NSString *detail(ByteCountDescription(bytes));
            [[cell textLabel] setText:title];
            [[cell detailTextLabel] setText:detail];
            [cell setAccessibilityIdentifier:downloading ?
                @"cydia.confirmation.sizes.downloading" :
                @"cydia.confirmation.sizes.resuming"];
            [cell setAccessibilityLabel:[NSString stringWithFormat:UCLocalize("COLON_DELIMITED"),
                                         title, detail]];
            break;
        }
    }

    [self applyCellAppearance:cell sectionKind:[section kind]];
    return cell;
}

- (void) tableView:(UITableView *)tableView
    willDisplayCell:(UITableViewCell *)cell
  forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void) tableView;
    CydiaConfirmationTableSection *section([_sections objectAtIndex:[indexPath section]]);
    [self applyCellAppearance:cell sectionKind:[section kind]];
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
