/* Cydia Refurbished native Home simulator probe.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/HomeControllerProbe.h"

#if TARGET_OS_SIMULATOR && defined(CYDIA_HOME_SIMULATOR_PROBE)

#include "Cydia/HomeController.h"
#include "Cydia/HomeProbeURLProtocol.h"
#include "Cydia/FAQController.h"
#include "Cydia/UpgradingGuideController.h"
#include "Cydia/MoreSourcesController.h"
#include "Cydia/CopyingFilesGuideController.h"
#include "Cydia/HomeGuideController.h"
#include "Cydia/HomePlaceholderController.h"
#include "Cydia/HomeStorageController.h"
#include "Cydia/AppState.h"
#include "Cydia/Appearance.h"
#include "Cydia/UIRouteContext.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"
#include "CyteKit/extern.h"
#include "CyteKit/WebNavigationContext.h"

#include <cmath>
#include <unistd.h>

@interface HomeController (CydiaHomeProbePrivate)
- (UITraitCollection *)homeAppearanceTraits;
- (void)openExternalURL:(NSURL *)URL;
- (BOOL)openNativeRoute:(NSString *)route;
- (NSURL *)URLForHomeAction:(NSInteger)action;
- (void)cancelButtonClicked;
@end

@interface CydiaHomeProbeDestinationController : CyteViewController
@property(nonatomic, copy) NSString *URLString;
@end

@implementation CydiaHomeProbeDestinationController
- (NSURL *)navigationURL {
    return [NSURL URLWithString:self.URLString];
}

- (void)loadView {
    UIView *view([[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]]);
    view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground
                                       traitCollection:self.traitCollection];
    UILabel *label([[UILabel alloc] initWithFrame:CGRectInset(view.bounds, 24, 24)]);
    label.text = self.URLString;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
                                  traitCollection:self.traitCollection];
    label.autoresizingMask = CydiaAutoresizingFlexibleBoth;
    [view addSubview:label];
    self.view = view;
}
@end

@interface CydiaHomeProbeDelegate : NSObject
@property(nonatomic) BOOL updatingValue;
@property(nonatomic) NSUInteger requestUpdateCount;
@property(nonatomic) NSUInteger cancelUpdateCount;
@property(nonatomic) NSUInteger routeCount;
@property(nonatomic) NSUInteger fallbackRouteCount;
@property(nonatomic, copy) NSString *lastRoute;
@property(nonatomic, copy) NSString *lastReferrer;
@property(nonatomic, copy) NSString *lastExternalURL;
@end

@implementation CydiaHomeProbeDelegate
- (BOOL)updating {
    return self.updatingValue;
}

- (bool)requestUpdate {
    ++self.requestUpdateCount;
    self.updatingValue = YES;
    return YES;
}

- (void)cancelUpdate {
    ++self.cancelUpdateCount;
    self.updatingValue = NO;
}

- (CyteViewController *)pageForURL:(NSURL *)URL
                           context:(NSObject<CyteWebNavigationContext> *)context
                      withReferrer:(NSString *)referrer {
    ++self.routeCount;
    self.lastRoute = [URL absoluteString];
    self.lastReferrer = referrer;
    if ([[URL scheme].lowercaseString isEqualToString:@"cydia"] &&
        [[URL host].lowercaseString isEqualToString:@"home"] &&
        [[URL path] isEqualToString:@"/faq"]) {
        FAQController *faq([[FAQController alloc] init]);
        if (faq != nil)
            return faq;
    }
    if ([[URL scheme].lowercaseString isEqualToString:@"cydia"] &&
        [[URL host].lowercaseString isEqualToString:@"home"] &&
        [[URL path] hasPrefix:@"/upgrading-jailbreaking"]) {
        NSArray *parts = [[URL path] componentsSeparatedByString:@"/"];
        NSString *identifier = parts.count > 2 && [parts[2] length] != 0 ? parts[2] : @"root";
        UpgradingGuideController *guide([[UpgradingGuideController alloc]
            initWithPageIdentifier:identifier]);
        if (guide != nil) {
            [guide setDelegate:self];
            return guide;
        }
    }
    if ([CydiaUIParseRouteURL(URL, NULL) kind] == CydiaUIRouteKindMoreSources) {
        MoreSourcesController *guide = [[MoreSourcesController alloc] initWithProvider:
            [[CydiaMoreSourcesProvider alloc] initWithDatabase:nil]];
        [guide setDelegate:self];
        return guide;
    }
    if ([CydiaUIParseRouteURL(URL, NULL) kind] == CydiaUIRouteKindCopyingFiles) {
        CopyingFilesGuideController *guide = [[CopyingFilesGuideController alloc] init];
        [guide setDelegate:self];
        return guide;
    }
    CydiaUIRouteDescriptor *guideRoute = CydiaUIParseRouteURL(URL, NULL);
    if (guideRoute.kind == CydiaUIRouteKindHomeGuide) {
        CyteViewController *guide;
        if ([guideRoute.arguments[0] isEqualToString:@"storage"])
            guide = [[HomeStorageController alloc] init];
        else if ([[@[@"featured", @"themes", @"account"] copy]
                  containsObject:guideRoute.arguments[0]])
            guide = [[HomePlaceholderController alloc]
                initWithPageIdentifier:guideRoute.arguments[0]];
        else
            guide = [[HomeGuideController alloc]
                initWithPageIdentifier:guideRoute.arguments[0]];
        [guide setDelegate:self];
        return guide;
    }
    CydiaHomeProbeDestinationController *destination(
        [[CydiaHomeProbeDestinationController alloc] init]);
    destination.URLString = [URL absoluteString];
    (void)context;
    return destination;
}

- (BOOL)openCydiaURL:(NSURL *)URL context:(CydiaUIRouteContext *)context {
    ++self.fallbackRouteCount;
    self.lastRoute = [URL absoluteString];
    (void)context;
    return YES;
}
@end

@interface CydiaHomeProbeController : HomeController
@property(nonatomic, weak) CydiaHomeProbeDelegate *probeDelegate;
@end

@implementation CydiaHomeProbeController
- (void)openExternalURL:(NSURL *)URL {
    self.probeDelegate.lastExternalURL = [URL absoluteString];
    [super openExternalURL:URL];
}
@end

static UIView *HomeProbeFindView(UIView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqualToString:identifier])
        return root;
    for (UIView *child in root.subviews) {
        UIView *match(HomeProbeFindView(child, identifier));
        if (match != nil)
            return match;
    }
    return nil;
}

static UITableView *HomeProbeFindTableWithIdentifier(UIView *root, NSString *identifier) {
    UIView *view(HomeProbeFindView(root, identifier));
    return [view isKindOfClass:[UITableView class]] ? (UITableView *)view : nil;
}

static UITableView *HomeProbeFindGuideTable(UIView *root) {
    UITableView *table = HomeProbeFindTableWithIdentifier(root,
        @"cydia.home.upgrading.rows");
    return table != nil ? table : HomeProbeFindTableWithIdentifier(root,
        @"cydia.home.upgrading.master.rows");
}

// Keep the command's flat link ordinal stable when the root inserts its
// bulletin after primary links. Detail rows on the tools page are deliberately
// not actions, so use the production accessibility identity instead of making
// assumptions about section parity.
static NSArray<NSIndexPath *> *HomeProbeGuideActionPaths(UITableView *table) {
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
    NSInteger sections = [table.dataSource numberOfSectionsInTableView:table];
    for (NSInteger section = 0; section < sections; ++section) {
        NSInteger rows = [table.dataSource tableView:table numberOfRowsInSection:section];
        for (NSInteger row = 0; row < rows; ++row) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
            UITableViewCell *cell = [table.dataSource tableView:table
                cellForRowAtIndexPath:path];
            if ([cell.accessibilityIdentifier hasPrefix:@"cydia.home.upgrading.row."])
                [paths addObject:path];
        }
    }
    return paths;
}

static NSIndexPath *HomeProbeIndexPathForIdentifier(UITableView *table,
                                                     NSString *identifier) {
    NSInteger sections([table.dataSource numberOfSectionsInTableView:table]);
    for (NSInteger section(0); section != sections; ++section) {
        NSInteger count([table.dataSource tableView:table numberOfRowsInSection:section]);
        for (NSInteger row(0); row != count; ++row) {
            NSIndexPath *indexPath([NSIndexPath indexPathForRow:row inSection:section]);
            UITableViewCell *cell([table.dataSource tableView:table
                cellForRowAtIndexPath:indexPath]);
            if ([cell.accessibilityIdentifier isEqualToString:identifier])
                return indexPath;
        }
    }
    return nil;
}

static NSInteger HomeProbeLuminance(UIColor *color) {
    CGFloat red(0), green(0), blue(0), alpha(0), white(0);
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha] &&
        [color getWhite:&white alpha:&alpha])
        red = green = blue = white;
    return (NSInteger)lround(((red + green + blue) / 3.0) * 1000.0);
}

static BOOL HomeProbeSplitButtonContentLeadingAligned(UIButton *button) {
    if (button == nil || button.imageView == nil)
        return NO;
    [button layoutIfNeeded];
    UIView *imageView(button.imageView);
    CGRect frame([imageView.superview convertRect:imageView.frame toView:button]);
    CGFloat leading(button.effectiveUserInterfaceLayoutDirection ==
        UIUserInterfaceLayoutDirectionRightToLeft ?
        CGRectGetWidth(button.bounds) - CGRectGetMaxX(frame) : CGRectGetMinX(frame));
    /* The normal grouped-cell content margin is 15pt.  Keep a small
     * sub-pixel tolerance for UIButton's integral image rounding. */
    return leading >= 13.5 && leading <= 16.5;
}

/* On iOS 14 and later UITableViewCell draws from backgroundConfiguration and
 * may intentionally leave cell.backgroundColor clear.  Probe the layer that
 * actually owns the rendered surface before falling back to older UIKit
 * backgroundView/cell properties. */
static UIColor *HomeProbeEffectiveCellColor(UITableViewCell *cell) {
    if (cell == nil)
        return nil;
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        UIColor *configured(cell.backgroundConfiguration.backgroundColor);
        if (configured != nil)
            return configured;
    }
#endif
    UIColor *backgroundViewColor(cell.backgroundView.backgroundColor);
    if (backgroundViewColor != nil)
        return backgroundViewColor;
    return cell.backgroundColor ?: cell.contentView.backgroundColor;
}

static BOOL HomeProbeColorIsTransparent(UIColor *color) {
    if (color == nil)
        return YES;
    CGFloat alpha(0), white(0), red(0), green(0), blue(0);
    if ([color getRed:&red green:&green blue:&blue alpha:&alpha] ||
        [color getWhite:&white alpha:&alpha])
        return alpha < 0.01;
    return NO;
}

static BOOL HomeProbeBackgroundConfigurationSynchronized(UITableViewCell *cell) {
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        if (cell == nil)
            return NO;
        // A legacy backgroundView intentionally clears the modern configuration
        // so UIKit retains its default selected background and fade animation.
        if (cell.backgroundConfiguration == nil)
            return cell.backgroundView != nil && cell.backgroundView.backgroundColor != nil;
        if (cell.backgroundConfiguration.backgroundColor == nil)
            return NO;
        UIColor *reference(cell.backgroundColor);
        if (HomeProbeColorIsTransparent(reference))
            reference = cell.backgroundView.backgroundColor;
        if (HomeProbeColorIsTransparent(reference))
            reference = cell.contentView.backgroundColor;
        if (HomeProbeColorIsTransparent(reference))
            return YES;
        return std::abs(HomeProbeLuminance(reference) -
                        HomeProbeLuminance(cell.backgroundConfiguration.backgroundColor)) <= 1;
    }
#endif
    /* iOS 12/13 have no backgroundConfiguration; the legacy surface check
     * below remains authoritative on those runtimes. */
    return YES;
}

static BOOL HomeProbeCellSurfaceSynchronized(UITableViewCell *cell) {
    UIColor *effective(HomeProbeEffectiveCellColor(cell));
    if (effective == nil || cell.contentView == nil)
        return NO;
    NSInteger expected(HomeProbeLuminance(effective));
    UIColor *content(cell.contentView.backgroundColor);
    if (!HomeProbeColorIsTransparent(content) &&
        std::abs(expected - HomeProbeLuminance(content)) > 1)
        return NO;
    if (!HomeProbeBackgroundConfigurationSynchronized(cell))
        return NO;
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *))
        return YES;
#endif
    return cell.backgroundView != nil && cell.backgroundView.backgroundColor != nil &&
        std::abs(expected - HomeProbeLuminance(cell.backgroundView.backgroundColor)) <= 1;
}

static NSString *HomeProbeEnvironment(NSString *key) {
    NSString *value([[[NSProcessInfo processInfo] environment] objectForKey:key]);
    return value ?: @"";
}

static CydiaHomeViewModel *HomeProbeModel(NSString *phase) {
    BOOL empty([phase isEqualToString:@"empty"]);
    BOOL offline([phase isEqualToString:@"offline"]);
    BOOL updating([phase isEqualToString:@"updating"]);
    return [[CydiaHomeViewModel alloc]
        initWithSourceCount:empty ? 0 : 8
        packageCount:empty ? 0 : 321
        installedCount:empty ? 0 : 88
        upgradeCount:empty ? 0 : 4
        halfInstalledCount:empty ? 0 : 1
        databaseReady:!empty
        databaseEra:empty ? 0 : 42
        status:offline ? CydiaHomeStatusOffline :
            updating ? CydiaHomeStatusUpdating :
            empty ? CydiaHomeStatusLoading : CydiaHomeStatusReady
        statusMessage:offline ? UCLocalize("NETWORK_ERROR") :
            updating ? UCLocalize("UPDATING_SOURCES") :
            empty ? UCLocalize("LOADING_DATA") : UCLocalize("COMPLETE")];
}

@interface CydiaHomeProbeHostController : UIViewController
@end

@implementation CydiaHomeProbeHostController {
    CydiaHomeProbeController *controller_;
    UINavigationController *navigation_;
    CydiaHomeProbeDelegate *delegate_;
    NSString *phase_;
    NSString *controllerToken_;
    NSString *modelToken_;
    BOOL dark_;
    BOOL accessibilityLarge_;
    NSUInteger settleTicks_;
    NSString *guideCommandToken_;
    NSURLSession *protocolSession_;
    NSURLSessionDataTask *protocolCanaryTask_;
    NSURLSessionDataTask *protocolHomeCanaryTask_;
    BOOL protocolRegistered_;
    NSMutableArray<NSString *> *lifecycleNotifications_;
    BOOL lifecycleArmed_;
    BOOL lifecycleComplete_;
}

- (UIStatusBarStyle) preferredStatusBarStyle {
    return dark_ ? UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}

- (NSString *)markerPath:(NSString *)name {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

- (BOOL)consumeMarker:(NSString *)name {
    NSString *path([self markerPath:name]);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return NO;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return YES;
}

- (void)observeApplicationLifecycle {
    NSNotificationCenter *center([NSNotificationCenter defaultCenter]);
    for (NSNotificationName name in @[
            UIApplicationWillResignActiveNotification,
            UIApplicationDidEnterBackgroundNotification,
            UIApplicationWillEnterForegroundNotification,
            UIApplicationDidBecomeActiveNotification]) {
        [center addObserver:self selector:@selector(applicationLifecycleNotification:)
                      name:name object:nil];
    }
}

- (void)applicationLifecycleNotification:(NSNotification *)notification {
    if (!lifecycleArmed_)
        return;
    [lifecycleNotifications_ addObject:notification.name];
    if (lifecycleNotifications_.count == 4 &&
        [notification.name isEqualToString:UIApplicationDidBecomeActiveNotification]) {
        lifecycleArmed_ = NO;
        lifecycleComplete_ = YES;
    }
    [self writeState];
}

- (void)startProtocolCanary {
    HomeProbeProtocolReset();
    protocolRegistered_ = [NSURLProtocol registerClass:[CydiaHomeProbeURLProtocol class]];
    if (!protocolRegistered_)
        return;
    NSURLSessionConfiguration *configuration(
        [NSURLSessionConfiguration ephemeralSessionConfiguration]);
    configuration.protocolClasses = @[[CydiaHomeProbeURLProtocol class]];
    protocolSession_ = [NSURLSession sessionWithConfiguration:configuration];
    NSURL *URL([NSURL URLWithString:
        @"https://cydia.saurik.com/__cydia_home_probe_canary__"]);
    protocolCanaryTask_ = [protocolSession_ dataTaskWithURL:URL
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)data;
            (void)response;
            (void)error;
        }];
    [protocolCanaryTask_ resume];
    NSURL *homeURL([NSURL URLWithString:
        @"https://cydia.saurik.com/ui/ios~iphone/1.1/?cydia-home-probe=1#!/home/"]);
    protocolHomeCanaryTask_ = [protocolSession_ dataTaskWithURL:homeURL
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)data;
            (void)response;
            (void)error;
        }];
    [protocolHomeCanaryTask_ resume];
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
}

- (void)dealloc {
    [protocolCanaryTask_ cancel];
    [protocolHomeCanaryTask_ cancel];
    [protocolSession_ invalidateAndCancel];
    if (protocolRegistered_)
        [NSURLProtocol unregisterClass:[CydiaHomeProbeURLProtocol class]];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    dark_ = NO;
    accessibilityLarge_ = NO;
    lifecycleNotifications_ = [NSMutableArray array];
    delegate_ = [[CydiaHomeProbeDelegate alloc] init];
    [self installPhase:@"full"];
    [self observeApplicationLifecycle];
    [self startProtocolCanary];
    [self performSelector:@selector(probeTick) withObject:nil afterDelay:0.2];
}

- (void)installPhase:(NSString *)phase {
    phase_ = [phase copy];
    CydiaHomeViewModel *model(HomeProbeModel(phase));
    controller_ = [[CydiaHomeProbeController alloc] initWithViewModel:model];
    controller_.probeDelegate = delegate_;
    [controller_ setDelegate:delegate_];
    controllerToken_ = [[NSUUID UUID] UUIDString];
    modelToken_ = [[NSUUID UUID] UUIDString];

    if (navigation_ == nil) {
        navigation_ = [[UINavigationController alloc]
            initWithRootViewController:controller_];
        [self addChildViewController:navigation_];
        navigation_.view.frame = self.view.bounds;
        navigation_.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:navigation_.view];
        [navigation_ didMoveToParentViewController:self];
    } else {
        [navigation_ setViewControllers:@[controller_] animated:NO];
    }
    [self applyTraits];
    settleTicks_ = 6;
}

- (void)applyTraits {
    UITraitCollection *style([UITraitCollection
        traitCollectionWithUserInterfaceStyle:dark_ ?
            UIUserInterfaceStyleDark : UIUserInterfaceStyleLight]);
    UITraitCollection *size([UITraitCollection
        traitCollectionWithPreferredContentSizeCategory:accessibilityLarge_ ?
            UIContentSizeCategoryAccessibilityLarge : UIContentSizeCategoryLarge]);
    [self setOverrideTraitCollection:[UITraitCollection
        traitCollectionWithTraitsFromCollections:@[style, size]]
        forChildViewController:navigation_];
    [navigation_.view setNeedsLayout];
    [navigation_.view layoutIfNeeded];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)probeTick {
    if ([self consumeMarker:@"cydia-home-probe-dark"]) {
        dark_ = YES;
        accessibilityLarge_ = NO;
        [self applyTraits];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-home-probe-light"]) {
        dark_ = NO;
        accessibilityLarge_ = NO;
        [self applyTraits];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-home-probe-accessibility"]) {
        dark_ = YES;
        accessibilityLarge_ = YES;
        [self applyTraits];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-home-probe-light-accessibility"]) {
        dark_ = NO;
        accessibilityLarge_ = YES;
        [self applyTraits];
        settleTicks_ = 5;
    }
    // Simulator-only finite guide control. It invokes the actual table delegate;
    // it is not physical-input/VoiceOver execution evidence.
    NSString *guideCommandPath = [self markerPath:@"cydia-home-probe-upgrading-command.plist"];
    NSDictionary *guideCommand = [NSDictionary dictionaryWithContentsOfFile:guideCommandPath];
    if (guideCommand != nil && [self consumeMarker:@"cydia-home-probe-upgrading-command.plist"]) {
        guideCommandToken_ = [guideCommand[@"token"] copy];
        UITableView *table = HomeProbeFindGuideTable(navigation_.topViewController.view);
        NSString *action = guideCommand[@"action"];
        NSInteger row = [guideCommand[@"row"] integerValue];
        NSArray<NSIndexPath *> *actions = HomeProbeGuideActionPaths(table);
        if ([action isEqualToString:@"back"]) {
            UpgradingGuideController *guide = [navigation_.topViewController
                isKindOfClass:[UpgradingGuideController class]] ?
                (UpgradingGuideController *)navigation_.topViewController : nil;
            if (guide == nil || ![guide popDisplayedSplitPage])
                [navigation_ popViewControllerAnimated:NO];
        }
        else if (table != nil && row >= 0 && row < actions.count) {
            NSIndexPath *path = actions[row];
            if ([action isEqualToString:@"select"])
                [table.delegate tableView:table didSelectRowAtIndexPath:path];
            else if ([action isEqualToString:@"scroll"])
                [table scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        }
        settleTicks_ = 8;
    }
    if ([self consumeMarker:@"cydia-home-probe-empty"]) {
        dark_ = NO;
        accessibilityLarge_ = NO;
        [self installPhase:@"empty"];
    }
    if ([self consumeMarker:@"cydia-home-probe-offline"]) {
        dark_ = YES;
        accessibilityLarge_ = NO;
        [self installPhase:@"offline"];
    }
    if ([self consumeMarker:@"cydia-home-probe-updating"]) {
        dark_ = NO;
        accessibilityLarge_ = NO;
        [self installPhase:@"updating"];
    }
    if ([self consumeMarker:@"cydia-home-probe-about"])
        [controller_ aboutButtonClicked];
    if ([self consumeMarker:@"cydia-home-probe-refresh"])
        [controller_ refreshButtonClicked];
    if ([self consumeMarker:@"cydia-home-probe-cancel"])
        [controller_ cancelButtonClicked];
    if ([self consumeMarker:@"cydia-home-probe-arm-lifecycle"]) {
        [lifecycleNotifications_ removeAllObjects];
        lifecycleArmed_ = YES;
        lifecycleComplete_ = NO;
    }
    if ([self consumeMarker:@"cydia-home-probe-route-sources"]) {
        UITableView *table(HomeProbeFindTableWithIdentifier(controller_.view,
            @"cydia.home.table"));
        NSIndexPath *indexPath(HomeProbeIndexPathForIdentifier(table,
            @"cydia.home.help.sources"));
        if (indexPath != nil)
            [table.delegate tableView:table didSelectRowAtIndexPath:indexPath];
        settleTicks_ = 3;
    }
    if ([self consumeMarker:@"cydia-home-probe-route-pop"])
        [navigation_ popToViewController:controller_ animated:NO];
    if ([self consumeMarker:@"cydia-home-probe-guide"]) {
        UITableView *table(HomeProbeFindTableWithIdentifier(controller_.view,
            @"cydia.home.table"));
        NSIndexPath *indexPath(HomeProbeIndexPathForIdentifier(table,
            @"cydia.home.guide.faq"));
        if (indexPath != nil)
            [table.delegate tableView:table didSelectRowAtIndexPath:indexPath];
    }
    if ([self consumeMarker:@"cydia-home-probe-upgrading-guide"]) {
        UITableView *table(HomeProbeFindTableWithIdentifier(controller_.view,
            @"cydia.home.table"));
        NSIndexPath *indexPath(HomeProbeIndexPathForIdentifier(table,
            @"cydia.home.help.upgrading"));
        if (indexPath != nil)
            [table.delegate tableView:table didSelectRowAtIndexPath:indexPath];
        settleTicks_ = 8;
    }
    if ([self consumeMarker:@"cydia-home-probe-upgrading-detail"]) {
        UITableView *table(HomeProbeFindGuideTable(navigation_.topViewController.view));
        NSArray<NSIndexPath *> *actions = HomeProbeGuideActionPaths(table);
        if (actions.count != 0)
            [table.delegate tableView:table
                didSelectRowAtIndexPath:actions[0]];
        settleTicks_ = 8;
    }
    if ([self consumeMarker:@"cydia-home-probe-faq-detail"]) {
        UITableView *table(HomeProbeFindTableWithIdentifier(
            navigation_.topViewController.view, @"cydia.home.faq.questions"));
        if (table != nil && [table.dataSource tableView:table
                numberOfRowsInSection:0] > 0)
            [table.delegate tableView:table
                didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        /* iOS 12's native navigation push can outlive the first three
         * 200ms probe ticks under a loaded simulator. */
        settleTicks_ = 8;
    }
    if ([self consumeMarker:@"cydia-home-probe-faq-pop"])
        [navigation_ popViewControllerAnimated:NO];
    if ([self consumeMarker:@"cydia-home-probe-featured"]) {
        UIButton *button((UIButton *)HomeProbeFindView(controller_.view,
            @"cydia.home.featured"));
        if ([button isKindOfClass:[UIButton class]])
            [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
    for (NSString *social in @[@"facebook", @"twitter"]) {
        if ([self consumeMarker:[@"cydia-home-probe-" stringByAppendingString:social]]) {
            UIButton *button((UIButton *)HomeProbeFindView(controller_.view, [@"cydia.home.social." stringByAppendingString:social]));
            if ([button isKindOfClass:[UIButton class]]) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
            settleTicks_ = 5;
        }
    }
    if ([self consumeMarker:@"cydia-home-probe-ipad-package"]) {
        UITableView *table(HomeProbeFindTableWithIdentifier(controller_.view,
            @"cydia.home.ipad.recommendations"));
        if (table != nil && !table.hidden)
            [table.delegate tableView:table didSelectRowAtIndexPath:
                [NSIndexPath indexPathForRow:0 inSection:0]];
    }
    [navigation_.view layoutIfNeeded];
    if (settleTicks_ != 0)
        --settleTicks_;
    [self writeState];
    [self performSelector:@selector(probeTick) withObject:nil afterDelay:0.2];
}

- (void)writeState {
    UITableView *table(HomeProbeFindTableWithIdentifier(controller_.view,
        @"cydia.home.table"));
    if (table == nil)
        return;
    [table layoutIfNeeded];

    NSMutableArray<NSString *> *rows([NSMutableArray array]);
    NSMutableArray<NSString *> *actions([NSMutableArray array]);
    NSMutableArray<NSNumber *> *actionTags([NSMutableArray array]);
    NSMutableArray<NSNumber *> *rowHeights([NSMutableArray array]);
    NSMutableArray<NSNumber *> *sectionRowCounts([NSMutableArray array]);
    BOOL rowLabelsPresent(YES);
    BOOL rowsMeetTouchTarget(YES);
    BOOL plainRowsHaveNoIcons(YES);
    UITableViewCell *surfaceCell(nil);
    UITableViewCell *accountCell(nil);
    UITableViewCell *splitCell(nil);
    NSInteger sections([table.dataSource numberOfSectionsInTableView:table]);
    for (NSInteger section(0); section != sections; ++section) {
        NSInteger count([table.dataSource tableView:table numberOfRowsInSection:section]);
        [sectionRowCounts addObject:@(count)];
        for (NSInteger row(0); row != count; ++row) {
            NSIndexPath *indexPath([NSIndexPath indexPathForRow:row inSection:section]);
            UITableViewCell *cell([table.dataSource tableView:table
                cellForRowAtIndexPath:indexPath]);
            NSString *identifier(cell.accessibilityIdentifier ?: @"");
            [rows addObject:identifier];
            CGRect frame([table rectForRowAtIndexPath:indexPath]);
            [rowHeights addObject:@(CGRectGetHeight(frame))];
            rowsMeetTouchTarget = rowsMeetTouchTarget && CGRectGetHeight(frame) >= 44.0;

            if ([identifier isEqualToString:@"cydia.home.social"] ||
                [identifier isEqualToString:@"cydia.home.discovery"]) {
                if (splitCell == nil)
                    splitCell = cell;
                NSArray<NSString *> *controlIDs([identifier isEqualToString:@"cydia.home.social"] ?
                    @[@"cydia.home.social.facebook", @"cydia.home.social.twitter"] :
                    @[@"cydia.home.featured", @"cydia.home.themes"]);
                for (NSString *controlID in controlIDs) {
                    [actions addObject:controlID];
                    UIView *control(HomeProbeFindView(cell, controlID));
                    rowLabelsPresent = rowLabelsPresent &&
                        [control isKindOfClass:[UIButton class]] &&
                        ((UIButton *)control).currentTitle.length != 0;
                    [actionTags addObject:[control isKindOfClass:[UIButton class]] ?
                        @(((UIButton *)control).tag) : @(-1)];
                }
            } else {
                [actions addObject:identifier];
                [actionTags addObject:@(cell.tag)];
                rowLabelsPresent = rowLabelsPresent && cell.textLabel.text.length != 0;
            }

            if ([identifier isEqualToString:@"cydia.home.account"])
                accountCell = cell;
            if ([identifier isEqualToString:@"cydia.home.guide.faq"])
                surfaceCell = cell;
            if ([identifier hasPrefix:@"cydia.home.help."] ||
                [identifier hasPrefix:@"cydia.home.guide."] ||
                [identifier hasPrefix:@"cydia.home.developer."] ||
                [identifier isEqualToString:@"cydia.home.credits"] ||
                [identifier isEqualToString:@"cydia.home.privacy"])
                plainRowsHaveNoIcons = plainRowsHaveNoIcons && cell.imageView.image == nil;
        }
    }

    UIView *header(HomeProbeFindView(controller_.view, @"cydia.home.header"));
    UIView *logo(HomeProbeFindView(controller_.view, @"cydia.home.header.logo"));
    UILabel *title((UILabel *)HomeProbeFindView(controller_.view,
        @"cydia.home.header.title"));
    UIButton *author((UIButton *)HomeProbeFindView(controller_.view,
        @"cydia.home.header.author"));
    UILabel *status((UILabel *)HomeProbeFindView(controller_.view,
        @"cydia.home.header.status"));
    UIView *footer(HomeProbeFindView(controller_.view, @"cydia.home.footer"));
    UILabel *footerLabel((UILabel *)HomeProbeFindView(controller_.view,
        @"cydia.home.footer.label"));
    NSString *footerText(footerLabel.text ?: @"");
    NSArray<NSString *> *footerLines([footerText componentsSeparatedByString:@"\n"]);
    NSString *footerSummary([footerLines firstObject] ?: @"");
    NSString *runtimeMachine(Machine_ == NULL ? nil :
        [NSString stringWithUTF8String:Machine_]);
    NSString *runtimeVersion(CydiaHomeVisibleVersion(Cydia_));
    NSString *runtimeIdentifier(UniqueID_);
    BOOL identifierMatches([runtimeIdentifier length] == 0 ?
        [footerLines count] == 1 :
        ([footerLines count] == 2 &&
         [[footerLines objectAtIndex:1] isEqualToString:runtimeIdentifier]));
    UITableView *recommendations(HomeProbeFindTableWithIdentifier(controller_.view,
        @"cydia.home.ipad.recommendations"));
    UITableViewCell *recommendationSurfaceCell(nil);

    UIView *faqTopView(navigation_.topViewController.view);
    UITableView *faqTable(HomeProbeFindTableWithIdentifier(faqTopView,
        @"cydia.home.faq.questions"));
    UITextView *faqAnswer((UITextView *)HomeProbeFindView(faqTopView,
        @"cydia.home.faq.answer.what-is-cydia"));
    NSMutableArray<NSString *> *faqQuestionIdentifiers([NSMutableArray array]);
    NSMutableArray<NSNumber *> *faqRowHeights([NSMutableArray array]);
    BOOL faqRowsMeetTouchTarget(YES);
    if (faqTable != nil) {
        NSInteger faqSections([faqTable.dataSource numberOfSectionsInTableView:faqTable]);
        for (NSInteger section(0); section != faqSections; ++section) {
            NSInteger count([faqTable.dataSource tableView:faqTable
                numberOfRowsInSection:section]);
            for (NSInteger row(0); row != count; ++row) {
                NSIndexPath *indexPath([NSIndexPath indexPathForRow:row inSection:section]);
                UITableViewCell *cell([faqTable.dataSource tableView:faqTable
                    cellForRowAtIndexPath:indexPath]);
                [faqQuestionIdentifiers addObject:cell.accessibilityIdentifier ?: @""];
                CGRect frame([faqTable rectForRowAtIndexPath:indexPath]);
                [faqRowHeights addObject:@(CGRectGetHeight(frame))];
                faqRowsMeetTouchTarget = faqRowsMeetTouchTarget &&
                    CGRectGetHeight(frame) >= 44.0;
            }
        }
    }
    CGRect faqAnswerFrame(faqAnswer == nil ? CGRectZero :
        [faqAnswer.superview convertRect:faqAnswer.frame toView:faqTopView]);
    UIView *guideTopView(navigation_.topViewController.view);
    UITableView *guideTable(HomeProbeFindGuideTable(guideTopView));
    UIView *guideBody(HomeProbeFindView(guideTopView, @"cydia.home.upgrading.body.text"));
    NSMutableArray *guideRows = [NSMutableArray array];
    NSArray<NSIndexPath *> *guideActions = HomeProbeGuideActionPaths(guideTable);
    for (UITableViewCell *cell in guideTable.visibleCells) {
        NSIndexPath *path = [guideTable indexPathForCell:cell];
        UILabel *label = (UILabel *)HomeProbeFindView(cell, @"cydia.home.upgrading.label");
        UIImageView *icon = (UIImageView *)HomeProbeFindView(cell, @"cydia.home.upgrading.icon");
        CGSize required = [label sizeThatFits:CGSizeMake(label.bounds.size.width, CGFLOAT_MAX)];
        [guideRows addObject:@{
            @"section": @(path.section), @"row": @(path.row),
            @"linkIndex": @([guideActions containsObject:path] ? (NSInteger)[guideActions indexOfObject:path] : -1),
            @"identifier": cell.accessibilityIdentifier ?: @"",
            @"label": cell.accessibilityLabel ?: @"",
            @"value": cell.accessibilityValue ?: @"",
            @"traits": @(cell.accessibilityTraits),
            @"isAccessibilityElement": @(cell.isAccessibilityElement),
            @"frame": NSStringFromCGRect([cell convertRect:cell.bounds toView:nil]),
            @"labelFrame": NSStringFromCGRect([label convertRect:label.bounds toView:nil]),
            @"labelRequiredHeight": @(required.height),
            @"labelUnclipped": @(label != nil && label.bounds.size.height + 0.5 >= required.height),
            @"fontSize": @(label.font.pointSize),
            @"hasImage": @(icon.image != nil),
            }];
    }

    NSInteger visibleNavigationDepth = navigation_.viewControllers.count;
    if ([navigation_.topViewController isKindOfClass:[UpgradingGuideController class]] &&
            [(UpgradingGuideController *)navigation_.topViewController hasDisplayedSplitPage])
        /* A selected split detail is a visible navigation level even though
         * it lives in the secondary column rather than the outer stack. */
        ++visibleNavigationDepth;

    NSArray<NSString *> *splitIDs(@[@"cydia.home.social.facebook",
        @"cydia.home.social.twitter", @"cydia.home.featured", @"cydia.home.themes"]);
    NSMutableArray<NSValue *> *splitFrames([NSMutableArray array]);
    NSMutableArray<NSValue *> *splitOwnerFrames([NSMutableArray array]);
    BOOL splitControlsMeetTouchTarget(YES);
    BOOL splitControlsWired(YES);
    NSUInteger splitDisclosureCount(0);
    BOOL splitDisclosuresDecorative(YES);
    BOOL splitDisclosuresInsideControls(YES);
    BOOL splitDisclosuresAtTrailingEdge(YES);
    BOOL splitDisclosureTintSynchronized(YES);
    BOOL splitDisclosuresSystemOwned(YES);
    BOOL splitContentLeadingAligned(YES);
    for (NSString *identifier in splitIDs) {
        UIView *control(HomeProbeFindView(controller_.view, identifier));
        if (control == nil) {
            splitControlsMeetTouchTarget = NO;
            splitControlsWired = NO;
            continue;
        }
        CGRect frame([control.superview convertRect:control.frame toView:controller_.view]);
        [splitFrames addObject:[NSValue valueWithCGRect:frame]];
        UIView *owner(control);
        while (owner != nil && ![owner isKindOfClass:[UITableViewCell class]])
            owner = owner.superview;
        CGRect ownerFrame(owner == nil ? CGRectNull :
            [owner convertRect:owner.bounds toView:controller_.view]);
        [splitOwnerFrames addObject:[NSValue valueWithCGRect:ownerFrame]];
        splitControlsMeetTouchTarget = splitControlsMeetTouchTarget &&
            CGRectGetHeight(frame) >= 44.0 && CGRectGetWidth(frame) >= 44.0;
        UIButton *button((UIButton *)control);
        splitContentLeadingAligned = splitContentLeadingAligned &&
            HomeProbeSplitButtonContentLeadingAligned(button);
        NSArray<NSString *> *selectors([button actionsForTarget:controller_
            forControlEvent:UIControlEventTouchUpInside]);
        splitControlsWired = splitControlsWired &&
            [button.allTargets containsObject:controller_] &&
            [selectors containsObject:@"splitButtonClicked:"] && button.tag > 0;

        NSString *disclosureIdentifier([identifier stringByAppendingString:@".disclosure"]);
        UIView *candidate(HomeProbeFindView(control, disclosureIdentifier));
        if (![candidate isKindOfClass:[UITableViewCell class]]) {
            splitDisclosuresDecorative = NO;
            splitDisclosuresInsideControls = NO;
            splitDisclosuresAtTrailingEdge = NO;
            splitDisclosureTintSynchronized = NO;
            splitDisclosuresSystemOwned = NO;
            continue;
        }
        UITableViewCell *disclosure((UITableViewCell *)candidate);
        ++splitDisclosureCount;
        splitDisclosuresDecorative = splitDisclosuresDecorative &&
            !disclosure.userInteractionEnabled && !disclosure.isAccessibilityElement &&
            disclosure.accessibilityElementsHidden;
        splitDisclosuresSystemOwned = splitDisclosuresSystemOwned &&
            disclosure.accessoryType == UITableViewCellAccessoryDisclosureIndicator &&
            disclosure.accessoryView == nil;
        splitDisclosuresInsideControls = splitDisclosuresInsideControls &&
            [disclosure isDescendantOfView:control] &&
            CGRectContainsRect(CGRectInset(control.bounds, -1, -1),
                [disclosure.superview convertRect:disclosure.frame toView:control]);
        /* The host cell owns the accessory slot; UIKit places that slot at
         * the effective trailing edge for both LTR and RTL directions.  The
         * explicit physical margins are part of that placement contract when
         * the cell is embedded outside a table. */
        UIEdgeInsets margins(disclosure.layoutMargins);
        BOOL regularCellMargins(std::abs(margins.left - 16.0) < 0.5 &&
            std::abs(margins.right - 16.0) < 0.5);
        CGRect disclosureFrame([disclosure.superview convertRect:disclosure.frame
                                                               toView:control]);
        splitDisclosuresAtTrailingEdge = splitDisclosuresAtTrailingEdge &&
            splitDisclosuresSystemOwned &&
            regularCellMargins &&
            std::abs(CGRectGetMinX(disclosureFrame) - CGRectGetMinX(control.bounds)) < 1.0 &&
            std::abs(CGRectGetMinY(disclosureFrame) - CGRectGetMinY(control.bounds)) < 1.0 &&
            std::abs(CGRectGetWidth(disclosureFrame) - CGRectGetWidth(control.bounds)) < 1.0 &&
            std::abs(CGRectGetHeight(disclosureFrame) - CGRectGetHeight(control.bounds)) < 1.0;
        /* A public UITableViewCell accessory is the color/weight contract;
         * sampling UIKit's private indicator view would make the probe
         * version-dependent. */
        splitDisclosureTintSynchronized = splitDisclosureTintSynchronized &&
            splitDisclosuresSystemOwned;
    }
    BOOL splitHorizontal(splitFrames.count == 4);
    BOOL splitVertical(splitFrames.count == 4);
    if (splitFrames.count == 4) {
        for (NSUInteger index(0); index != 4; index += 2) {
            CGRect left([splitFrames[index] CGRectValue]);
            CGRect right([splitFrames[index + 1] CGRectValue]);
            CGRect leftOwner([splitOwnerFrames[index] CGRectValue]);
            CGRect rightOwner([splitOwnerFrames[index + 1] CGRectValue]);
            BOOL contained(!CGRectIsNull(leftOwner) && !CGRectIsNull(rightOwner) &&
                CGRectContainsRect(CGRectInset(leftOwner, -1, -1), left) &&
                CGRectContainsRect(CGRectInset(rightOwner, -1, -1), right));
            splitHorizontal = splitHorizontal &&
                std::abs(CGRectGetMinY(left) - CGRectGetMinY(right)) < 1.0 &&
                std::abs(CGRectGetWidth(left) - CGRectGetWidth(right)) < 1.0 &&
                CGRectGetMinX(left) < CGRectGetMinX(right) &&
                CGRectGetMaxX(left) <= CGRectGetMinX(right) + 1.0 && contained;
            splitVertical = splitVertical &&
                CGRectGetMaxY(left) <= CGRectGetMinY(right) + 1.0 &&
                std::abs(CGRectGetMinX(left) - CGRectGetMinX(right)) < 1.0 &&
                std::abs(CGRectGetWidth(left) - CGRectGetWidth(right)) < 1.0 &&
                contained;
        }
    }
    NSMutableArray<NSString *> *actionDestinations([NSMutableArray array]);
    for (NSNumber *tag in actionTags) {
        NSURL *destination([controller_ URLForHomeAction:tag.integerValue]);
        [actionDestinations addObject:destination.absoluteString ?: @""];
    }
    NSUInteger recommendationRows(0);
    NSMutableArray<NSString *> *recommendationIdentifiers([NSMutableArray array]);
    if (recommendations != nil) {
        NSInteger recommendationSections([recommendations.dataSource
            numberOfSectionsInTableView:recommendations]);
        for (NSInteger section(0); section != recommendationSections; ++section) {
            NSInteger count([recommendations.dataSource tableView:recommendations
                numberOfRowsInSection:section]);
            recommendationRows += count;
            for (NSInteger row(0); row != count; ++row) {
                UITableViewCell *cell([recommendations.dataSource tableView:recommendations
                    cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row
                        inSection:section]]);
                if (recommendationSurfaceCell == nil)
                    recommendationSurfaceCell = cell;
                [recommendationIdentifiers addObject:cell.accessibilityIdentifier ?: @""];
            }
        }
    }
    BOOL columnsSeparated(recommendations == nil || recommendations.hidden ||
        (CGRectGetWidth(table.frame) >= 300 && CGRectGetWidth(recommendations.frame) >= 300 &&
         CGRectGetMaxX(table.frame) < CGRectGetMinX(recommendations.frame)));

    NSArray<NSString *> *assetNames(@[@"Home/cydia7.png", @"Home/facebook.png",
        @"Home/twitter.png", @"Home/featured.png", @"Home/themes.png",
        @"Home/account.png"]);
    BOOL legacyAssetsPresent(YES);
    for (NSString *assetName in assetNames)
        legacyAssetsPresent = legacyAssetsPresent && [UIImage imageNamed:assetName] != nil;

    UIAlertController *alert([controller_.presentedViewController
        isKindOfClass:[UIAlertController class]] ?
        (UIAlertController *)controller_.presentedViewController : nil);
    NSMutableArray<NSString *> *alertActions([NSMutableArray array]);
    for (UIAlertAction *action in alert.actions)
        [alertActions addObject:action.title ?: @""];

    CydiaHomeViewModel *model([controller_ probeViewModel]);
    NSDictionary *protocolState(HomeProbeProtocolSnapshot());
    BOOL retiredAssetsAbsent(
        [[NSBundle mainBundle] pathForResource:@"error" ofType:@"html"] == nil &&
        [[NSBundle mainBundle] pathForResource:@"localize" ofType:@"js"] == nil &&
        [[NSBundle mainBundle] pathForResource:@"menes/menes" ofType:@"js"] == nil);
    NSDictionary *state(@{
        @"schema": @1,
        @"fixtureVersion": @"native-home-legacy-hierarchy-v2",
        @"buildEvidence": @{
            @"sourceHEAD": HomeProbeEnvironment(@"CYDIA_PROBE_SOURCE_HEAD"),
            @"binarySHA256": HomeProbeEnvironment(@"CYDIA_PROBE_BINARY_SHA256"),
            @"bundleShortVersion": HomeProbeEnvironment(@"CYDIA_PROBE_BUNDLE_SHORT_VERSION"),
            @"bundleVersion": HomeProbeEnvironment(@"CYDIA_PROBE_BUNDLE_VERSION"),
        },
        @"ready": @(settleTicks_ == 0),
        @"phase": phase_ ?: @"",
        @"style": dark_ ? @"dark" : @"light",
        @"contentSize": accessibilityLarge_ ? @"accessibility-large" : @"large",
        @"processID": @((int)getpid()),
        @"systemVersion": [[UIDevice currentDevice] systemVersion],
        @"controllerClass": NSStringFromClass([controller_ class]),
        @"controllerToken": controllerToken_ ?: @"",
        @"modelToken": modelToken_ ?: @"",
        @"navigationURL": [[controller_ navigationURL] absoluteString] ?: @"",
        @"navigationDepth": @(visibleNavigationDepth),
        @"topControllerClass": NSStringFromClass([navigation_.topViewController class]),
        @"topNavigationURL": [[navigation_.topViewController navigationURL] absoluteString] ?: @"",
        @"faqListVisible": @(faqTable != nil),
        @"faqDetailVisible": @(faqAnswer != nil),
        @"faqQuestionIdentifiers": faqQuestionIdentifiers,
        @"faqQuestionCount": @(faqQuestionIdentifiers.count),
        @"faqRowHeights": faqRowHeights,
        @"faqRowsMeetTouchTarget": @(faqRowsMeetTouchTarget),
        @"faqAnswerAccessibilityIdentifier": faqAnswer.accessibilityIdentifier ?: @"",
        @"faqAnswerTextLength": @(faqAnswer.text.length),
        @"faqAnswerFrameWidth": @(CGRectGetWidth(faqAnswerFrame)),
        @"faqAnswerFrameHeight": @(CGRectGetHeight(faqAnswerFrame)),
        @"faqAnswerScrollEnabled": @(faqAnswer.scrollEnabled),
        @"upgradingGuideListVisible": @(guideTable != nil),
        @"upgradingGuideRowCount": @(guideActions.count),
        @"upgradingGuideBodyVisible": @(guideBody != nil),
        @"upgradingGuideVisibleRows": guideRows,
        @"upgradingGuideCommandToken": guideCommandToken_ ?: @"",
        @"upgradingGuideContentSize": NSStringFromCGSize(guideTable.contentSize),
        @"upgradingGuideContentOffset": NSStringFromCGPoint(guideTable.contentOffset),
        @"sectionCount": @(sections),
        @"rowCount": @(rows.count),
        @"rowIdentifiers": rows,
        @"sectionRowCounts": sectionRowCounts,
        @"actionCount": @(actions.count),
        @"actionIdentifiers": actions,
        @"actionTags": actionTags,
        @"actionDestinations": actionDestinations,
        @"rowHeights": rowHeights,
        @"rowLabelsPresent": @(rowLabelsPresent),
        @"rowsMeetTouchTarget": @(rowsMeetTouchTarget),
        @"splitControlCount": @(splitFrames.count),
        @"splitControlsMeetTouchTarget": @(splitControlsMeetTouchTarget),
        @"splitControlsWired": @(splitControlsWired),
        @"splitDisclosureCount": @(splitDisclosureCount),
        @"splitDisclosuresDecorative": @(splitDisclosuresDecorative),
        @"splitDisclosuresInsideControls": @(splitDisclosuresInsideControls),
        @"splitDisclosuresAtTrailingEdge": @(splitDisclosuresAtTrailingEdge),
        @"splitDisclosureTintSynchronized": @(splitDisclosureTintSynchronized),
        @"splitDisclosuresSystemOwned": @(splitDisclosuresSystemOwned),
        @"splitContentLeadingAligned": @(splitContentLeadingAligned),
        @"splitLayout": splitVertical && !splitHorizontal ? @"vertical" :
            splitHorizontal && !splitVertical ? @"horizontal" : @"invalid",
        @"plainRowsHaveNoIcons": @(plainRowsHaveNoIcons),
        @"accountHasHistoricalIcon": @(accountCell.imageView.image != nil),
        @"legacyAssetsPresent": @(legacyAssetsPresent),
        @"sourceCount": model ? @(model.sourceCount) : @0,
        @"packageCount": model ? @(model.packageCount) : @0,
        @"installedCount": model ? @(model.installedCount) : @0,
        @"upgradeCount": model ? @(model.upgradeCount) : @0,
        @"halfInstalledCount": model ? @(model.halfInstalledCount) : @0,
        @"databaseReady": model ? @(model.databaseReady) : @NO,
        @"databaseEra": model ? @(model.databaseEra) : @0,
        @"status": model ? @(model.status) : @0,
        @"statusMessage": status.text ?: @"",
        @"headerPresent": @(header != nil),
        @"headerHeight": @(CGRectGetHeight(header.bounds)),
        @"headerContentFitted": @(header != nil && logo != nil && title != nil &&
            author != nil && CGRectGetMaxY(logo.frame) <= CGRectGetHeight(header.bounds) + 0.5 &&
            CGRectGetMaxY(title.frame) <= CGRectGetHeight(header.bounds) + 0.5 &&
            CGRectGetMaxY(author.frame) <= CGRectGetHeight(header.bounds) + 0.5),
        @"headerTitle": title.text ?: @"",
        @"headerSubtitle": author.currentTitle ?: @"",
        @"headerStatus": status.text ?: @"",
        @"statusHidden": @(status.hidden),
        @"statusFrameHeight": @(CGRectGetHeight(status.frame)),
        @"statusVisibleAndFitted": @(!status.hidden &&
            CGRectGetHeight(status.frame) > 0 && CGRectGetMaxY(status.frame) <=
                CGRectGetHeight(header.bounds) + 0.5),
        @"footerPresent": @(footer != nil),
        @"footerSummary": footerSummary,
        @"footerHardwareModelMatchesRuntime": @([runtimeMachine length] != 0 &&
            [footerSummary rangeOfString:runtimeMachine].location != NSNotFound),
        @"footerCydiaVersionMatchesRuntime": @([runtimeVersion length] != 0 &&
            [footerSummary rangeOfString:[NSString stringWithFormat:@"_%@", runtimeVersion]]
                .location != NSNotFound),
        @"footerDeviceIdentifierAvailable": @([runtimeIdentifier length] != 0),
        @"footerDeviceIdentifierMatchesRuntime": @(identifierMatches),
        @"iPadRecommendationsVisible": @(recommendations != nil && !recommendations.hidden),
        @"iPadRecommendationSections": recommendations == nil ? @0 :
            @([recommendations.dataSource numberOfSectionsInTableView:recommendations]),
        @"iPadRecommendationRows": @(recommendationRows),
        @"iPadRecommendationIdentifiers": recommendationIdentifiers,
        @"columnsSeparated": @(columnsSeparated),
        @"navigationBarHidden": @(navigation_.navigationBar.hidden),
        @"preferredStatusBarStyle": @([self preferredStatusBarStyle]),
        @"aboutVisible": @(alert != nil),
        @"aboutActionTitles": alertActions,
        @"routeCount": @(delegate_.routeCount),
        @"fallbackRouteCount": @(delegate_.fallbackRouteCount),
        @"lastRoute": delegate_.lastRoute ?: @"",
        @"lastReferrer": delegate_.lastReferrer ?: @"",
        @"lastExternalURL": delegate_.lastExternalURL ?: @"",
        @"requestUpdateCount": @(delegate_.requestUpdateCount),
        @"cancelUpdateCount": @(delegate_.cancelUpdateCount),
        @"protocolRegistered": @(protocolRegistered_),
        @"protocolCanaryCount": protocolState[@"canaryCount"] ?: @0,
        @"appCacheRequestCount": protocolState[@"appCacheRequestCount"] ?: @0,
        @"remoteHomeCanaryCount": protocolState[@"remoteHomeCanaryCount"] ?: @0,
        @"unexpectedRemoteHomeRequestCount":
            protocolState[@"unexpectedRemoteHomeRequestCount"] ?: @0,
        @"protocolURLs": protocolState[@"URLs"] ?: @[],
        @"retiredAssetsAbsent": @(retiredAssetsAbsent),
        @"lifecycleArmed": @(lifecycleArmed_),
        @"lifecycleComplete": @(lifecycleComplete_),
        @"lifecycleNotificationCount": @(lifecycleNotifications_.count),
        @"lifecycleNotifications": [lifecycleNotifications_ copy],
        @"lastLifecycleNotification": lifecycleNotifications_.lastObject ?: @"",
        @"applicationState": UIApplication.sharedApplication.applicationState ==
            UIApplicationStateBackground ? @"background" : @"active",
        @"surfaceLuminance": @(HomeProbeLuminance(table.backgroundColor)),
        @"cellLuminance": @(HomeProbeLuminance(HomeProbeEffectiveCellColor(surfaceCell))),
        @"cellSurfaceSynchronized": @(HomeProbeCellSurfaceSynchronized(surfaceCell)),
        @"cellBackgroundConfigurationSynchronized":
            @(HomeProbeBackgroundConfigurationSynchronized(surfaceCell)),
        @"accountSurfaceSynchronized": @(HomeProbeCellSurfaceSynchronized(accountCell)),
        @"accountBackgroundConfigurationSynchronized":
            @(HomeProbeBackgroundConfigurationSynchronized(accountCell)),
        @"splitSurfaceSynchronized": @(HomeProbeCellSurfaceSynchronized(splitCell)),
        @"splitBackgroundConfigurationSynchronized":
            @(HomeProbeBackgroundConfigurationSynchronized(splitCell)),
        @"recommendationSurfaceSynchronized":
            @(recommendations == nil || recommendations.hidden ||
              HomeProbeCellSurfaceSynchronized(recommendationSurfaceCell)),
        @"recommendationBackgroundConfigurationSynchronized":
            @(recommendations == nil || recommendations.hidden ||
              HomeProbeBackgroundConfigurationSynchronized(recommendationSurfaceCell)),
        @"surfaceSeparated": @(
            std::abs(HomeProbeLuminance(table.backgroundColor) -
                     HomeProbeLuminance(HomeProbeEffectiveCellColor(surfaceCell))) >= 30),
        @"accountSurfaceDistinct": @(
            std::abs(HomeProbeLuminance(accountCell.backgroundColor) -
                     HomeProbeLuminance(surfaceCell.backgroundColor)) >= 20),
    });
    [state writeToFile:[self markerPath:@"cydia-home-probe.plist"] atomically:YES];
}

@end

UIViewController *CydiaHomeControllerProbeRootController(void) {
    return [[CydiaHomeProbeHostController alloc] init];
}

#endif // TARGET_OS_SIMULATOR && CYDIA_HOME_SIMULATOR_PROBE
