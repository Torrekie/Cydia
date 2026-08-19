/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/ChangeControllers.h"

#include "Cydia/Appearance.h"
#include "Cydia/AppState.h"
#include "Cydia/ControllerState.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/NSString+Cydia.h"
#include "Cydia/Package.h"
#include "Cydia/Section.h"
#include "CyteKit/Localize.h"
#include "Menes/Menes.h"
#include "Substrate.hpp"
#include "iPhonePrivate.h"

// Match MobileCydia's release build: profiling and trace logging are no-ops.
#undef _trace
#define _trace(args...)
#undef _profile
#define _profile(name) {
#undef _end
#define _end }

/* Changes Controller {{{ */
@implementation ChangesController

- (NSURL *) referrerURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/changes/", UI_]];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://changes"];
}

- (Package *) packageAtIndexPath:(NSIndexPath *)path {
@synchronized (database_) {
    if ([database_ era] != era_)
        return nil;

    NSUInteger sectionIndex([path section]);
    if (sectionIndex >= [sections_ count])
        return nil;
    Section *section([sections_ objectAtIndex:sectionIndex]);
    NSInteger row([path row]);
    return [packages_ objectAtIndex:([section row] + row)];
} }

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"norefresh"])
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
}

- (void) setLeftBarButtonItem {
    NSObject<CydiaDelegate> *delegate((NSObject<CydiaDelegate> *) [self delegate]);
    if ([delegate updating])
        [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("CANCEL")
            style:UIBarButtonItemStyleDone
            target:self
            action:@selector(cancelButtonClicked)
        ] animated:YES];
    else
        [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("REFRESH")
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(refreshButtonClicked)
        ] animated:YES];
}

- (void) refreshButtonClicked {
    if ([(NSObject<CydiaDelegate> *) [self delegate] requestUpdate])
        [self setLeftBarButtonItem];
}

- (void) cancelButtonClicked {
    [(NSObject<CydiaDelegate> *) [self delegate] cancelUpdate];
}

- (void) upgradeButtonClicked {
    [(NSObject<CydiaDelegate> *) [self delegate] distUpgrade];
    [[self navigationItem] setRightBarButtonItem:nil animated:YES];
}

- (bool) shouldYield {
    return true;
}

- (bool) shouldBlock {
    return true;
}

- (void) useFilter {
@synchronized (self) {
    [self setFilter:[](Package *package) {
        return [package upgradableAndEssential:YES] || [package visible];
    }];

    [self setSorter:[](NSMutableArray *packages) {
        [packages radixSortUsingFunction:reinterpret_cast<MenesRadixSortFunction>(&PackageChangesRadix) withContext:NULL];
    }];
} }

- (id) initWithDatabase:(Database *)database {
    if ((self = [super initWithDatabase:database title:UCLocalize("CHANGES")]) != nil) {
        [self useFilter];
    } return self;
}

- (void) viewDidLoad {
    [super viewDidLoad];
    [self setLeftBarButtonItem];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setLeftBarButtonItem];
}

- (void) reloadData {
    [self setLeftBarButtonItem];
    [super reloadData];
}

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages {
    NSMutableArray *sections([NSMutableArray arrayWithCapacity:16]);

    Section *upgradable = [[Section alloc] initWithName:UCLocalize("AVAILABLE_UPGRADES") localize:NO];
    Section *ignored = nil;
    Section *section = nil;
    time_t last = 0;

    size_t upgrades_ = 0;
    bool unseens = false;

    CFDateFormatterRef formatter(CFDateFormatterCreate(NULL, Locale_, kCFDateFormatterMediumStyle, kCFDateFormatterMediumStyle));

    for (size_t offset = 0, count = [packages count]; offset != count; ++offset) {
        Package *package = [packages objectAtIndex:offset];

        BOOL uae = [package upgradableAndEssential:YES];

        if (!uae) {
            unseens = true;
            time_t seen([package seen]);

            if (section == nil || last != seen) {
                last = seen;

                NSString *name;
                name = CFBridgingRelease(CFDateFormatterCreateStringWithDate(NULL, formatter, (CFDateRef) [NSDate dateWithTimeIntervalSince1970:seen]));

                _profile(ChangesController$reloadData$Allocate)
                    name = [NSString stringWithFormat:UCLocalize("NEW_AT"), name];
                    section = [[Section alloc] initWithName:name row:offset localize:NO];
                    [sections addObject:section];
                _end
            }

            [section addToCount];
        } else if ([package ignored]) {
            if (ignored == nil) {
                ignored = [[Section alloc] initWithName:UCLocalize("IGNORED_UPGRADES") row:offset localize:NO];
            }
            [ignored addToCount];
        } else {
            ++upgrades_;
            [upgradable addToCount];
        }
    }
    _trace();

    CFRelease(formatter);

    if (unseens) {
        Section *last = [sections lastObject];
        size_t count = [last count];
        [packages removeObjectsInRange:NSMakeRange([packages count] - count, count)];
        [sections removeLastObject];
    }

    if ([ignored count] != 0)
        [sections insertObject:ignored atIndex:0];
    if (upgrades_ != 0)
        [sections insertObject:upgradable atIndex:0];

    [[self navigationItem] setRightBarButtonItem:(upgrades_ == 0 ? nil : [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:UCLocalize("PARENTHETICAL"), UCLocalize("UPGRADE"), [NSString stringWithFormat:@"%zu", upgrades_]]
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(upgradeButtonClicked)
    ]) animated:YES];

    return sections;
}

@end
/* }}} */
/* Search Controller {{{ */
@interface SearchController () <UISearchBarDelegate>
@end

@implementation SearchController {
    _H<UISearchBar, 1> search_;
    BOOL searchloaded_;
    bool summary_;
}

- (NSURL *) referrerURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/search?q=%@", UI_, [([search_ text] ?: @"") stringByAddingPercentEscapesIncludingReserved]]];
}

- (NSURL *) navigationURL {
    if ([search_ text] == nil || [[search_ text] isEqualToString:@""])
        return [NSURL URLWithString:@"cydia://search"];
    else
        return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://search/%@", [[search_ text] stringByAddingPercentEscapesIncludingReserved]]];
}

- (NSArray *) termsForQuery:(NSString *)query {
    NSMutableArray *terms([NSMutableArray arrayWithCapacity:2]);
    for (NSString *component in [query componentsSeparatedByString:@" "])
        if ([component length] != 0)
            [terms addObject:component];

    return terms;
}

- (void) useSearch {
    _H<NSArray> query([self termsForQuery:[search_ text]]);
    summary_ = false;

@synchronized (self) {
    [self setFilter:[=](Package *package) {
        if (![package unfiltered])
            return false;
        if (![package matches:query])
            return false;
        return true;
    }];

    [self setSorter:[](NSMutableArray *packages) {
        [packages radixSortUsingSelector:@selector(rank)];
    }];
}

    [self clearData];
    [self reloadData];
}

- (void) usePrefix:(NSString *)prefix {
    _H<NSString> query(prefix);
    summary_ = true;

@synchronized (self) {
    [self setFilter:[=](Package *package) {
        if ([query length] == 0)
            return false;
        if (![package unfiltered])
            return false;
        if ([query length] > [[package name] length])
            return false;
        if ([[package name] compare:query options:MatchCompareOptions_ range:NSMakeRange(0, [query length])] != NSOrderedSame)
            return false;
        return true;
    }];

    [self setSorter:nullptr];
}

    [self reloadData];
}

- (void) searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [self clearData];
    [self usePrefix:[search_ text]];
}

- (void) searchBarButtonClicked:(UISearchBar *)searchBar {
    [search_ resignFirstResponder];
    [self useSearch];
}

- (void) searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [search_ setText:@""];
    [self searchBarButtonClicked:searchBar];
}

- (void) searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self searchBarButtonClicked:searchBar];
}

- (void) searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    [self usePrefix:text];
}

- (bool) shouldYield {
    return YES;
}

- (bool) shouldBlock {
    return !summary_;
}

- (bool) isSummarized {
    return summary_;
}

- (bool) showsSections {
    return false;
}

- (id) initWithDatabase:(Database *)database query:(NSString *)query {
    if ((self = [super initWithDatabase:database title:UCLocalize("SEARCH")])) {
        search_ = [[UISearchBar alloc] init];
        [search_ setPlaceholder:UCLocalize("SEARCH_EX")];
        [search_ setDelegate:self];

        UITextField *textField;
        if ([search_ respondsToSelector:@selector(searchField)])
            textField = [search_ searchField];
        else
            textField = MSHookIvar<UITextField *>(search_, "_searchField");

        [textField setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin];
        [textField setEnablesReturnKeyAutomatically:NO];
        [[self navigationItem] setTitleView:textField];

        if (query != nil)
            [search_ setText:query];
        [self useSearch];
    } return self;
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (!searchloaded_) {
        searchloaded_ = YES;
        [search_ setFrame:CGRectMake(0, 0, [[self view] bounds].size.width, 44.0f)];
        [search_ layoutSubviews];
    }

    if ([self isSummarized])
        [search_ becomeFirstResponder];
}

- (void) reloadData {
    [self resetCursor];
    [super reloadData];
}

- (void) didSelectPackage:(Package *)package {
    [search_ resignFirstResponder];
    [super didSelectPackage:package];
}

@end
/* }}} */
