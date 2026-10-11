/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished work Copyright (C) 2026    Torrekie
 */

#include "Cydia/HomeController.h"
#include "Cydia/AppState.h"
#include "Cydia/ExternalURLPolicy.h"
#include "Cydia/HomeSplitDisclosure.h"
#include "Cydia/HomeTableAppearance.h"

#include "Cydia/Application.h"
#include "Cydia/Appearance.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/UIColor+Cydia.h"
#include "Cydia/UIRouteContext.h"
#include "CyteKit/Localize.h"
#include "CyteKit/extern.h"
#include "Menes/ObjectHandle.h"

#include <SystemConfiguration/SystemConfiguration.h>

@interface HomeController () <UITableViewDataSource, UITableViewDelegate>
- (UITraitCollection *) homeAppearanceTraits;
@end

@interface CydiaHomeSplitLinkCell : UITableViewCell
- (void) configureLeftTitle:(NSString *)leftTitle
                  leftImage:(UIImage *)leftImage
             leftIdentifier:(NSString *)leftIdentifier
                 leftAction:(NSInteger)leftAction
                 rightTitle:(NSString *)rightTitle
                 rightImage:(UIImage *)rightImage
            rightIdentifier:(NSString *)rightIdentifier
                rightAction:(NSInteger)rightAction
                     target:(id)target
                     action:(SEL)action
            traitCollection:(UITraitCollection *)traits;
- (void) applyAppearanceForTraitCollection:(UITraitCollection *)traits;
@end

namespace {

enum HomeSection : NSInteger {
    HomeSectionSocial = 0,
    HomeSectionDiscovery,
    HomeSectionAccount,
    HomeSectionHelp,
    HomeSectionGuides,
    HomeSectionDevelopers,
    HomeSectionLegal,
};

enum HomeAction : NSInteger {
    HomeActionAuthor = 1,
    HomeActionFacebook,
    HomeActionTwitter,
    HomeActionFeatured,
    HomeActionThemes,
    HomeActionAccount,
    HomeActionUpgrading,
    HomeActionApplications,
    HomeActionSourcesGuide,
    HomeActionFAQ,
    HomeActionCopying,
    HomeActionOpenSSH,
    HomeActionRootPassword,
    HomeActionStorage,
    HomeActionDeveloperResources,
    HomeActionCredits,
    HomeActionPrivacy,
};

struct HomeLinkDescriptor {
    HomeAction action;
    const char *localizationKey;
    const char *fallback;
    const char *identifier;
    const char *imageName;
};

struct HomeRecommendation {
    const char *identifier;
    const char *name;
    const char *summary;
};

static const HomeLinkDescriptor HomeSocialLinks[] = {
    {HomeActionFacebook, NULL, "Cydia", "cydia.home.social.facebook", "Home/facebook.png"},
    {HomeActionTwitter, NULL, "saurik", "cydia.home.social.twitter", "Home/twitter.png"},
};

static const HomeLinkDescriptor HomeDiscoveryLinks[] = {
    {HomeActionFeatured, "HOME_FEATURED", "Featured", "cydia.home.featured", "Home/featured.png"},
    {HomeActionThemes, "HOME_THEMES", "Themes", "cydia.home.themes", "Home/themes.png"},
};

static const HomeLinkDescriptor HomeAccountLinks[] = {
    {HomeActionAccount, "HOME_MANAGE_ACCOUNT", "Manage Account", "cydia.home.account", "Home/account.png"},
};

static const HomeLinkDescriptor HomeHelpLinks[] = {
    {HomeActionUpgrading, "HOME_UPGRADING_HELP", "Upgrading & Jailbreaking Help", "cydia.home.help.upgrading", NULL},
    {HomeActionApplications, "HOME_FIND_EXTENSIONS", "Find Extensions for Applications", "cydia.home.help.applications", NULL},
    {HomeActionSourcesGuide, "MORE_PACKAGE_SOURCES", "More Package Sources", "cydia.home.help.sources", NULL},
};

static const HomeLinkDescriptor HomeGuideLinks[] = {
    {HomeActionFAQ, "FREQUENTLY_ASKED_QUESTIONS", "Frequently Asked Questions", "cydia.home.guide.faq", NULL},
    {HomeActionCopying, "HOME_COPYING_FILES", "Copying Files to/from Device", "cydia.home.guide.copying", NULL},
    {HomeActionOpenSSH, "HOME_OPENSSH_HELP", "OpenSSH Access How-To", "cydia.home.guide.openssh", NULL},
    {HomeActionRootPassword, "HOME_ROOT_PASSWORD_HELP", "Root Password How-To", "cydia.home.guide.password", NULL},
    {HomeActionStorage, "HOME_STORAGE_INFORMATION", "Storage Information", "cydia.home.guide.storage", NULL},
};

static const HomeLinkDescriptor HomeDeveloperLinks[] = {
    {HomeActionDeveloperResources, "HOME_DEVELOPER_RESOURCES", "Useful Developer Resources", "cydia.home.developer.resources", NULL},
};

static const HomeLinkDescriptor HomeLegalLinks[] = {
    {HomeActionCredits, "HOME_CREDITS_THANK_YOU", "Credits / Thank You", "cydia.home.credits", NULL},
    {HomeActionPrivacy, "HOME_PRIVACY_POLICY", "Privacy Policy", "cydia.home.privacy", NULL},
};

static const HomeRecommendation HomeIPadExtensions[] = {
    {"libactivator", "Activator", "customize buttons and gestures\nto do useful shortcut actions"},
    {"org.herf.flux", "f.lux", "make screen colors warmer at night\nfor more comfortable viewing"},
    {"com.booleanmagic.fullforce", "FullForce", "make older applications fullscreen"},
    {"ws.hbang.ncpad", "NCPad", "make notification banners full width"},
    {"com.iky1e.swipeselection", "SwipeSelection", "edit text faster with keyboard gestures"},
};

static const HomeRecommendation HomeIPadProducts[] = {
    {"com.aaronash.barrel", "Barrel", "animated Home screen page transitions"},
    {"ch.ringwald.btc-mouse", "Bluetooth Mouse & Trackpad", "Bluetooth pointing-device support"},
    {"eu.heinelt.ifile", "iFile", "browse, edit, and transfer local files"},
    {"net.joedj.nitrous", "Nitrous", "faster JavaScript in third-party browsers"},
    {"com.rpetrich.videopane", "VideoPane", "picture-in-picture video playback"},
};

template <typename Type, size_t Count>
static size_t HomeArrayCount(const Type (&)[Count]) {
    return Count;
}

static NSString *HomeNSString(const char *value) {
    return value == NULL ? nil : [NSString stringWithUTF8String:value];
}

static NSString *HomeLocalizedString(NSString *key, NSString *fallback) {
    if (key == nil)
        return fallback;
    NSBundle *bundle([NSBundle mainBundle]);
    // Preserve the website's translations without replacing unrelated app
    // terminology. Missing Home entries retain the existing app fallback;
    // explicit English entries preserve the website's partial translations.
    NSString *appFallback([bundle localizedStringForKey:key value:fallback table:nil]);
    return [bundle localizedStringForKey:key value:appFallback table:@"Home"];
}

static NSString *HomeLocalized(const char *key, const char *fallback) {
    return HomeLocalizedString(HomeNSString(key), HomeNSString(fallback));
}

static UIImage *HomeImage(NSString *name) {
    return name == nil ? nil : [UIImage imageNamed:name];
}

static UIImage *HomeScaleImage(UIImage *image, CGSize size) {
    if (image == nil || CGSizeEqualToSize(image.size, size))
        return image;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *scaled(UIGraphicsGetImageFromCurrentImageContext());
    UIGraphicsEndImageContext();
    return scaled;
}

static UIImage *HomeImageSized(NSString *name, CGSize size) {
    return HomeScaleImage(HomeImage(name), size);
}

static CydiaColorRole HomeCellSurfaceRole(UITableViewCell *cell) {
    return [cell.accessibilityIdentifier isEqualToString:@"cydia.home.account"] ?
        CydiaColorRoleInstallingBackground : CydiaColorRoleCellBackground;
}

static void HomeApplyCellAppearance(UITableViewCell *cell,
                                    UITraitCollection *traits) {
    if (cell == nil)
        return;
    HomeApplyCellSurface(cell, HomeCellSurfaceRole(cell), traits);
    if ([cell isKindOfClass:[CydiaHomeSplitLinkCell class]])
        [(CydiaHomeSplitLinkCell *)cell applyAppearanceForTraitCollection:traits];
    else {
        cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
                                              traitCollection:traits];
        cell.detailTextLabel.textColor =
            [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                       traitCollection:traits];
    }
}

static const HomeLinkDescriptor *HomeStandardDescriptor(NSIndexPath *indexPath) {
    switch (indexPath.section) {
        case HomeSectionAccount:
            return indexPath.row < (NSInteger) HomeArrayCount(HomeAccountLinks) ?
                &HomeAccountLinks[indexPath.row] : NULL;
        case HomeSectionHelp:
            return indexPath.row < (NSInteger) HomeArrayCount(HomeHelpLinks) ?
                &HomeHelpLinks[indexPath.row] : NULL;
        case HomeSectionGuides:
            return indexPath.row < (NSInteger) HomeArrayCount(HomeGuideLinks) ?
                &HomeGuideLinks[indexPath.row] : NULL;
        case HomeSectionDevelopers:
            return indexPath.row < (NSInteger) HomeArrayCount(HomeDeveloperLinks) ?
                &HomeDeveloperLinks[indexPath.row] : NULL;
        case HomeSectionLegal:
            return indexPath.row < (NSInteger) HomeArrayCount(HomeLegalLinks) ?
                &HomeLegalLinks[indexPath.row] : NULL;
    }
    return NULL;
}

static BOOL HomeIsAccessibilityCategory(UITraitCollection *traits) {
    return traits != nil &&
        UIContentSizeCategoryIsAccessibilityCategory(traits.preferredContentSizeCategory);
}

static BOOL HomeIsUpdating(id delegate) {
    return [delegate respondsToSelector:@selector(updating)] && [delegate updating];
}

}

@implementation CydiaHomeSplitLinkCell {
    UIStackView *stack_;
    UIButton *left_;
    UIButton *right_;
    UITableViewCell *leftDisclosure_;
    UITableViewCell *rightDisclosure_;
    UIView *divider_;
}

- (instancetype) initWithReuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault
                     reuseIdentifier:identifier]) != nil) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.isAccessibilityElement = NO;

        left_ = [UIButton buttonWithType:UIButtonTypeSystem];
        right_ = [UIButton buttonWithType:UIButtonTypeSystem];
        for (UIButton *button in @[left_, right_]) {
            button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
            CydiaHomeApplySplitButtonInsets(button);
            button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            button.titleLabel.adjustsFontForContentSizeCategory = YES;
            button.titleLabel.numberOfLines = 2;
            button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
            [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        }

        stack_ = [[UIStackView alloc] initWithArrangedSubviews:@[left_, right_]];
        stack_.translatesAutoresizingMaskIntoConstraints = NO;
        stack_.axis = UILayoutConstraintAxisHorizontal;
        stack_.distribution = UIStackViewDistributionFillEqually;
        [self.contentView addSubview:stack_];
        [NSLayoutConstraint activateConstraints:@[
            [stack_.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [stack_.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [stack_.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [stack_.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];

        leftDisclosure_ = CydiaHomeSystemDisclosureAccessory();
        rightDisclosure_ = CydiaHomeSystemDisclosureAccessory();
        NSArray<NSArray *> *disclosurePairs(@[
            @[left_, leftDisclosure_],
            @[right_, rightDisclosure_],
        ]);
        for (NSArray *pair in disclosurePairs) {
            UIButton *button(pair[0]);
            UITableViewCell *disclosure(pair[1]);
            disclosure.translatesAutoresizingMaskIntoConstraints = NO;
            [button addSubview:disclosure];
            [NSLayoutConstraint activateConstraints:@[
                [disclosure.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
                [disclosure.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
                [disclosure.topAnchor constraintEqualToAnchor:button.topAnchor],
                [disclosure.bottomAnchor constraintEqualToAnchor:button.bottomAnchor],
            ]];
            [button sendSubviewToBack:disclosure];
        }

        divider_ = [[UIView alloc] init];
        divider_.userInteractionEnabled = NO;
        [self.contentView addSubview:divider_];
    }
    return self;
}

- (void) configureButton:(UIButton *)button
                    title:(NSString *)title
                    image:(UIImage *)image
               identifier:(NSString *)identifier
                   action:(NSInteger)actionValue
                   target:(id)target
                 selector:(SEL)selector {
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
        forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier;
    button.accessibilityLabel = title;
    UITableViewCell *disclosure(button == left_ ? leftDisclosure_ : rightDisclosure_);
    disclosure.accessibilityIdentifier = [identifier stringByAppendingString:@".disclosure"];
    button.tag = actionValue;
    [button removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:target action:selector forControlEvents:UIControlEventTouchUpInside];
}

- (void) configureLeftTitle:(NSString *)leftTitle
                  leftImage:(UIImage *)leftImage
             leftIdentifier:(NSString *)leftIdentifier
                 leftAction:(NSInteger)leftAction
                 rightTitle:(NSString *)rightTitle
                 rightImage:(UIImage *)rightImage
            rightIdentifier:(NSString *)rightIdentifier
                rightAction:(NSInteger)rightAction
                     target:(id)target
                     action:(SEL)action
            traitCollection:(UITraitCollection *)traits {
    [self configureButton:left_ title:leftTitle image:leftImage identifier:leftIdentifier
        action:leftAction target:target selector:action];
    [self configureButton:right_ title:rightTitle image:rightImage identifier:rightIdentifier
        action:rightAction target:target selector:action];
    stack_.axis = HomeIsAccessibilityCategory(traits) ?
        UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    [self applyAppearanceForTraitCollection:traits];
    [self setNeedsLayout];
}

- (void) applyAppearanceForTraitCollection:(UITraitCollection *)traits {
    HomeApplyCellSurface(self, CydiaColorRoleCellBackground, traits);
    UIColor *label([UIColor cydiaColorForRole:CydiaColorRoleLabel
                              traitCollection:traits]);
    divider_.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                           traitCollection:traits];
    [left_ setTitleColor:label forState:UIControlStateNormal];
    [right_ setTitleColor:label forState:UIControlStateNormal];
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle style(traits.userInterfaceStyle);
        leftDisclosure_.overrideUserInterfaceStyle = style;
        rightDisclosure_.overrideUserInterfaceStyle = style;
    }
#endif
    /* The donor cells intentionally inherit UIKit's accessory tint instead
     * of being overwritten with one of Cydia's label roles. */
}

- (void) layoutSubviews {
    CydiaHomeApplySplitButtonInsets(left_);
    CydiaHomeApplySplitButtonInsets(right_);
    [super layoutSubviews];
    CGFloat scale([UIScreen mainScreen].scale);
    if (scale <= 0)
        scale = 1;
    CGFloat thickness(1.0 / scale);
    if (stack_.axis == UILayoutConstraintAxisHorizontal)
        divider_.frame = CGRectMake(floor(CGRectGetMidX(self.contentView.bounds)), 7,
            thickness, MAX(0, CGRectGetHeight(self.contentView.bounds) - 14));
    else
        divider_.frame = CGRectMake(15, floor(CGRectGetMidY(self.contentView.bounds)),
            MAX(0, CGRectGetWidth(self.contentView.bounds) - 30), thickness);
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    stack_.axis = HomeIsAccessibilityCategory(self.traitCollection) ?
        UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    [self applyAppearanceForTraitCollection:self.traitCollection];
    [self setNeedsLayout];
}

@end

/* Home Controller {{{ */
@implementation HomeController {
    __weak Database *database_;
    CydiaHomeViewModel *viewModel_;
    UITableView *table_;
    UITableView *recommendationsTable_;
    UIView *header_;
    UIImageView *logo_;
    UILabel *title_;
    UIButton *author_;
    UILabel *status_;
    UIView *footer_;
    UILabel *footerLabel_;
    BOOL reachabilityKnown_;
    BOOL reachable_;
}

- (UITraitCollection *) homeAppearanceTraits {
    UITraitCollection *traits(self.traitCollection);
#if !defined(CYDIA_HOME_SIMULATOR_PROBE)
    UIWindow *window(self.viewIfLoaded.window);
    UITraitCollection *windowTraits(window.traitCollection);
    if (windowTraits != nil &&
        windowTraits.userInterfaceStyle != UIUserInterfaceStyleUnspecified)
        traits = windowTraits;
    else {
        UITraitCollection *screenTraits([UIScreen mainScreen].traitCollection);
        if (screenTraits != nil &&
            screenTraits.userInterfaceStyle != UIUserInterfaceStyleUnspecified)
            traits = screenTraits;
    }
#endif
    return traits;
}

- (UIStatusBarStyle) preferredStatusBarStyle {
    return [self homeAppearanceTraits].userInterfaceStyle == UIUserInterfaceStyleDark ?
        UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}

static void HomeControllerReachabilityCallback(SCNetworkReachabilityRef reachability,
                                               SCNetworkReachabilityFlags flags,
                                               void *info) {
    (void) reachability;
    HomeController *controller((__bridge HomeController *) info);
    BOOL reachable((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    [controller performSelectorOnMainThread:@selector(setReachabilityKnownValue:)
                                 withObject:@(reachable)
                              waitUntilDone:NO];
}

- (instancetype) init {
    return [self initWithDatabase:[Database sharedInstance]];
}

- (instancetype) initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) {
        database_ = database;
        reachabilityKnown_ = NO;
        reachable_ = YES;

        reachability_ = SCNetworkReachabilityCreateWithName(
            kCFAllocatorDefault, "cydia.saurik.com");
        if (reachability_ != NULL) {
            SCNetworkReachabilityContext context = {0, (__bridge void *) self, NULL, NULL, NULL};
            SCNetworkReachabilitySetCallback(reachability_, HomeControllerReachabilityCallback, &context);
            CFRunLoopRef runloop(CFRunLoopGetCurrent());
            if (SCNetworkReachabilityScheduleWithRunLoop(reachability_, runloop,
                                                          kCFRunLoopDefaultMode))
                runloop_ = runloop;

            SCNetworkReachabilityFlags flags(0);
            if (SCNetworkReachabilityGetFlags(reachability_, &flags)) {
                reachabilityKnown_ = YES;
                reachable_ = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
            }
        }
    }
    return self;
}

#if defined(CYDIA_HOME_SIMULATOR_PROBE)
- (instancetype) initWithViewModel:(CydiaHomeViewModel *)viewModel {
    if ((self = [super init]) != nil) {
        viewModel_ = viewModel;
        reachabilityKnown_ = YES;
        reachable_ = viewModel.status != CydiaHomeStatusOffline;
    }
    return self;
}

- (void) setProbeReachabilityKnown:(BOOL)known reachable:(BOOL)reachable {
    reachabilityKnown_ = known;
    reachable_ = reachable;
    [self reloadData];
}

- (CydiaHomeViewModel *) probeViewModel {
    return viewModel_;
}
#endif

- (void) dealloc {
    if (reachability_ != NULL) {
        if (runloop_ != NULL)
            SCNetworkReachabilityUnscheduleFromRunLoop(reachability_, runloop_,
                                                       kCFRunLoopDefaultMode);
        CFRelease(reachability_);
        reachability_ = NULL;
    }
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://home"];
}

- (void) loadView {
    UIView *view([[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]]);
    view.autoresizingMask = CydiaAutoresizingFlexibleBoth;
    view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                       traitCollection:[self homeAppearanceTraits]];
    self.view = view;

    table_ = [[UITableView alloc] initWithFrame:view.bounds style:UITableViewStyleGrouped];
    table_.dataSource = self;
    table_.delegate = self;
    table_.accessibilityIdentifier = @"cydia.home.table";
    table_.estimatedRowHeight = 44;
    table_.rowHeight = UITableViewAutomaticDimension;
    table_.sectionHeaderHeight = 0.01;
    table_.sectionFooterHeight = 0.01;
    HomeApplyTableSurface(table_, view.backgroundColor, [self homeAppearanceTraits]);
    table_.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                        traitCollection:[self homeAppearanceTraits]];
    if ([table_ respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)])
        table_.cellLayoutMarginsFollowReadableWidth = NO;
    /* iOS 15 added 22pt of grouped-table section-header top padding.  The
     * legacy Home lanes already own their spacing through the delegate's
     * explicit section footer, so retaining that implicit inset makes the
     * social and discovery rows look disconnected.  Keep the guard for the
     * iOS 12 deployment target, where this selector is unavailable. */
    if ([table_ respondsToSelector:@selector(setSectionHeaderTopPadding:)])
        table_.sectionHeaderTopPadding = 0;
    [view addSubview:table_];

    recommendationsTable_ = [[UITableView alloc] initWithFrame:CGRectZero
        style:UITableViewStyleGrouped];
    recommendationsTable_.dataSource = self;
    recommendationsTable_.delegate = self;
    recommendationsTable_.estimatedRowHeight = 60;
    recommendationsTable_.rowHeight = UITableViewAutomaticDimension;
    recommendationsTable_.sectionHeaderHeight = 0.01;
    recommendationsTable_.sectionFooterHeight = 0.01;
    if ([recommendationsTable_ respondsToSelector:@selector(setSectionHeaderTopPadding:)])
        recommendationsTable_.sectionHeaderTopPadding = 0;
    HomeApplyTableSurface(recommendationsTable_, view.backgroundColor,
        [self homeAppearanceTraits]);
    recommendationsTable_.separatorColor = table_.separatorColor;
    recommendationsTable_.accessibilityIdentifier = @"cydia.home.ipad.recommendations";
    recommendationsTable_.hidden = YES;
    [view addSubview:recommendationsTable_];

    header_ = [[UIView alloc] initWithFrame:CGRectMake(0, 0, view.bounds.size.width, 78)];
    header_.accessibilityIdentifier = @"cydia.home.header";
    logo_ = [[UIImageView alloc] initWithImage:HomeImageSized(@"Home/cydia7.png",
        CGSizeMake(60, 60))];
    logo_.contentMode = UIViewContentModeScaleAspectFit;
    logo_.accessibilityLabel = @"Cydia";
    logo_.accessibilityIdentifier = @"cydia.home.header.logo";
    [header_ addSubview:logo_];

    title_ = [[UILabel alloc] init];
    title_.text = HomeLocalized("WELCOME_TO_CYDIA", "Welcome to Cydia™");
    title_.accessibilityIdentifier = @"cydia.home.header.title";
    /* The legacy banner uses a compact headline beside the logo.  Title2
     * makes the native replacement visually heavier than the source page on
     * iPad while offering no additional hierarchy. */
    title_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title_.adjustsFontForContentSizeCategory = YES;
    title_.numberOfLines = 0;
    title_.textAlignment = NSTextAlignmentCenter;
    [header_ addSubview:title_];

    author_ = [UIButton buttonWithType:UIButtonTypeSystem];
    [author_ setTitle:[NSString stringWithFormat:HomeLocalized("BY", "by %@"),
        @"Jay Freeman (saurik)"] forState:UIControlStateNormal];
    author_.accessibilityIdentifier = @"cydia.home.header.author";
    author_.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    author_.titleLabel.adjustsFontForContentSizeCategory = YES;
    author_.titleLabel.numberOfLines = 0;
    author_.titleLabel.textAlignment = NSTextAlignmentCenter;
    [author_ addTarget:self action:@selector(authorButtonClicked)
        forControlEvents:UIControlEventTouchUpInside];
    [header_ addSubview:author_];

    status_ = [[UILabel alloc] init];
    status_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    status_.adjustsFontForContentSizeCategory = YES;
    status_.numberOfLines = 0;
    status_.accessibilityIdentifier = @"cydia.home.header.status";
    status_.textAlignment = NSTextAlignmentCenter;
    status_.hidden = YES;
    [header_ addSubview:status_];
    table_.tableHeaderView = header_;

    footer_ = [[UIView alloc] initWithFrame:CGRectMake(0, 0, view.bounds.size.width, 50)];
    footer_.accessibilityIdentifier = @"cydia.home.footer";
    footerLabel_ = [[UILabel alloc] init];
    footerLabel_.accessibilityIdentifier = @"cydia.home.footer.label";
    /* This is diagnostic metadata rather than primary content.  Keep the
     * footer compact enough for the fixed-width device identifier to remain
     * one readable line on the iPad's narrow Home column. */
    footerLabel_.font = [UIFont systemFontOfSize:10.0];
    footerLabel_.adjustsFontForContentSizeCategory = YES;
    footerLabel_.numberOfLines = 0;
    footerLabel_.textAlignment = NSTextAlignmentCenter;
    [footer_ addSubview:footerLabel_];
    table_.tableFooterView = footer_;

    [self applyColorAppearance];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    /* A device can change appearance while Cydia is suspended.  Reapply the
     * row surfaces at the foreground boundary as well as in the trait hook,
     * before UIKit lays out the grouped cells. */
    [self applyColorAppearance];
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (table_ == nil)
        return;

    CGRect bounds(self.view.bounds);
    CGFloat viewWidth(CGRectGetWidth(bounds));
    BOOL twoColumns(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad &&
        viewWidth >= 700);
    if (twoColumns) {
        CGFloat columnWidth(MIN(340, floor((viewWidth - 36) / 2)));
        CGFloat gap(12);
        CGFloat total(columnWidth * 2 + gap);
        CGFloat x(floor((viewWidth - total) / 2));
        table_.frame = CGRectMake(x, 0, columnWidth, CGRectGetHeight(bounds));
        recommendationsTable_.frame = CGRectMake(x + columnWidth + gap, 30,
            columnWidth, MAX(0, CGRectGetHeight(bounds) - 30));
        recommendationsTable_.hidden = NO;
    } else {
        table_.frame = bounds;
        recommendationsTable_.hidden = YES;
        recommendationsTable_.frame = CGRectZero;
    }

    CGFloat width(table_.bounds.size.width);
    CGFloat contentWidth(MIN(320, MAX(1, width - 32)));
    CGFloat contentLeft(floor((width - contentWidth) / 2));
    CGFloat textLeft(contentLeft + 70);
    CGFloat textWidth(MAX(1, contentWidth - 70));
    CGFloat y(6);
    CGSize logoSize(CGSizeMake(60, 60));
    logo_.frame = CGRectMake(contentLeft, y, logoSize.width, logoSize.height);

    CGSize titleSize([title_ sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)]);
    title_.frame = CGRectMake(textLeft, y, textWidth, titleSize.height);
    y += titleSize.height + 2;
    CGSize authorSize([author_ sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)]);
    CGFloat authorHeight(MAX(44, authorSize.height));
    author_.frame = CGRectMake(textLeft, y, textWidth, authorHeight);
    y += authorHeight;

    CGFloat topperBottom(MAX(y, 9 + logoSize.height));
    CGFloat height(topperBottom + 5);
    if (!status_.hidden) {
        CGFloat statusTop(topperBottom + 4);
        CGSize statusSize([status_ sizeThatFits:CGSizeMake(width - 32, CGFLOAT_MAX)]);
        status_.frame = CGRectMake(16, statusTop, width - 32, statusSize.height);
        height = statusTop + statusSize.height + 9;
    } else {
        status_.frame = CGRectZero;
    }
    CGRect frame(header_.frame);
    frame.size = CGSizeMake(width, height);
    if (!CGRectEqualToRect(header_.frame, frame)) {
        header_.frame = frame;
        table_.tableHeaderView = header_;
    }

    CGSize footerSize([footerLabel_ sizeThatFits:CGSizeMake(width - 32, CGFLOAT_MAX)]);
    footerLabel_.frame = CGRectMake(16, 12, width - 32, footerSize.height);
    CGRect footerFrame(footer_.frame);
    footerFrame.size = CGSizeMake(width, footerSize.height + 24);
    if (!CGRectEqualToRect(footer_.frame, footerFrame)) {
        footer_.frame = footerFrame;
        table_.tableFooterView = footer_;
    }
}

- (void) applyColorAppearance {
    UITraitCollection *traits([self homeAppearanceTraits]);
    UIColor *grouped([UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                traitCollection:traits]);
    UIColor *label([UIColor cydiaColorForRole:CydiaColorRoleLabel
                           traitCollection:traits]);
    UIColor *secondary([UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                               traitCollection:traits]);
    UIColor *separator([UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                traitCollection:traits]);
    UIColor *accent([UIColor cydiaColorForRole:CydiaColorRoleAccent
                             traitCollection:traits]);
    self.view.backgroundColor = grouped;
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle style(traits.userInterfaceStyle);
        if (style != UIUserInterfaceStyleUnspecified)
            self.view.overrideUserInterfaceStyle = style;
    }
#endif
    HomeApplyTableSurface(table_, grouped, traits);
    table_.separatorColor = separator;
    HomeApplyTableSurface(recommendationsTable_, grouped, traits);
    recommendationsTable_.separatorColor = separator;
    header_.backgroundColor = grouped;
    footer_.backgroundColor = grouped;
    title_.textColor = label;
    [author_ setTitleColor:accent forState:UIControlStateNormal];
    status_.textColor = viewModel_.status == CydiaHomeStatusOffline ?
        [UIColor cydiaColorForRole:CydiaColorRoleErrorLabel
                   traitCollection:traits] : secondary;
    footerLabel_.textColor = secondary;
    for (UITableViewCell *cell in table_.visibleCells)
        HomeApplyCellAppearance(cell, traits);
    for (UITableViewCell *cell in recommendationsTable_.visibleCells)
        HomeApplyCellAppearance(cell, traits);
    if (self.navigationController != nil) {
        UINavigationBar *navigationBar(self.navigationController.navigationBar);
        navigationBar.barStyle = traits.userInterfaceStyle == UIUserInterfaceStyleDark ?
            UIBarStyleBlack : UIBarStyleDefault;
        navigationBar.tintColor = accent;
        navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: label};
    }
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    BOOL colorChanged(CydiaColorAppearanceDidChange(self.traitCollection,
        previousTraitCollection));
    BOOL contentSizeChanged(previousTraitCollection == nil ||
        ![self.traitCollection.preferredContentSizeCategory isEqualToString:
            previousTraitCollection.preferredContentSizeCategory]);
    if (colorChanged)
        [self applyColorAppearance];
    if (colorChanged || contentSizeChanged) {
        [table_ reloadData];
        [recommendationsTable_ reloadData];
        [self viewDidLayoutSubviews];
    }
}

- (NSString *) statusMessage {
    if (viewModel_ == nil)
        return UCLocalize("LOADING_DATA");
    return [viewModel_ statusMessage];
}

- (void) updateNavigationItems {
    [[self navigationItem] setTitle:UCLocalize("HOME")];
    [[self navigationItem] setLeftBarButtonItem:[self leftButton]];

    id delegate([self delegate]);
    BOOL updating(HomeIsUpdating(delegate));
    UIBarButtonItem *right([[UIBarButtonItem alloc]
        initWithTitle:updating ? UCLocalize("CANCEL") : UCLocalize("REFRESH")
        style:updating ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain
        target:self
        action:updating ? @selector(cancelButtonClicked) : @selector(refreshButtonClicked)]);
    [[self navigationItem] setRightBarButtonItem:right];
}

- (UIBarButtonItem *) leftButton {
    return [[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("ABOUT")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(aboutButtonClicked)];
}

- (void) setReachabilityKnownValue:(NSNumber *)value {
    reachabilityKnown_ = YES;
    reachable_ = [value boolValue];
    [self reloadData];
}

- (void) snapshotDatabase {
    Database *database(database_);
    if (database == nil)
        return;

    NSUInteger sourceCount(0);
    NSUInteger packageCount(0);
    NSUInteger installed(0);
    NSUInteger upgrades(0);
    NSUInteger halfInstalled(0);
    BOOL ready;
    NSUInteger era;
    @synchronized (database) {
        NSArray *packages([database packages]);
        NSArray *sources([database sources]);
        sourceCount = [sources count];
        packageCount = [packages count];
        ready = [database hasPackages];
        era = [database era];

        for (Package *package in packages) {
            if ([package installed] != nil)
                ++installed;
            if ([package upgradableAndEssential:YES])
                ++upgrades;
            if ([package half])
                ++halfInstalled;
        }
    }

    id delegate([self delegate]);
    CydiaHomeStatus status(CydiaHomeStatusLoading);
    NSString *message(UCLocalize("LOADING_DATA"));
    if (HomeIsUpdating(delegate)) {
        status = CydiaHomeStatusUpdating;
        message = UCLocalize("UPDATING_SOURCES");
    } else if (reachabilityKnown_ && !reachable_) {
        status = CydiaHomeStatusOffline;
        message = UCLocalize("NETWORK_ERROR");
    } else if (ready) {
        status = CydiaHomeStatusReady;
        message = UCLocalize("COMPLETE");
    }

    viewModel_ = [[CydiaHomeViewModel alloc]
        initWithSourceCount:sourceCount
        packageCount:packageCount
        installedCount:installed
        upgradeCount:upgrades
        halfInstalledCount:halfInstalled
        databaseReady:ready
        databaseEra:era
        status:status
        statusMessage:message];
}

- (void) reloadData {
    [super reloadData];
    [self snapshotDatabase];
    [self updateNavigationItems];
    status_.text = [self statusMessage];
    BOOL statusHidden(viewModel_ != nil && viewModel_.status == CydiaHomeStatusReady);
    status_.hidden = statusHidden;
    status_.accessibilityElementsHidden = statusHidden;
    footerLabel_.text = [self footerText];
    [self applyColorAppearance];
    [table_ reloadData];
    [recommendationsTable_ reloadData];
    [self viewDidLayoutSubviews];
}

- (NSString *) footerText {
    UIDevice *device([UIDevice currentDevice]);
    NSString *machine(Machine_ == NULL ? nil : [NSString stringWithUTF8String:Machine_]);
    NSString *language([[NSLocale preferredLanguages] firstObject] ?: @"en");
    return CydiaHomeFooterText(machine, device.systemVersion,
        sizeof(void *) * 8, Cydia_, language, UniqueID_);
}

- (BOOL) openNativeRoute:(NSString *)route {
    id delegate([self delegate]);
    NSURL *url([NSURL URLWithString:route]);
    CydiaUIRouteContext *context([CydiaUIRouteContext trustedNativeContext]);
    if ([delegate respondsToSelector:@selector(pageForURL:context:withReferrer:)]) {
        CyteViewController *page([(Cydia *) delegate pageForURL:url
            context:context withReferrer:self.navigationURL.absoluteString]);
        if (page != nil && self.navigationController != nil) {
            [self.navigationController pushViewController:page animated:YES];
            return YES;
        }
    }
    if (![delegate respondsToSelector:@selector(openCydiaURL:context:)])
        return NO;
    return [(Cydia *) delegate openCydiaURL:url context:context];
}

- (void) openExternalURL:(NSURL *)url {
    NSURL *route(CydiaExternalURLRouteURL(url));
    if (route != nil)
        [self openNativeRoute:[route absoluteString]];
}

- (NSURL *) URLForHomeAction:(HomeAction)action {
    switch (action) {
        case HomeActionAuthor:
            return [NSURL URLWithString:@"https://www.saurik.com/"];
        case HomeActionFacebook:
            return [NSURL URLWithString:@"https://www.facebook.com/Cydia"];
        case HomeActionTwitter:
            return [NSURL URLWithString:@"https://twitter.com/saurik"];
        case HomeActionFeatured:
            return [NSURL URLWithString:@"cydia://home/featured"];
        case HomeActionThemes:
            return [NSURL URLWithString:@"cydia://home/themes"];
        case HomeActionAccount:
            return [NSURL URLWithString:@"cydia://home/account"];
        case HomeActionUpgrading:
            return [NSURL URLWithString:@"cydia://home/upgrading-jailbreaking/root"];
        case HomeActionApplications:
            return [NSURL URLWithString:@"cydia://home/application-extensions"];
        case HomeActionSourcesGuide:
            return [NSURL URLWithString:@"cydia://home/more-sources"];
        case HomeActionFAQ:
            return [NSURL URLWithString:@"cydia://home/faq"];
        case HomeActionCopying:
            return [NSURL URLWithString:@"cydia://home/copying-files"];
        case HomeActionOpenSSH:
            return [NSURL URLWithString:@"cydia://home/openssh"];
        case HomeActionRootPassword:
            return [NSURL URLWithString:@"cydia://home/root-password"];
        case HomeActionStorage:
            return [NSURL URLWithString:@"cydia://home/storage"];
        case HomeActionDeveloperResources:
            return [NSURL URLWithString:@"cydia://home/developer-resources"];
        case HomeActionCredits:
            return [NSURL URLWithString:@"cydia://home/credits"];
        case HomeActionPrivacy:
            return [NSURL URLWithString:@"cydia://home/privacy"];
    }
    return nil;
}

- (void) performHomeAction:(HomeAction)action {
    NSURL *url([self URLForHomeAction:action]);
    if (url != nil && (action == HomeActionFeatured || action == HomeActionThemes ||
                      action == HomeActionAccount || action == HomeActionFAQ || action == HomeActionUpgrading ||
                      action == HomeActionApplications || action == HomeActionSourcesGuide ||
                      action == HomeActionCopying || action == HomeActionOpenSSH ||
                      action == HomeActionRootPassword || action == HomeActionStorage ||
                      action == HomeActionDeveloperResources ||
                      action == HomeActionCredits || action == HomeActionPrivacy)) {
        [self openNativeRoute:[url absoluteString]];
    } else if (url != nil) {
        [self openExternalURL:url];
    }
}

- (void) splitButtonClicked:(UIButton *)button {
    [self performHomeAction:(HomeAction) button.tag];
}

- (void) authorButtonClicked {
    [self performHomeAction:HomeActionAuthor];
}

- (void) refreshButtonClicked {
    id delegate([self delegate]);
    if ([delegate respondsToSelector:@selector(requestUpdate)] && [delegate requestUpdate])
        [self reloadData];
}

- (void) cancelButtonClicked {
    id delegate([self delegate]);
    if ([delegate respondsToSelector:@selector(cancelUpdate)])
        [delegate cancelUpdate];
    [self reloadData];
}

- (void) aboutButtonClicked {
    NSString *refurbished([NSString stringWithFormat:
        UCLocalizeEx(@"ABOUT_REFURBISHED_COPYRIGHT", @"Refurbished work Copyright (C) %@"),
        @"2026"]);
    UIAlertController *alert([UIAlertController alertControllerWithTitle:UCLocalize("ABOUT_CYDIA")
        message:[NSString stringWithFormat:
                @"Original work Copyright (C) 2008-2017\nSaurikIT, LLC\n\n"
                "Jay Freeman (saurik)\nhttp://www.saurik.com/\n\n"
                "Modified work Copyright (C) 2018\nSB Designs, INC\n\n"
                "Sam Bingner (sbingner)\nhttp://www.bingner.com/\n\n"
                "%@\nTorrekie\nhttps://torrekie.dev/", refurbished]
        preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CLOSE")
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return tableView == recommendationsTable_ ? 2 : 7;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == recommendationsTable_)
        return section == 0 ? (NSInteger) HomeArrayCount(HomeIPadExtensions) :
            section == 1 ? (NSInteger) HomeArrayCount(HomeIPadProducts) : 0;
    switch (section) {
        case HomeSectionSocial:
        case HomeSectionDiscovery:
        case HomeSectionAccount:
        case HomeSectionDevelopers:
            return 1;
        case HomeSectionHelp:
            return (NSInteger) HomeArrayCount(HomeHelpLinks);
        case HomeSectionGuides:
            return (NSInteger) HomeArrayCount(HomeGuideLinks);
        case HomeSectionLegal:
            return (NSInteger) HomeArrayCount(HomeLegalLinks);
    }
    return 0;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (tableView == recommendationsTable_)
        return section == 0 ?
            HomeLocalized("HOME_IPAD_EXTENSIONS", "Extensions Useful on iPad") :
            HomeLocalized("HOME_IPAD_PRODUCTS", "Products Designed for iPad");
    if (section == HomeSectionGuides)
        return HomeLocalized("USER_GUIDES", "User Guides");
    if (section == HomeSectionDevelopers)
        return HomeLocalized("DEVELOPERS_ONLY", "Developers Only");
    return nil;
}

- (const HomeRecommendation *) recommendationAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 &&
        indexPath.row < (NSInteger) HomeArrayCount(HomeIPadExtensions))
        return &HomeIPadExtensions[indexPath.row];
    if (indexPath.section == 1 &&
        indexPath.row < (NSInteger) HomeArrayCount(HomeIPadProducts))
        return &HomeIPadProducts[indexPath.row];
    return NULL;
}

- (UITableViewCell *) tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == recommendationsTable_) {
        const HomeRecommendation *recommendation([self recommendationAtIndexPath:indexPath]);
        NSString *identifier(recommendation == NULL ? @"cydia.home.ipad.unknown" :
            [@"cydia.home.ipad." stringByAppendingString:
                HomeNSString(recommendation->identifier)]);
        UITableViewCell *cell([[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier]);
        cell.accessibilityIdentifier = identifier;
        HomeApplyCellSurface(cell, CydiaColorRoleCellBackground, [self homeAppearanceTraits]);
        cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
                                              traitCollection:[self homeAppearanceTraits]];
        cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                                    traitCollection:[self homeAppearanceTraits]];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.numberOfLines = 0;
        if (recommendation != NULL) {
            NSString *packageID(HomeNSString(recommendation->identifier));
            cell.textLabel.text = HomeNSString(recommendation->name);
            cell.detailTextLabel.text = HomeNSString(recommendation->summary);
            Package *package([database_ packageWithName:packageID]);
            UIImage *packageIcon([package icon] ?: HomeImage(@"unknown.png"));
            cell.imageView.image = HomeScaleImage(packageIcon, CGSizeMake(30, 30));
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == HomeSectionSocial ||
        indexPath.section == HomeSectionDiscovery) {
        const HomeLinkDescriptor *links(indexPath.section == HomeSectionSocial ?
            HomeSocialLinks : HomeDiscoveryLinks);
        NSString *identifier(indexPath.section == HomeSectionSocial ?
            @"cydia.home.social" : @"cydia.home.discovery");
        CydiaHomeSplitLinkCell *cell([[CydiaHomeSplitLinkCell alloc]
            initWithReuseIdentifier:identifier]);
        cell.accessibilityIdentifier = identifier;
        [cell configureLeftTitle:HomeLocalized(links[0].localizationKey, links[0].fallback)
            leftImage:HomeImageSized(HomeNSString(links[0].imageName), CGSizeMake(30, 30))
            leftIdentifier:HomeNSString(links[0].identifier)
            leftAction:links[0].action
            rightTitle:HomeLocalized(links[1].localizationKey, links[1].fallback)
            rightImage:HomeImageSized(HomeNSString(links[1].imageName), CGSizeMake(30, 30))
            rightIdentifier:HomeNSString(links[1].identifier)
            rightAction:links[1].action
            target:self action:@selector(splitButtonClicked:)
            traitCollection:[self homeAppearanceTraits]];
        return cell;
    }

    const HomeLinkDescriptor *descriptor(HomeStandardDescriptor(indexPath));
    NSString *identifier(descriptor == NULL ? @"cydia.home.unknown" :
        HomeNSString(descriptor->identifier));
    UITableViewCell *cell([[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier]);
    cell.accessibilityIdentifier = identifier;
    CydiaColorRole surfaceRole(descriptor != NULL &&
        descriptor->action == HomeActionAccount ? CydiaColorRoleInstallingBackground :
        CydiaColorRoleCellBackground);
    HomeApplyCellSurface(cell, surfaceRole, [self homeAppearanceTraits]);
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
                                          traitCollection:[self homeAppearanceTraits]];
    if (descriptor != NULL) {
        cell.textLabel.text = HomeLocalized(descriptor->localizationKey,
            descriptor->fallback);
        cell.imageView.image = HomeImageSized(HomeNSString(descriptor->imageName),
            CGSizeMake(30, 30));
        cell.tag = descriptor->action;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void) tableView:(UITableView *)tableView
    willDisplayCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void) indexPath;
    HomeApplyCellAppearance(cell, [self homeAppearanceTraits]);
    (void) tableView;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (tableView == recommendationsTable_) {
        const HomeRecommendation *recommendation([self recommendationAtIndexPath:indexPath]);
        if (recommendation != NULL)
            [self openNativeRoute:[@"cydia://package/" stringByAppendingString:
                HomeNSString(recommendation->identifier)]];
        return;
    }
    const HomeLinkDescriptor *descriptor(HomeStandardDescriptor(indexPath));
    if (descriptor != NULL)
        [self performHomeAction:descriptor->action];
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView != recommendationsTable_ && indexPath.section == HomeSectionAccount &&
        !HomeIsAccessibilityCategory([self homeAppearanceTraits]))
        return 44.0;
    return UITableViewAutomaticDimension;
}

- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    NSString *title([self tableView:tableView titleForHeaderInSection:section]);
    if ([title length] != 0)
        return 24.0;
    /* UIKit's grouped style otherwise supplies a large implicit header even
     * for untitled sections, separating the social and discovery lanes more
     * than the historical Home page did. */
    return 0.01;
}

- (CGFloat) tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (tableView != recommendationsTable_ && section == HomeSectionSocial)
        return 0.01;
    NSInteger sectionCount([self numberOfSectionsInTableView:tableView]);
    return section + 1 < sectionCount ? 12.0 : 0.01;
}

@end
/* }}} */
