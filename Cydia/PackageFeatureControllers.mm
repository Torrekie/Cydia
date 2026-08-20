/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/PackageFeatureControllers.h"

#include "Cydia/Appearance.h"
#include "Cydia/AppState.h"
#include "Cydia/ControllerState.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/DpkgRunner.h"
#include "Cydia/Package.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/Section.h"
#include "CyteKit/Localize.h"
#include "Menes/Menes.h"
#include "iPhonePrivate.h"

#define AlwaysReload 0

/* Package Settings Controller {{{ */
@interface PackageSettingsController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation PackageSettingsController {
    __weak Database *database_;
    _H<NSString> name_;
    _H<Package> package_;
    _H<UITableView, 2> table_;
    _H<UISwitch> subscribedSwitch_;
    _H<UISwitch> ignoredSwitch_;
    _H<UITableViewCell> subscribedCell_;
    _H<UITableViewCell> ignoredCell_;
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@/settings", (id) name_]];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    if (package_ == nil)
        return 0;

    if ([package_ installed] == nil)
        return 1;
    else
        return 2;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (package_ == nil)
        return 0;

    // both sections contain just one item right now.
    return 1;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return nil;
}

- (NSString *) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return UCLocalize("SHOW_ALL_CHANGES_EX");
    else
        return UCLocalize("IGNORE_UPGRADES_EX");
}

- (void) onSubscribed:(id)control {
    bool value([control isOn]);
    if (package_ == nil)
        return;
    if ([package_ setSubscribed:value])
        [(NSObject<CydiaDelegate> *) [self delegate] updateData];
}

- (void) _updateIgnored {
    bool on([ignoredSwitch_ isOn]);

    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    const char *name([[package_ dpkgId] UTF8String]);
    std::string input(name == NULL ? "" : name);
    input += on ? " hold\n" : " install\n";

    CydiaRuntime::Dpkg::Runner runner(CydiaRuntime::Dpkg::Executable::Cydo);
    (void) runner.RunWithInput({paths.DpkgBinaryPath(), "--set-selections"}, input);
}

- (void) onIgnored:(id)control {
    NSInvocation *invocation([NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(_updateIgnored)]]);
    [invocation setTarget:self];
    [invocation setSelector:@selector(_updateIgnored)];

    [(NSObject<CydiaDelegate> *) [self delegate] reloadDataWithInvocation:invocation];
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (package_ == nil)
        return nil;

    switch ([indexPath section]) {
        case 0: return subscribedCell_;
        case 1: return ignoredCell_;

        _nodefault
    }

    return nil;
}

- (void) loadView {
    UIView *view([[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]]);
    [view setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
    [self setView:view];

    table_ = [[UITableView alloc] initWithFrame:[[self view] bounds] style:UITableViewStyleGrouped];
    if ([table_ respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)])
        [table_ setCellLayoutMarginsFollowReadableWidth:NO];
    [table_ setAutoresizingMask:CydiaAutoresizingFlexibleBoth];
    [(UITableView *) table_ setDataSource:self];
    [table_ setDelegate:self];
    [view addSubview:table_];

    subscribedSwitch_ = [[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 50, 20)];
    [subscribedSwitch_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    [subscribedSwitch_ addTarget:self action:@selector(onSubscribed:) forEvents:UIControlEventValueChanged];

    ignoredSwitch_ = [[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 50, 20)];
    [ignoredSwitch_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    [ignoredSwitch_ addTarget:self action:@selector(onIgnored:) forEvents:UIControlEventValueChanged];

    subscribedCell_ = [[UITableViewCell alloc] init];
    [subscribedCell_ setText:UCLocalize("SHOW_ALL_CHANGES")];
    [subscribedCell_ setAccessoryView:subscribedSwitch_];
    [subscribedCell_ setSelectionStyle:UITableViewCellSelectionStyleNone];

    ignoredCell_ = [[UITableViewCell alloc] init];
    [ignoredCell_ setText:UCLocalize("IGNORE_UPGRADES")];
    [ignoredCell_ setAccessoryView:ignoredSwitch_];
    [ignoredCell_ setSelectionStyle:UITableViewCellSelectionStyleNone];
}

- (void) viewDidLoad {
    [super viewDidLoad];
    [[self navigationItem] setTitle:UCLocalize("SETTINGS")];
}

- (void) releaseSubviews {
    ignoredCell_ = nil;
    subscribedCell_ = nil;
    table_ = nil;
    ignoredSwitch_ = nil;
    subscribedSwitch_ = nil;

    [super releaseSubviews];
}

- (id) initWithDatabase:(Database *)database package:(NSString *)package {
    if ((self = [super init]) != nil) {
        database_ = database;
        name_ = package;
    } return self;
}

- (void) reloadData {
    [super reloadData];

    package_ = [database_ packageWithName:name_];

    if (package_ != nil) {
        [subscribedSwitch_ setOn:([package_ subscribed] ? 1 : 0) animated:NO];
        [ignoredSwitch_ setOn:([package_ ignored] ? 1 : 0) animated:NO];
    } // XXX: what now, G?

    [table_ reloadData];
}

@end
/* }}} */
/* Installed Controller {{{ */
@implementation InstalledController {
    bool sectioned_;
}

- (NSURL *) referrerURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/installed/", UI_]];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://installed"];
}

- (void) useRecent {
    sectioned_ = false;

@synchronized (self) {
    [self setFilter:[](Package *package) {
        return ![package uninstalled] && package->role_ < 7;
    }];

    [self setSorter:[](NSMutableArray *packages) {
        [packages radixSortUsingSelector:@selector(recent)];
    }];
} }

- (void) useFilter:(UISegmentedControl *)segmented {
    NSInteger selected([segmented selectedSegmentIndex]);
    if (selected == 2)
        return [self useRecent];
    bool simple(selected == 0);
    sectioned_ = true;

@synchronized (self) {
    [self setFilter:[=](Package *package) {
        return ![package uninstalled] && package->role_ <= (simple ? 1 : 3);
    }];

    [self setSorter:nullptr];
} }

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages {
    if (sectioned_)
        return [super sectionsForPackages:packages];

    CFDateFormatterRef formatter(CFDateFormatterCreate(NULL, Locale_, kCFDateFormatterLongStyle, kCFDateFormatterNoStyle));

    NSMutableArray *sections([NSMutableArray arrayWithCapacity:16]);
    Section *section(nil);
    time_t last(0);

    for (size_t offset(0), count([packages count]); offset != count; ++offset) {
        Package *package([packages objectAtIndex:offset]);

        time_t upgraded([package upgraded]);
        if (upgraded < 1168364520)
            upgraded = 0;
        else
            upgraded -= upgraded % (60 * 60 * 24);

        if (section == nil || upgraded != last) {
            last = upgraded;

            NSString *name;
            if (upgraded == 0)
                continue; // XXX: name = UCLocalize("...");
            else {
                name = CFBridgingRelease(CFDateFormatterCreateStringWithDate(NULL, formatter, (CFDateRef) [NSDate dateWithTimeIntervalSince1970:upgraded]));
            }

            section = [[Section alloc] initWithName:name row:offset localize:NO];
            [sections addObject:section];
        }

        [section addToCount];
    }

    CFRelease(formatter);
    return sections;
}

- (id) initWithDatabase:(Database *)database {
    if ((self = [super initWithDatabase:database title:UCLocalize("INSTALLED")]) != nil) {
        UISegmentedControl *segmented([[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:UCLocalize("USER"), UCLocalize("EXPERT"), UCLocalize("RECENT"), nil]]);
        [segmented setSelectedSegmentIndex:0];
        [segmented setSegmentedControlStyle:UISegmentedControlStyleBar];
        [[self navigationItem] setTitleView:segmented];

        [segmented addTarget:self action:@selector(modeChanged:) forEvents:UIControlEventValueChanged];
        [self useFilter:segmented];

        [self queueStatusDidChange];
    } return self;
}

#if !AlwaysReload
- (void) queueButtonClicked {
    [(NSObject<CydiaDelegate> *) [self delegate] queue];
}
#endif

- (void) queueStatusDidChange {
#if !AlwaysReload
    if (Queuing_) {
        [[self navigationItem] setRightBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("QUEUE")
            style:UIBarButtonItemStyleDone
            target:self
            action:@selector(queueButtonClicked)
        ]];
    } else {
        [[self navigationItem] setRightBarButtonItem:nil];
    }
#endif
}

- (void) modeChanged:(UISegmentedControl *)segmented {
    [self useFilter:segmented];
    [self reloadData];
}

@end
/* }}} */
