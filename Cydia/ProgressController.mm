/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished native progress work Copyright (C) 2026 Torrekie
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

#include "Cydia/ProgressController.h"

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/Appearance.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/ProgressEventCell.h"
#include "Cydia/RebootCompat.h"
#include "CyteKit/Localize.h"
#include "Menes/yieldToSelector.h"
#include "iPhonePrivate.h"

#include <notify.h>

extern bool RestartSubstrate_;
extern void UpdateExternalStatus(uint64_t newStatus);

#define SpringBoard_ "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
#define NotifyConfig_ "/etc/notify.conf"

static NSString * const CydiaProgressEventCellIdentifier = @"CydiaProgressEventCell";

static std::string FileFingerprint(const char *path) {
    if (path == NULL)
        return std::string();

    NSData *data([NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]]);
    if (data == nil)
        return std::string();
    return CydiaAPT::Fingerprint([data bytes], [data length]);
}

@protocol ProgressControllerDelegate <NSObject>
- (void) saveState;
- (void) returnToCydia;
- (void) terminateWithSuccess;
- (UIProgressHUD *) addProgressHUD;
- (void) reloadSpringBoard;
@end

@interface ProgressController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation ProgressController {
    UIView *headerView_;
    UILabel *titleLabel_;
    UILabel *statusLabel_;
    UIProgressView *progressView_;
    UITableView *eventsView_;
    UIBarButtonItem *cancelItem_;
    UIBarButtonItem *finishItem_;
    CydiaProgressViewState *renderedState_;
}

- (void) dealloc {
    [progressModel_ setObserver:nil];
    if ([database_ progressDelegate] == (CydiaProgressViewModel *) progressModel_)
        [database_ setProgressDelegate:nil];
}

- (instancetype) initWithProgressModel:(CydiaProgressViewModel *)model
                               database:(Database *)database
                               delegate:(id)delegate {
    if ((self = [super init]) != nil) {
        NSParameterAssert(model != nil);
        database_ = database;
        progressModel_ = model;
        self.delegate = delegate;
        renderedState_ = model.state;

        cancelItem_ = [[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("CANCEL")
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(cancel)];
        finishItem_ = [[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("CLOSE")
            style:UIBarButtonItemStyleDone
            target:self
            action:@selector(close)];

        self.navigationItem.hidesBackButton = YES;
        [progressModel_ setObserver:self];
        [database_ setProgressDelegate:progressModel_];
        [self updateNavigationActionsForState:renderedState_];
    }
    return self;
}

- (id) initWithDatabase:(Database *)database delegate:(id)delegate {
    __weak Database *weakDatabase(database);
    CydiaProgressViewModel *model([[CydiaProgressViewModel alloc]
        initWithPackageNameResolver:^NSString *(NSString *identifier) {
            if (![weakDatabase hasPackages])
                return nil;
            Package *package([weakDatabase packageWithName:identifier]);
            return [package name];
        }]);
    return [self initWithProgressModel:model database:database delegate:delegate];
}

#if TARGET_OS_SIMULATOR
/* The installed probe uses the production controller with a deterministic
 * model, but never constructs Database or invokes privileged finish actions. */
- (id) initWithProgressModelForTesting:(CydiaProgressViewModel *)model delegate:(id)delegate {
    return [self initWithProgressModel:model database:nil delegate:delegate];
}
#endif

- (void) loadView {
    UIView *view([[UIView alloc] initWithFrame:[UIScreen mainScreen].applicationFrame]);
    view.autoresizingMask = CydiaAutoresizingFlexibleBoth;
    view.accessibilityIdentifier = @"cydia.progress.root";
    self.view = view;

    headerView_ = [[UIView alloc] init];
    headerView_.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:headerView_];

    titleLabel_ = [[UILabel alloc] init];
    titleLabel_.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel_.numberOfLines = 0;
    titleLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    titleLabel_.adjustsFontForContentSizeCategory = YES;
    titleLabel_.accessibilityTraits = UIAccessibilityTraitHeader;
    titleLabel_.accessibilityIdentifier = @"cydia.progress.title";
    [headerView_ addSubview:titleLabel_];

    statusLabel_ = [[UILabel alloc] init];
    statusLabel_.translatesAutoresizingMaskIntoConstraints = NO;
    statusLabel_.numberOfLines = 0;
    statusLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    statusLabel_.adjustsFontForContentSizeCategory = YES;
    statusLabel_.accessibilityIdentifier = @"cydia.progress.status";
    [headerView_ addSubview:statusLabel_];

    progressView_ = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progressView_.translatesAutoresizingMaskIntoConstraints = NO;
    progressView_.isAccessibilityElement = YES;
    progressView_.accessibilityLabel = UCLocalize("RUNNING");
    progressView_.accessibilityIdentifier = @"cydia.progress.percent";
    [headerView_ addSubview:progressView_];

    eventsView_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    eventsView_.translatesAutoresizingMaskIntoConstraints = NO;
    eventsView_.autoresizingMask = CydiaAutoresizingFlexibleBoth;
    eventsView_.dataSource = self;
    eventsView_.delegate = self;
    eventsView_.rowHeight = UITableViewAutomaticDimension;
    eventsView_.estimatedRowHeight = 56.0;
    eventsView_.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    eventsView_.accessibilityIdentifier = @"cydia.progress.events";
    [eventsView_ registerClass:[CydiaProgressEventCell class]
        forCellReuseIdentifier:CydiaProgressEventCellIdentifier];
    [view addSubview:eventsView_];

    UILayoutGuide *margins(headerView_.layoutMarginsGuide);
    [NSLayoutConstraint activateConstraints:@[
        [headerView_.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [headerView_.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [headerView_.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor],
        [titleLabel_.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [titleLabel_.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [titleLabel_.topAnchor constraintEqualToAnchor:headerView_.topAnchor constant:14.0],
        [statusLabel_.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [statusLabel_.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [statusLabel_.topAnchor constraintEqualToAnchor:titleLabel_.bottomAnchor constant:4.0],
        [progressView_.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [progressView_.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [progressView_.topAnchor constraintEqualToAnchor:statusLabel_.bottomAnchor constant:12.0],
        [progressView_.bottomAnchor constraintEqualToAnchor:headerView_.bottomAnchor constant:-14.0],
        [eventsView_.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [eventsView_.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [eventsView_.topAnchor constraintEqualToAnchor:headerView_.bottomAnchor],
        [eventsView_.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    [self applyTypography];
    [self applyColorAppearance];
    [self renderState:renderedState_ previous:nil change:CydiaProgressViewModelChangeNone];
}

- (void) releaseSubviews {
    eventsView_.dataSource = nil;
    eventsView_.delegate = nil;
    headerView_ = nil;
    titleLabel_ = nil;
    statusLabel_ = nil;
    progressView_ = nil;
    eventsView_ = nil;
    [super releaseSubviews];
}

- (void) applyColorAppearance {
    UITraitCollection *traits(self.traitCollection);
    UIColor *background([UIColor cydiaColorForRole:CydiaColorRoleBackground
                                     traitCollection:traits]);
    UIColor *grouped([UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                  traitCollection:traits]);
    self.view.backgroundColor = grouped;
    headerView_.backgroundColor = grouped;
    eventsView_.backgroundColor = background;
    eventsView_.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                            traitCollection:traits];
    titleLabel_.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
                                       traitCollection:traits];
    statusLabel_.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                        traitCollection:traits];
    progressView_.progressTintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent
                                                  traitCollection:traits];
    progressView_.trackTintColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                               traitCollection:traits];
}

- (void) applyTypography {
    UITraitCollection *traits(self.traitCollection);
    titleLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline
                              compatibleWithTraitCollection:traits];
    statusLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline
                               compatibleWithTraitCollection:traits];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection))
        [self applyColorAppearance];
    if (self.isViewLoaded && (previousTraitCollection == nil ||
        ![self.traitCollection.preferredContentSizeCategory isEqualToString:
            previousTraitCollection.preferredContentSizeCategory])) {
        BOOL follow([self shouldFollowEventTail]);
        [self applyTypography];
        [eventsView_ reloadData];
        [headerView_ setNeedsLayout];
        [eventsView_ setNeedsLayout];
        if (follow && [renderedState_.events count] != 0) {
            __weak ProgressController *weakSelf(self);
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf scrollToLastEventAnimated:NO];
            });
        }
    }
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.barStyle = UIBarStyleDefault;
    CydiaProgressViewState *state([progressModel_ state]);
    CydiaProgressViewState *previous(renderedState_);
    renderedState_ = state;
    [self renderState:state previous:previous change:CydiaProgressViewModelChangeNone];
}

- (NSString *) accessibilityPercentForState:(CydiaProgressViewState *)state {
    if (!state.progressDeterminate)
        return UCLocalize("UNKNOWN");
    return [NSNumberFormatter localizedStringFromNumber:@(state.displayPercent)
                                            numberStyle:NSNumberFormatterPercentStyle];
}

- (CydiaProgressFinishAction) effectiveFinishActionForState:(CydiaProgressViewState *)state {
    return CydiaProgressEffectiveFinishAction(state.finishAction, Finish_);
}

- (NSString *) effectiveFinishTitleForState:(CydiaProgressViewState *)state {
    CydiaProgressFinishAction action([self effectiveFinishActionForState:state]);
    if (action == CydiaProgressFinishActionNone)
        return nil;
    if (action == state.finishAction && [state.finishTitle length] != 0)
        return state.finishTitle;
    return UCLocalizeEx(CydiaProgressFinishLocalizationKey(action));
}

- (NSString *) accessibilityValueForState:(CydiaProgressViewState *)state {
    NSString *percent([self accessibilityPercentForState:state]);
    NSString *finishTitle([self effectiveFinishTitleForState:state]);
    if (state.running || [finishTitle length] == 0)
        return percent;
    return [NSString stringWithFormat:UCLocalize("COMMA_DELIMITED"),
        percent, finishTitle];
}

- (BOOL) eventsWereAppendedFrom:(NSArray *)previous to:(NSArray *)events {
    if ([previous count] > [events count])
        return NO;
    for (NSUInteger index(0); index != [previous count]; ++index)
        if ([previous objectAtIndex:index] != [events objectAtIndex:index])
            return NO;
    return YES;
}

- (BOOL) shouldFollowEventTail {
    if ([renderedState_.events count] == 0)
        return YES;
    CGFloat visibleBottom(CGRectGetMaxY(eventsView_.bounds));
    return eventsView_.contentSize.height - visibleBottom <= 72.0;
}

- (void) scrollToLastEventAnimated:(BOOL)animated {
    NSUInteger count([renderedState_.events count]);
    if (count == 0)
        return;
    [eventsView_ scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:count - 1 inSection:0]
                       atScrollPosition:UITableViewScrollPositionBottom
                               animated:animated];
}

- (void) renderEventsFromState:(CydiaProgressViewState *)state
                      previous:(CydiaProgressViewState *)previous {
    NSArray *oldEvents(previous == nil ? @[] : previous.events);
    NSArray *newEvents(state.events);
    BOOL appended([self eventsWereAppendedFrom:oldEvents to:newEvents]);
    BOOL follow([oldEvents count] == 0 || [self shouldFollowEventTail]);
    if (previous == nil || !appended) {
        [eventsView_ reloadData];
    } else if ([oldEvents count] != [newEvents count]) {
        /* iOS 12 can retain an estimated height for a newly inserted
         * multiline cell. A nonanimated reload commits final Auto Layout
         * heights while preserving this immutable state's event order. */
        [eventsView_ reloadData];
    }
    if (follow && [newEvents count] != 0) {
        __weak ProgressController *weakSelf(self);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf scrollToLastEventAnimated:NO];
        });
    }
}

- (void) redrawCompletedHierarchy {
    /* Completion replaces both navigation actions and the running title in a
     * single model publication. Refresh the already-ordered rows as well so
     * old CoreAnimation tiles cannot survive that terminal presentation. */
    [eventsView_ reloadData];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [headerView_ setNeedsDisplay];
    [eventsView_ setNeedsDisplay];
    for (UITableViewCell *cell in [eventsView_ visibleCells])
        [cell setNeedsDisplay];
    [self.view setNeedsDisplay];
}

- (void) renderState:(CydiaProgressViewState *)state
             previous:(CydiaProgressViewState *)previous
               change:(CydiaProgressViewModelChange)change {
    if (state == nil || !self.isViewLoaded)
        return;
    NSString *title(state.localizedTitle ?: state.rawTitle ?: @"");
    titleLabel_.text = title;
    self.navigationItem.title = title;
    statusLabel_.text = state.statusText ?: @"";
    statusLabel_.accessibilityLabel = statusLabel_.text;
    progressView_.accessibilityLabel = state.running ?
        UCLocalize("RUNNING") : UCLocalize("COMPLETE");
    progressView_.accessibilityValue = [self accessibilityValueForState:state];
    [progressView_ setProgress:state.displayPercent
                      animated:previous != nil &&
                               (change & CydiaProgressViewModelChangeMetrics) != 0];
    [self updateNavigationActionsForState:state];

    if (previous == nil ||
        (change & CydiaProgressViewModelChangeEvents) != 0 ||
        ![previous.events isEqualToArray:state.events])
        [self renderEventsFromState:state previous:previous];

    if (previous != nil && previous.running && !state.running)
        [self redrawCompletedHierarchy];
}

- (void) updateNavigationActionsForState:(CydiaProgressViewState *)state {
    BOOL cancellable(state.cancellationState == CydiaProgressCancellationAvailable);
    self.navigationItem.leftBarButtonItem = cancellable ? cancelItem_ : nil;

    CydiaProgressFinishAction action([self effectiveFinishActionForState:state]);
    BOOL finished(!state.running && action != CydiaProgressFinishActionNone);
    NSString *finishTitle([self effectiveFinishTitleForState:state]);
    finishItem_.title = [finishTitle length] == 0 ? UCLocalize("CLOSE") : finishTitle;
    self.navigationItem.rightBarButtonItem = finished ? finishItem_ : nil;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void) tableView;
    (void) section;
    return (NSInteger) [renderedState_.events count];
}

- (UITableViewCell *) tableView:(UITableView *)tableView
          cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    CydiaProgressEventCell *cell([tableView
        dequeueReusableCellWithIdentifier:CydiaProgressEventCellIdentifier
                              forIndexPath:indexPath]);
    [cell configureWithEvent:[renderedState_.events objectAtIndex:(NSUInteger) indexPath.row]];
    return cell;
}

- (void) dismissProgressInterface {
    [[[self navigationController] parentOrPresentingViewController]
        dismissModalViewControllerAnimated:YES];
}

- (void) close {
    UpdateExternalStatus(0);

    id<ProgressControllerDelegate> delegate(self.delegate);
    CydiaProgressFinishAction action(CydiaProgressEffectiveFinishAction(
        [[progressModel_ state] finishAction], Finish_));
    CydiaProgressFinishPlan plan(CydiaProgressFinishPlanForAction(action));
    if (plan.savesState)
        [delegate saveState];

    switch (plan.sideEffect) {
        case CydiaProgressFinishSideEffectNone:
            _assume(false);
        break;

        case CydiaProgressFinishSideEffectReturnToCydia:
            [delegate returnToCydia];
        break;

        case CydiaProgressFinishSideEffectTerminate:
            [delegate terminateWithSuccess];
        break;

        case CydiaProgressFinishSideEffectReloadSpringBoard: {
            _trace();
            UIProgressHUD *hud([delegate addProgressHUD]);
            [hud setText:UCLocalize("LOADING")];
            [(NSObject *) delegate performSelector:@selector(reloadSpringBoard)
                                         withObject:nil afterDelay:0.5];
            return;
        }

        case CydiaProgressFinishSideEffectRebootDevice:
            _trace();
            CydiaReboot(RB_AUTOBOOT);
        break;
    }

    if (plan.dismissesController)
        [self dismissProgressInterface];
}

- (void) setTitle:(NSString *)title {
    [progressModel_ setTitle:title];
}

- (void) invoke:(NSInvocation *)invocation withTitle:(NSString *)title {
    UpdateExternalStatus(1);
    [progressModel_ beginWithTitle:title];

    std::string notifyconf(FileFingerprint(NotifyConfig_));
    std::string springlist(FileFingerprint(SpringBoard_));

    if (invocation != nil) {
        [invocation yieldToSelector:@selector(invoke)];
        [self setTitle:@"COMPLETE"];
    }

    if (Finish_ < 4 && notifyconf != FileFingerprint(NotifyConfig_))
        Finish_ = 4;
    if (Finish_ < 3 && springlist != FileFingerprint(SpringBoard_))
        Finish_ = 3;
    if (Finish_ < 2 && RestartSubstrate_)
        Finish_ = 2;

    RestartSubstrate_ = false;
    UpdateExternalStatus(Finish_ == 0 ? 0 : 2);
    [progressModel_ completeWithFinishAction:static_cast<CydiaProgressFinishAction>(Finish_)];
}

- (void) addProgressEvent:(CydiaProgressEvent *)event {
    [progressModel_ addProgressEvent:event];
}

- (bool) isProgressCancelled {
    return [progressModel_ isProgressCancelled];
}

- (void) cancel {
    [progressModel_ requestCancellation];
}

- (void) setCancellable:(bool)cancellable {
    [progressModel_ setCancellable:cancellable];
}

- (void) setProgressCancellable:(NSNumber *)cancellable {
    [progressModel_ setProgressCancellable:cancellable];
}

- (void) setProgressPercent:(NSNumber *)percent {
    [progressModel_ setProgressPercent:percent];
}

- (void) setProgressStatus:(NSDictionary *)status {
    [progressModel_ setProgressStatus:status];
}

- (void) progressViewModel:(CydiaProgressViewModel *)model
           didPublishState:(CydiaProgressViewState *)state
                    change:(CydiaProgressViewModelChange)change {
    (void) model;
    CydiaProgressViewState *previous(renderedState_);
    renderedState_ = state;
    [self renderState:state previous:previous change:change];
}

@end
