/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
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

#include "Cydia/PackageControllers.h"

#include "Cydia/Appearance.h"
#include "Cydia/AppState.h"
#include "Cydia/Collation.hpp"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/ExternalURLPolicy.h"
#include "Cydia/LegacyUICompatibilityNativeCaller.h"
#include "Cydia/Package.h"
#include "Cydia/PackageArchitecturePresentation.h"
#include "Cydia/PackageDetailViewModel.h"
#include "Cydia/PackageLegacyIconLoader.h"
#include "Cydia/PackageViews.h"
#include "Cydia/PackageUnavailableController.h"
#include "Cydia/Section.h"
#include "Cydia/UIRouteContext.h"
#define ProfileTimes 0
#include "Cydia/Profile.hpp"

#include "CyteKit/Localize.h"
#include "CyteKit/extern.h"
#include "Menes/Menes.h"
#include "iPhonePrivate.h"

#define AlwaysReload 0
#define PrintTimes() do {} while (false)

@protocol CYPackageControllerApplicationDelegate <CydiaDelegate, NSObject>
- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForPackage:(Package *)package
                                                                              presenter:(id)presenter;
- (CyteViewController *)pageForURL:(NSURL *)URL
                           context:(NSObject<CyteWebNavigationContext> *)context
                      withReferrer:(NSString *)referrer;
- (BOOL)openCydiaURL:(NSURL *)URL context:(CydiaUIRouteContext *)context;
- (void)presentModalViewController:(UIViewController *)controller force:(BOOL)force;
- (void)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
@end

@interface PackageDetailController (CYPackageControllerProtected)
- (void)selectModifyAction:(CydiaPackageDetailModifyAction *)action;
- (void)updateWithViewModel:(CydiaPackageDetailViewModel *)viewModel
                 headerIcon:(UIImage *)headerIcon
                 reloadTable:(BOOL)reloadTable;
@end

namespace {

NSString *PackageVersionArchitectureFilter(NSString *name, Package *package) {
    const CydiaAPT::PackageSelector selector(CydiaAPT::ParsePackageSelector([name UTF8String]));
    if (selector.kind == CydiaAPT::PackageSelectorKind::Native)
        return [[package registeredArchitectures] firstObject];
    if (selector.kind == CydiaAPT::PackageSelectorKind::ExactArchitecture)
        return [NSString stringWithUTF8String:selector.architecture.c_str()];
    return nil;
}

NSURL *PackageRouteURL(NSString *URLString) {
    if (![URLString isKindOfClass:[NSString class]] || [URLString length] == 0)
        return nil;
    NSURL *destination([NSURL URLWithString:URLString]);
    if (destination == nil || [[destination scheme] length] == 0)
        return nil;
    NSString *scheme([[destination scheme] lowercaseString]);
    if ([scheme isEqualToString:@"cydia"] || [scheme isEqualToString:@"apptapp"])
        return destination;
    return CydiaExternalURLRouteURL(destination);
}

} // namespace

/* Package Controller {{{ */
@implementation CYPackageController

- (void) bindLegacyCompatibilitySessionForPackage:(Package *)package {
    if (legacyCompatibilitySession_ != nil &&
        [legacyCompatibilitySession_ isActive] &&
        [legacyCompatibilitySession_ target] == package)
        return;

    [legacyCompatibilitySession_ invalidate];
    legacyCompatibilitySession_ = nil;

    id delegate([self delegate]);
    if (package == nil || delegate == nil ||
        ![delegate respondsToSelector:@selector(
            legacyUICompatibilitySessionForPackage:presenter:)])
        return;

    CydiaLegacyUICompatibilityNativeSession *session(
        [(id<CYPackageControllerApplicationDelegate>)delegate
            legacyUICompatibilitySessionForPackage:package presenter:nil]);
    if (session == nil || ![session isActive]) {
        [session invalidate];
        return;
    }

    id identity([session invokeScope:@"Package"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"id"
        arguments:@[] targetOrigin:nil]);
    if (![identity isKindOfClass:[NSString class]] ||
        ![identity isEqualToString:[package id]]) {
        [session invalidate];
        return;
    }
    legacyCompatibilitySession_ = session;
}

- (void)cancelLegacyAlternateIconLoad {
    ++legacyIconGeneration_;
    [legacyIconLoader_ cancel];
    legacyIconLoader_ = nil;
    legacyIconIdentity_ = nil;
}

- (void)startLegacyAlternateIconLoadForViewModel:
        (CydiaPackageDetailViewModel *)viewModel {
    [self cancelLegacyAlternateIconLoad];
    NSString *identity([viewModel baseIdentity] ?: [viewModel identity]);
    NSUInteger generation(legacyIconGeneration_);
    __weak CYPackageController *weakSelf(self);
    CydiaPackageLegacyIconLoader *loader([[CydiaPackageLegacyIconLoader alloc]
        initWithPackageIdentity:identity completion:^(UIImage *image) {
            CYPackageController *strongSelf(weakSelf);
            if (strongSelf == nil || generation != strongSelf->legacyIconGeneration_)
                return;
            NSString *current([[strongSelf viewModel] baseIdentity] ?:
                [[strongSelf viewModel] identity]);
            if (![identity isEqualToString:current] ||
                ![identity isEqualToString:strongSelf->legacyIconIdentity_])
                return;
            strongSelf->legacyIconLoader_ = nil;
            if (image != nil)
                [strongSelf updateHeaderIcon:image];
        }]);
    if (loader == nil)
        return;
    legacyIconIdentity_ = [identity copy];
    legacyIconLoader_ = loader;
    [loader start];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@", (id) name_]];
}

- (Package *) packageForAction {
    /* A source refresh advances Database.era and invalidates Package handles
     * retained by an already-visible detail controller.  Re-resolve by the
     * immutable route identity immediately before every mutating action so a
     * visible button cannot silently become a no-op after that refresh. */
    Package *current([database_ packageWithName:name_]);
    if (current == nil || ![[current fullVersion] isEqualToString:[[self viewModel] fullVersion]] ||
        ![[current architecture] isEqual:[[self viewModel] architecture]]) {
        /* A refresh may replace the candidate or make a formerly unique
         * selector ambiguous. Show that new state before accepting a click. */
        [self reloadData];
        return nil;
    }
    if (package_ != current) {
        package_ = current;
        [self bindLegacyCompatibilitySessionForPackage:current];
    }
    return current;
}

- (void) _clickButtonWithPackage:(Package *)package {
    Package *current([self packageForAction]);
    for (Package *version in [current availableVersions])
        if ([[version id] isEqualToString:[package id]] &&
            [[version fullVersion] isEqualToString:[package fullVersion]] &&
            [[version architecture] isEqual:[package architecture]])
            return [self.delegate installPackage:version];
    [self reloadData];
}

- (void) _clickButtonWithName:(NSString *)name {
    Package *package([self packageForAction]);
    if (package == nil)
        return;
    if ([name isEqualToString:@"CLEAR"])
        return [self.delegate clearPackage:package];
    else if ([name isEqualToString:@"REMOVE"])
        return [self.delegate removePackage:package];
    else if ([name isEqualToString:@"PURGE"] || [name isEqualToString:@"PACKAGE_PURGE_ACTION"])
        return [self.delegate purgePackage:package];
    else if ([name isEqualToString:@"REINSTALL"])
        return [self.delegate reinstallPackage:package];
    else if ([name isEqualToString:@"DOWNGRADE"] || [name isEqualToString:@"PACKAGE_VERSIONS"]) {
        for (CydiaPackageDetailModifyAction *action in [[self viewModel] modifyActions])
            if ([action kind] == CydiaPackageDetailModifyActionKindVersions)
                return [self selectModifyAction:action];
        return;
    }
    else if ([name isEqualToString:@"INSTALL"]);
    else if ([name isEqualToString:@"UPGRADE"]);
    else _assert(false);

    [self.delegate installPackage:package_];
}

- (void) actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)button {
    NSString *context([sheet context]);
    if (sheet_ == sheet)
        sheet_ = nil;

    if ([context isEqualToString:@"modify"]) {
        if (button != [sheet cancelButtonIndex]) {
            if (IsWildcat_)
                [self performSelector:@selector(_clickButtonWithName:) withObject:buttons_[button].first afterDelay:0];
            else
                [self _clickButtonWithName:buttons_[button].first];
        }

        [sheet dismissWithClickedButtonIndex:button animated:YES];
    } else if ([context isEqualToString:@"version"]) {
        if (button != [sheet cancelButtonIndex]) {
            Package *version([versions_ objectAtIndex:button]);
            if (IsWildcat_)
                [self performSelector:@selector(_clickButtonWithPackage:) withObject:version afterDelay:0];
            else
                [self _clickButtonWithPackage:version];
        }

        [sheet dismissWithClickedButtonIndex:button animated:YES];
    }
}

- (bool) _allowJavaScriptPanel {
    return commercial_;
}

#if !AlwaysReload
- (void) _customButtonClicked {
    [self modifyButtonClicked];
}

- (void) customButtonClicked {
    [self _customButtonClicked];
}

- (void) applyLoadingTitle {
    // Don't show "Loading" as the title. Ever.
}

- (UIBarButtonItem *) rightButton {
    if (button_ != nil)
        return button_;
    return self.navigationItem.rightBarButtonItem;
}
#endif

- (void) setPageColor:(UIColor *)color {
    [super setPageColor:color];
}

- (id) initWithDatabase:(Database *)database forPackage:(NSString *)name withReferrer:(NSString *)referrer {
    (void) referrer;
    Package *package([database packageWithName:name]);
    CydiaPackageDetailViewModel *viewModel(package == nil ? nil :
        [[CydiaPackageDetailViewModel alloc] initWithPackage:package
            registeredArchitectures:[package registeredArchitectures]
            versionArchitecture:PackageVersionArchitectureFilter(name, package)]);
    if (viewModel == nil)
        return nil;
    if ((self = [super initWithViewModel:viewModel
                              headerIcon:[package icon]
                                delegate:self]) != nil) {
        database_ = database;
        name_ = [name copy];
        [self synchronizeLegacyStateWithPackage:package viewModel:viewModel];
    } return self;
}

- (void)dealloc {
    [legacyCompatibilitySession_ invalidate];
    [self cancelLegacyAlternateIconLoad];
}

- (void) synchronizeLegacyStateWithPackage:(Package *)package
                                  viewModel:(CydiaPackageDetailViewModel *)viewModel {
    package_ = package;
    versions_ = [package availableVersions] ?: @[];
    commercial_ = [viewModel isCommercial];

    buttons_.clear();
    for (CydiaPackageDetailModifyAction *action in [viewModel modifyActions])
        buttons_.push_back(std::make_pair([action titleLocalizationKey],
            [[action titleLocalizationKey] hasPrefix:@"PACKAGE_"] ? [[NSBundle mainBundle]
                localizedStringForKey:[action titleLocalizationKey] value:[action titleLocalizationKey]
                table:@"Actions"] : UCLocalizeEx([action titleLocalizationKey])));
}

- (void) reloadData {
    [sheet_ dismissWithClickedButtonIndex:[sheet_ cancelButtonIndex] animated:YES];
    sheet_ = nil;
    Package *package([database_ packageWithName:name_]);
    CydiaPackageDetailViewModel *viewModel(package == nil ? nil :
        [[CydiaPackageDetailViewModel alloc] initWithPackage:package
            registeredArchitectures:[package registeredArchitectures]
            versionArchitecture:PackageVersionArchitectureFilter(name_, package)]);
    [self bindLegacyCompatibilitySessionForPackage:package];
    if (viewModel != nil) {
        [self synchronizeLegacyStateWithPackage:package viewModel:viewModel];
        /* PackageDetailController reloadData performs the one table reload
         * after the model is rebound.  Avoid the old update-then-super double
         * reload: UITableView may create two depiction cells before the first
         * WK load settles, yielding duplicate initial GETs. */
        [self updateWithViewModel:viewModel
                       headerIcon:[package icon]
                       reloadTable:NO];
        [self startLegacyAlternateIconLoadForViewModel:viewModel];
    } else {
        [self cancelLegacyAlternateIconLoad];
        package_ = nil;
        versions_ = @[];
        buttons_.clear();
        self.navigationItem.rightBarButtonItem = nil;
        button_ = nil;
        PackageUnavailableController *unavailable([[PackageUnavailableController alloc]
            initWithDatabase:database_ forPackage:name_ withReferrer:nil]);
        NSMutableArray *stack([self.navigationController.viewControllers mutableCopy]);
        NSUInteger index([stack indexOfObjectIdenticalTo:self]);
        if (unavailable != nil && stack != nil && index != NSNotFound) {
            [unavailable setDelegate:self.delegate];
            [stack replaceObjectAtIndex:index withObject:unavailable];
            [self.navigationController setViewControllers:stack animated:NO];
        }
        return;
    }
    [super reloadData];
    if ([self isViewLoaded])
        button_ = self.navigationItem.rightBarButtonItem;
}

- (bool) isLoading {
    return false;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    button_ = self.navigationItem.rightBarButtonItem;
    [self bindLegacyCompatibilitySessionForPackage:package_];
}

- (void)packageDetailController:(PackageDetailController *)controller
          didSelectModifyAction:(CydiaPackageDetailModifyAction *)action
                   versionChoice:(CydiaPackageDetailVersionChoice *)versionChoice {
    if (controller != self)
        return;
    Package *package([self packageForAction]);
    if (package == nil)
        return;
    /* Account authorization must not turn an old visible action into a new
     * candidate, a different source, or an action now blocked by a hold. */
    CydiaPackageDetailViewModel *fresh([[CydiaPackageDetailViewModel alloc]
        initWithPackage:package registeredArchitectures:[package registeredArchitectures]
        versionArchitecture:PackageVersionArchitectureFilter(name_, package)]);
    if (!CydiaPackageDetailCanPerformAction(self.viewModel, fresh, action.kind)) {
        [self reloadData]; return;
    }
    switch ([action kind]) {
        case CydiaPackageDetailModifyActionKindClear:
            return [self.delegate clearPackage:package];
        case CydiaPackageDetailModifyActionKindRemove:
            return [self.delegate removePackage:package];
        case CydiaPackageDetailModifyActionKindPurge:
            return [self.delegate purgePackage:package];
        case CydiaPackageDetailModifyActionKindReinstall:
            return [self.delegate reinstallPackage:package];
        case CydiaPackageDetailModifyActionKindInstall:
        case CydiaPackageDetailModifyActionKindUpgrade:
        case CydiaPackageDetailModifyActionKindDowngrade:
            return [self.delegate installPackage:package];
        case CydiaPackageDetailModifyActionKindVersions:
            break;
        case CydiaPackageDetailModifyActionKindAccount:
            return; // Handled by the native account controller, never a package mutation.
    }

    if (versionChoice == nil)
        return;
    for (Package *version in [package availableVersions])
        if ([[version id] isEqualToString:[versionChoice identity]] &&
            [[version fullVersion] isEqualToString:[versionChoice fullVersion]] &&
            [[version architecture] isEqual:[versionChoice architecture]])
            return [self.delegate installPackage:version];
    [self reloadData];
}

- (void)packageDetailController:(PackageDetailController *)controller
         didSelectNavigationKind:(CydiaPackageDetailNavigationKind)kind
                       URLString:(NSString *)URLString
                      identifier:(NSString *)identifier {
    if (controller != self)
        return;
    id<CYPackageControllerApplicationDelegate> application((id)[self delegate]);
    if (kind == CydiaPackageDetailNavigationKindApplication) {
        if ([identifier length] != 0 &&
            [application respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)])
            [application launchApplicationWithIdentifier:identifier suspended:NO];
        return;
    }

    NSURL *route(PackageRouteURL(URLString));
    if (route == nil ||
        ![application respondsToSelector:@selector(pageForURL:context:withReferrer:)])
        return;

    CydiaUIRouteContext *context;
    if (kind == CydiaPackageDetailNavigationKindDepictionLink) {
        NSURL *origin([NSURL URLWithString:[[self viewModel] depictionURLString]]);
        context = [CydiaUIRouteContext repositoryDepictionContextWithOrigin:origin
            packageIdentity:[[self viewModel] identity] mainFrame:YES userGesture:YES];
        if (context == nil)
            context = [CydiaUIRouteContext untrustedWebPageContextWithOrigin:origin
                mainFrame:YES userGesture:YES];

        /* External depiction handoffs must go through the application
         * coordinator.  The package controller is a transient child and its
         * navigationController can be absent or no longer be the selected
         * stack while the tab transition settles.  The shared coordinator
         * owns that selected-stack check, pending external coalescing, and
         * the same typed route policy used by direct cydia://url/ callers.
         * Keep the pageForURL path below as a compatibility fallback for
         * coordinators predating openCydiaURL:context:. */
        NSError *routeError(nil);
        CydiaUIRouteDescriptor *descriptor(CydiaUIParseRouteURL(route, &routeError));
        if ([descriptor kind] == CydiaUIRouteKindExternalOpen &&
            [application respondsToSelector:@selector(openCydiaURL:context:)]) {
            [application openCydiaURL:route context:context];
            /* A rejected/pending handoff is terminal too: do not route a
             * second time through a controller fallback after that decision. */
            return;
        }
    } else {
        context = [CydiaUIRouteContext trustedNativeContext];
    }

    CyteViewController *page([application pageForURL:route context:context
        withReferrer:[[self.navigationURL absoluteString] copy]]);
    if (page == nil)
        return;
    [page setDelegate:application];
    if (kind == CydiaPackageDetailNavigationKindContact &&
        [application respondsToSelector:@selector(presentModalViewController:force:)]) {
        /* Legacy package support used a modal web shell with Close and
         * Reload controls.  Keep that navigation boundary while replacing
         * its body with the native Support controller. */
        [application presentModalViewController:page force:NO];
        return;
    }
    [self.navigationController pushViewController:page animated:YES];
}

@end
/* }}} */

/* Package List Controller {{{ */
@implementation PackageListController

- (NSURL *) referrerURL {
    return [self navigationURL];
}

- (bool) isSummarized {
    return false;
}

- (bool) showsSections {
    return true;
}

- (void) didSelectPackage:(Package *)package {
    CYPackageController *view([[CYPackageController alloc] initWithDatabase:database_ forPackage:[package id] withReferrer:[[self referrerURL] absoluteString]]);
    if (view == nil)
        return;
    [view setDelegate:self.delegate];
    [[self navigationController] pushViewController:view animated:YES];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)list {
    NSInteger count([sections_ count]);
    return count == 0 ? 1 : count;
}

- (NSString *) tableView:(UITableView *)list titleForHeaderInSection:(NSInteger)section {
    if ([sections_ count] == 0 || [[sections_ objectAtIndex:section] count] == 0)
        return nil;
    return [[sections_ objectAtIndex:section] name];
}

- (NSInteger) tableView:(UITableView *)list numberOfRowsInSection:(NSInteger)section {
    if ([sections_ count] == 0)
        return 0;
    return [[sections_ objectAtIndex:section] count];
}

- (Package *) packageAtIndexPath:(NSIndexPath *)path {
@synchronized (database_) {
    if ([database_ era] != era_)
        return nil;

    Section *section([sections_ objectAtIndex:[path section]]);
    NSInteger row([path row]);
    Package *package([packages_ objectAtIndex:([section row] + row)]);
    return package;
} }

- (UITableViewCell *) tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    PackageCell *cell((PackageCell *) [table dequeueReusableCellWithIdentifier:@"Package"]);
    if (cell == nil)
        cell = [[PackageCell alloc] init];

    Package *package([database_ packageWithName:[[self packageAtIndexPath:path] id]]);
    [cell setPackage:package asSummary:[self isSummarized]];
    return cell;
}

- (void) tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    Package *package([self packageAtIndexPath:path]);
    package = [database_ packageWithName:[package id]];
    [self didSelectPackage:package];
}

- (NSArray *) sectionIndexTitlesForTableView:(UITableView *)tableView {
    return thumbs_;
}

- (NSInteger) tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
    return offset_[index];
}

- (CGFloat) rowHeight {
    return [self isSummarized] ? 38 : 73;
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    Package *package([self packageAtIndexPath:indexPath]);
    return [self rowHeight] + ([[PackageCell architectureCaptionForPackage:package] length] == 0 ? 0 : 17);
}

- (id) initWithDatabase:(Database *)database title:(NSString *)title {
    if ((self = [super initWithTitle:title]) != nil) {
        database_ = database;
    } return self;
}

- (void) releaseSubviews {
    packages_ = nil;
    sections_ = nil;

    thumbs_ = nil;
    offset_.clear();

    [super releaseSubviews];
}

- (bool) shouldBlock {
    return false;
}

- (NSMutableArray *) _reloadPackages {
@synchronized (database_) {
    era_ = [database_ era];
    NSArray *packages([database_ packages]);

    return [NSMutableArray arrayWithArray:packages];
} }

- (void) _reloadData {
    if (reloading_ != 0) {
        reloading_ = 2;
        return;
    }

    NSMutableArray *packages;

  reload:
    if ([self shouldYield]) {
        do {
            UIProgressHUD *hud;

            if (![self shouldBlock])
                hud = nil;
            else {
                hud = [self.delegate addProgressHUD];
                [hud setText:UCLocalize("LOADING")];
            }

            reloading_ = 1;
            packages = [self yieldToSelector:@selector(_reloadPackages)];

            if (hud != nil)
                [self.delegate removeProgressHUD:hud];
        } while (reloading_ == 2);
    } else {
        packages = [self _reloadPackages];
    }

@synchronized (database_) {
    if (era_ != [database_ era])
        goto reload;
    reloading_ = 0;

    thumbs_ = nil;
    offset_.clear();

    packages_ = packages;

    if ([self showsSections])
        sections_ = [self sectionsForPackages:packages];
    else {
        Section *section([[Section alloc] initWithName:nil row:0 localize:NO]);
        [section setCount:[packages_ count]];
        sections_ = [NSArray arrayWithObject:section];
    }

    [super _reloadData];
}

    PrintTimes();
}

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages {
    Section *prefix([[Section alloc] initWithName:nil row:0 localize:NO]);
    size_t end([packages count]);

    NSMutableArray *sections([NSMutableArray arrayWithCapacity:16]);
    Section *section(prefix);

    thumbs_ = CollationThumbs_;
    offset_ = CollationOffset_;

    size_t offset(0);
    size_t offsets([CollationStarts_ count]);

    NSString *start([CollationStarts_ objectAtIndex:offset]);
    size_t length([start length]);

    for (size_t index(0); index != end; ++index) {
        if (start != nil) {
            Package *package([packages objectAtIndex:index]);
            NSString *name(PackageName(package, @selector(cyname)));

            //while ([start compare:name options:NSNumericSearch range:NSMakeRange(0, length) locale:CollationLocale_] != NSOrderedDescending) {
            while (StringNameCompare(start, name, length) != kCFCompareGreaterThan) {
                NSString *title([CollationTitles_ objectAtIndex:offset]);
                section = [[Section alloc] initWithName:title row:index localize:NO];
                [sections addObject:section];

                start = ++offset == offsets ? nil : [CollationStarts_ objectAtIndex:offset];
                if (start == nil)
                    break;
                length = [start length];
            }
        }

        [section addToCount];
    }

    for (; offset != offsets; ++offset) {
        NSString *title([CollationTitles_ objectAtIndex:offset]);
        Section *section([[Section alloc] initWithName:title row:end localize:NO]);
        [sections addObject:section];
    }

    if ([prefix count] != 0) {
        Section *suffix([sections lastObject]);
        [prefix setName:[suffix name]];
        [suffix setName:nil];
        [sections insertObject:prefix atIndex:(offsets - 1)];
    }

    return sections;
}

@end
/* }}} */

/* Filtered Package List Controller {{{ */
@implementation FilteredPackageListController

- (void) setFilter:(PackageFilter)filter {
@synchronized (self) {
    filter_ = filter;
} }

- (void) setSorter:(PackageSorter)sorter {
@synchronized (self) {
    sorter_ = sorter;
} }

- (NSMutableArray *) _reloadPackages {
@synchronized (database_) {
    era_ = [database_ era];

    NSArray *packages([database_ packages]);
    NSMutableArray *filtered([NSMutableArray arrayWithCapacity:[packages count]]);

    PackageFilter filter;
    PackageSorter sorter;

    @synchronized (self) {
        filter = filter_;
        sorter = sorter_;
    }

    _profile(PackageTable$reloadData$Filter)
        for (Package *package in packages)
            if (filter(package))
                [filtered addObject:package];
    _end

    if (sorter)
        sorter(filtered);
    return filtered;
} }

- (id) initWithDatabase:(Database *)database title:(NSString *)title filter:(PackageFilter)filter {
    if ((self = [super initWithDatabase:database title:title]) != nil) {
        [self setFilter:filter];
    } return self;
}

@end
/* }}} */
