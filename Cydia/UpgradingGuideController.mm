/* Cydia Refurbished native upgrading and jailbreaking guide.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "Cydia/UpgradingGuideController.h"
#include "Cydia/TableViewCompatibility.h"
#include "Cydia/UIRouteContext.h"
#include "Cydia/ExternalURLPolicy.h"
#include "Cydia/UIColor+Cydia.h"
#include "Cydia/HomeTableAppearance.h"
#include "Cydia/NativeAccessibilityTrace.h"
#include "CyteKit/Localize.h"

/* These are the same typed selectors used by HomeController and implemented
 * by Cydia (Navigation). No private or selector-string dispatch is needed. */
@protocol CydiaGuideRouteDelegate <NSObject>
- (CyteViewController *)pageForURL:(NSURL *)URL
    context:(NSObject<CyteWebNavigationContext> *)context withReferrer:(NSString *)referrer;
- (BOOL)openCydiaURL:(NSURL *)URL context:(CydiaUIRouteContext *)context;
@end

namespace {
NSDictionary *GuidePages() {
    static NSDictionary *pages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *URL = [[NSBundle mainBundle] URLForResource:@"UpgradingGuide" withExtension:@"json"];
        NSData *data = URL == nil ? nil : [NSData dataWithContentsOfURL:URL];
        NSDictionary *document = data == nil ? nil :
            [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([document isKindOfClass:[NSDictionary class]] && [document[@"schema"] isEqual:@1] &&
            [document[@"pages"] isKindOfClass:[NSDictionary class]])
            pages = document[@"pages"];
    });
    return pages;
}

NSString *GuideText(NSString *page, NSString *field, NSString *fallback) {
    /* Unique per-page/per-row keys: translating one child must not rename all
     * children. Keep the authored fallback when no localized value exists. */
    return UCLocalizeEx([NSString stringWithFormat:@"UPGRADING_%@_%@", page, field],
        fallback);
}

static UIFont *GuideRunFont(UIFont *font, NSDictionary *run) {
    UIFontDescriptorSymbolicTraits traits = font.fontDescriptor.symbolicTraits;
    if ([run[@"bold"] boolValue])
        traits |= UIFontDescriptorTraitBold;
    if ([run[@"italic"] boolValue])
        traits |= UIFontDescriptorTraitItalic;
    UIFontDescriptor *descriptor = [font.fontDescriptor
        fontDescriptorWithSymbolicTraits:traits];
    CGFloat scale = [run[@"scale"] doubleValue];
    if (scale <= 0.0)
        scale = 1.0;
    return descriptor == nil ? font :
        ([UIFont fontWithDescriptor:descriptor size:font.pointSize * scale] ?: font);
}

/* Keep authored emphasis in data when available, while retaining the strong
 * version-number treatment used by the source tools page for the existing
 * compact data rows.  The helper is deliberately UIKit-only and works on the
 * iOS 12 deployment target. */
static NSAttributedString *GuideAttributedText(NSString *text, UIFont *font,
                                                NSArray *runs,
                                                BOOL emphasizeVersions,
                                                UITraitCollection *traits) {
    if (text == nil)
        text = @"";
    if (font == nil)
        font = [UIFont systemFontOfSize:17.0];
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc]
        initWithString:text attributes:@{NSFontAttributeName: font,
            NSForegroundColorAttributeName:[UIColor cydiaColorForRole:CydiaColorRoleLabel
                traitCollection:traits]}];
    if ([runs isKindOfClass:[NSArray class]] && runs.count != 0) {
        NSUInteger cursor = 0;
        for (NSDictionary *run in runs) {
            if (![run isKindOfClass:[NSDictionary class]] ||
                    ![run[@"text"] isKindOfClass:[NSString class]])
                continue;
            NSString *runText = run[@"text"];
            NSRange search = NSMakeRange(cursor, text.length - cursor);
            NSRange range = [text rangeOfString:runText options:0 range:search];
            if (range.location == NSNotFound)
                range = [text rangeOfString:runText];
            if (range.location == NSNotFound)
                continue;
            [result addAttribute:NSFontAttributeName value:GuideRunFont(font, run)
                range:range];
            if ([run[@"obsolete"] boolValue])
                [result addAttribute:NSStrikethroughStyleAttributeName
                    value:@(NSUnderlineStyleSingle) range:range];
            if ([run[@"secondary"] boolValue])
                [result addAttribute:NSForegroundColorAttributeName
                    value:[UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                        traitCollection:traits] range:range];
            NSString *destination = [run[@"link"] isKindOfClass:[NSString class]] ?
                run[@"link"] : nil;
            NSURL *URL = destination == nil ? nil : [NSURL URLWithString:destination];
            if (URL != nil) {
                [result addAttribute:NSLinkAttributeName value:URL range:range];
                [result addAttribute:NSUnderlineStyleAttributeName
                    value:@(NSUnderlineStyleSingle) range:range];
            }
            cursor = NSMaxRange(range);
        }
        return result;
    }
    if (!emphasizeVersions)
        return result;

    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"(?<![A-Za-z])\\d+(?:\\.\\d+)+"
        options:0 error:NULL];
    UIFont *bold = GuideRunFont(font, @{@"bold": @YES});
    for (NSTextCheckingResult *match in
            [expression matchesInString:text options:0 range:NSMakeRange(0, text.length)])
        [result addAttribute:NSFontAttributeName value:bold range:match.range];
    return result;
}
}

// UITableViewCell's legacy textLabel uses manual layout; setting numberOfLines
// alone does not give automaticDimension a vertical constraint chain.
@interface CydiaGuideTableCell : UITableViewCell
@property(nonatomic, strong) UILabel *guideLabel;
@property(nonatomic, strong) UITextView *guideTextView;
@property(nonatomic, strong) UIImageView *guideImage;
@property(nonatomic, strong) NSLayoutConstraint *imageWidth;
@property(nonatomic, strong) NSLayoutConstraint *imageGap;
@property(nonatomic) BOOL secondaryText;
- (void)setGuideIcon:(UIImage *)image;
@end

@implementation CydiaGuideTableCell
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil])) {
        _guideLabel = [[UILabel alloc] init];
        _guideLabel.numberOfLines = 0;
        _guideLabel.accessibilityIdentifier = @"cydia.home.upgrading.label";
        _guideLabel.isAccessibilityElement = NO;
        _guideLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _guideLabel.adjustsFontForContentSizeCategory = YES;
        _guideTextView = [[UITextView alloc] init];
        _guideTextView.editable = NO;
        _guideTextView.selectable = YES;
        _guideTextView.scrollEnabled = NO;
        _guideTextView.backgroundColor = UIColor.clearColor;
        _guideTextView.textContainerInset = UIEdgeInsetsZero;
        _guideTextView.textContainer.lineFragmentPadding = 0.0;
        _guideTextView.accessibilityIdentifier = @"cydia.home.upgrading.richText";
        _guideTextView.hidden = YES;
        _guideTextView.translatesAutoresizingMaskIntoConstraints = NO;
        _secondaryText = NO;
        _guideImage = [[UIImageView alloc] init];
        _guideImage.contentMode = UIViewContentModeScaleAspectFit;
        _guideImage.isAccessibilityElement = NO;
        _guideImage.accessibilityIdentifier = @"cydia.home.upgrading.icon";
        _guideImage.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_guideImage];
        [self.contentView addSubview:_guideLabel];
        [self.contentView addSubview:_guideTextView];
        _imageWidth = [_guideImage.widthAnchor constraintEqualToConstant:0];
        _imageGap = [_guideLabel.leadingAnchor constraintEqualToAnchor:_guideImage.trailingAnchor];
        [NSLayoutConstraint activateConstraints:@[
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
            [_guideImage.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            _imageWidth, [_guideImage.heightAnchor constraintEqualToConstant:32],
            [_guideImage.centerYAnchor constraintEqualToAnchor:_guideLabel.centerYAnchor],
            _imageGap,
            [_guideLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_guideLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_guideLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
            [_guideTextView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_guideTextView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_guideTextView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_guideTextView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        ]];
    }
    return self;
}
- (void)setGuideIcon:(UIImage *)image {
    _guideImage.image = image;
    _imageWidth.constant = image == nil ? 0 : 32;
    _imageGap.constant = image == nil ? 0 : 12;
}
@end

@interface UpgradingGuideController () <UITableViewDataSource, UITableViewDelegate, UITextViewDelegate>
@property(nonatomic, copy, readwrite) NSString *pageIdentifier;
@property(nonatomic, strong) NSDictionary *page;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, copy) NSArray<NSString *> *bodyParts;
@property(nonatomic, copy) NSArray<NSArray<NSDictionary *> *> *bodyRuns;
/* On an iPad regular-width root, the guide keeps its master list in the
 * primary column and renders selected children in a secondary navigation
 * column.  Compact width never creates this container and retains the
 * existing push-navigation path. */
@property(nonatomic, strong) UISplitViewController *guideSplitViewController;
@property(nonatomic, strong) UINavigationController *guideSecondaryNavigation;
@property(nonatomic, copy) NSString *splitSelectedPageIdentifier;
- (NSArray<NSArray<NSDictionary *> *> *)detailLinkGroups;
@end

@implementation UpgradingGuideController

+ (NSArray<NSString *> *)pageIdentifiers {
    return [[GuidePages() allKeys] sortedArrayUsingSelector:@selector(compare:)] ?: @[];
}

- (instancetype)init {
    return [self initWithPageIdentifier:@"root"];
}

- (instancetype)initWithPageIdentifier:(NSString *)identifier {
    NSDictionary *page = identifier == nil ? nil : GuidePages()[identifier];
    if (![page isKindOfClass:[NSDictionary class]])
        return nil;
    if ((self = [super init]) != nil) {
        _pageIdentifier = [identifier copy];
        _page = page;
        /* The root shares Home's translated heading. Child titles retain
         * their individual authored fallbacks and per-page lookup keys. */
        self.title = [identifier isEqualToString:@"root"] ?
            UCLocalizeEx(@"HOME_UPGRADING_HELP", page[@"title"]) :
            GuideText(identifier, @"title", page[@"title"]);
        NSString *body = GuideText(identifier, @"body", page[@"body"]);
        NSArray *authoredBodyParts = page[@"bodyParts"];
        if ([authoredBodyParts isKindOfClass:[NSArray class]] && authoredBodyParts.count != 0)
            _bodyParts = [authoredBodyParts copy];
        else
            _bodyParts = @[body];
        NSArray *authoredBodyRuns = page[@"bodyRuns"];
        _bodyRuns = [authoredBodyRuns isKindOfClass:[NSArray class]] ?
            [authoredBodyRuns copy] : @[];
    }
    return self;
}

- (NSURL *)navigationURL {
    /* Identifier comes from the finite bundled model, never arbitrary input. */
    if (self.guideSecondaryNavigation != nil && self.hasDisplayedSplitPage) {
        NSURL *selected = [self.guideSecondaryNavigation.topViewController navigationURL];
        if (selected != nil)
            return selected;
    }
    return [NSURL URLWithString:[@"cydia://home/upgrading-jailbreaking/"
        stringByAppendingString:_pageIdentifier]];
}

- (BOOL)hasLinkDetails {
    if (![_pageIdentifier isEqualToString:@"tools"])
        return NO;
    for (NSDictionary *link in _page[@"links"]) {
        if ([link[@"detail"] isKindOfClass:[NSString class]] &&
                [link[@"detail"] length] != 0)
            return YES;
    }
    return NO;
}

- (NSArray<NSArray<NSDictionary *> *> *)detailLinkGroups {
    if (![self hasLinkDetails])
        return @[];
    NSMutableArray *groups = [NSMutableArray array];
    for (NSDictionary *link in _page[@"links"]) {
        NSString *detail = [link[@"detail"] isKindOfClass:[NSString class]] ?
            link[@"detail"] : @"";
        NSMutableArray *last = groups.lastObject;
        NSDictionary *first = last.firstObject;
        NSString *lastDetail = [first[@"detail"] isKindOfClass:[NSString class]] ?
            first[@"detail"] : @"";
        if (last != nil && [lastDetail isEqualToString:detail])
            [last addObject:link];
        else
            [groups addObject:[NSMutableArray arrayWithObject:link]];
    }
    return groups;
}

- (BOOL)hasLinkGroups {
    return [_page[@"groups"] isKindOfClass:[NSArray class]] &&
        [_page[@"groups"] count] != 0;
}

- (BOOL)hasRootBulletinLayout {
    return [_pageIdentifier isEqualToString:@"root"] && _bodyParts.count >= 3;
}

- (BOOL)isBodySection:(NSInteger)section {
    if ([self hasRootBulletinLayout])
        return section == 0 || section == 2 || section == 3;
    return section >= 0 && section < _bodyParts.count;
}

/* Inline anchors remain in their text block. Only authored resource rows
 * belong in the standalone list; links also retains the route inventory. */
- (NSArray<NSDictionary *> *)displayedResourceLinks {
    NSArray *identifiers = _page[@"displayResources"];
    if (![identifiers isKindOfClass:[NSArray class]])
        return _page[@"links"] ?: @[];
    NSMutableArray *links = [NSMutableArray array];
    for (NSString *identifier in identifiers)
        for (NSDictionary *link in _page[@"links"])
            if ([link[@"id"] isEqual:identifier]) {
                [links addObject:link];
                break;
            }
    return links;
}

- (NSInteger)bodyPartIndexForSection:(NSInteger)section {
    if (![self isBodySection:section])
        return NSNotFound;
    if ([self hasRootBulletinLayout])
        return section == 0 ? 0 : section - 1;
    return section;
}

- (NSDictionary *)groupedLinkAtIndexPath:(NSIndexPath *)path {
    NSArray *groups = _page[@"groups"];
    if (path.section < 1 || path.section - 1 >= groups.count)
        return nil;
    NSDictionary *group = groups[path.section - 1];
    NSArray *identifiers = group[@"links"];
    if (![identifiers isKindOfClass:[NSArray class]] || path.row >= identifiers.count)
        return nil;
    NSString *identifier = identifiers[path.row];
    for (NSDictionary *link in _page[@"links"]) {
        if ([link[@"id"] isEqual:identifier])
            return link;
    }
    return nil;
}

- (BOOL)shouldUseRegularWidthSplit {
    if (![self.pageIdentifier isEqualToString:@"root"])
        return NO;
    if (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular)
        return YES;
    /* A host that has not propagated traits yet can still be an iPad-sized
     * window.  This keeps the iOS 12 path deterministic without consulting a
     * private API. */
    return CGRectGetWidth(UIScreen.mainScreen.bounds) >= 700.0;
}

- (UIViewController *)guideSplitPlaceholderController {
    UIViewController *placeholder = [[UIViewController alloc] init];
    placeholder.title = UCLocalizeEx(@"HOME_UPGRADING_SELECT", @"Select a guide");
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
        traitCollection:self.traitCollection];
    UILabel *label = [[UILabel alloc] init];
    label.text = placeholder.title;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.adjustsFontForContentSizeCategory = YES;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
        traitCollection:self.traitCollection];
    [view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:view.leadingAnchor constant:24],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:view.trailingAnchor constant:-24],
        [label.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
    ]];
    placeholder.view = view;
    return placeholder;
}

- (void)configureRegularWidthSplit {
    if (self.guideSplitViewController != nil || ![self shouldUseRegularWidthSplit])
        return;

    /* The current table remains the data-source owner.  Reparent only the
     * table view into a primary column; the compact path still uses the same
     * table directly as the controller's view. */
    UIViewController *primaryColumn = [[UIViewController alloc] init];
    primaryColumn.title = UCLocalizeEx(@"HOME_UPGRADING_SHORT_TITLE", @"Upgrading");
    UIView *primaryView = [[UIView alloc] initWithFrame:CGRectZero];
    primaryView.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
        traitCollection:self.traitCollection];
    [self.tableView removeFromSuperview];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [primaryView addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:primaryView.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:primaryView.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:primaryView.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:primaryView.bottomAnchor],
    ]];
    primaryColumn.view = primaryView;
    primaryColumn.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:UCLocalizeEx(@"HOME", @"Home") style:UIBarButtonItemStylePlain
        target:self action:@selector(splitHomeButtonTapped:)];

    UINavigationController *primaryNavigation = [[UINavigationController alloc]
        initWithRootViewController:primaryColumn];
    UINavigationController *secondaryNavigation = [[UINavigationController alloc]
        initWithRootViewController:[self guideSplitPlaceholderController]];
    UISplitViewController *split = [[UISplitViewController alloc] init];
    split.preferredDisplayMode = UISplitViewControllerDisplayModeAllVisible;
    split.minimumPrimaryColumnWidth = 280.0;
    split.maximumPrimaryColumnWidth = 390.0;
    if ([split respondsToSelector:@selector(setPreferredPrimaryColumnWidthFraction:)])
        split.preferredPrimaryColumnWidthFraction = 0.34;
    split.viewControllers = @[primaryNavigation, secondaryNavigation];
    primaryNavigation.navigationBarHidden = NO;
    secondaryNavigation.navigationBarHidden = NO;
    self.guideSplitViewController = split;
    self.guideSecondaryNavigation = secondaryNavigation;

    UIView *splitRoot = [[UIView alloc] initWithFrame:CGRectZero];
    splitRoot.backgroundColor = primaryView.backgroundColor;
    [self addChildViewController:split];
    split.view.translatesAutoresizingMaskIntoConstraints = NO;
    [splitRoot addSubview:split.view];
    [NSLayoutConstraint activateConstraints:@[
        [split.view.leadingAnchor constraintEqualToAnchor:splitRoot.leadingAnchor],
        [split.view.trailingAnchor constraintEqualToAnchor:splitRoot.trailingAnchor],
        [split.view.topAnchor constraintEqualToAnchor:splitRoot.topAnchor],
        [split.view.bottomAnchor constraintEqualToAnchor:splitRoot.bottomAnchor],
    ]];
    self.view = splitRoot;
    [split didMoveToParentViewController:self];
    [self applyColorAppearance];
}

- (void)splitHomeButtonTapped:(id)sender {
    if (self.navigationController != nil)
        [self.navigationController popViewControllerAnimated:YES];
}

- (void)showSplitGuidePage:(NSString *)identifier {
    if (self.guideSecondaryNavigation == nil || identifier.length == 0)
        return;
    UpgradingGuideController *child = [[UpgradingGuideController alloc]
        initWithPageIdentifier:identifier];
    if (child == nil)
        return;
    [child setDelegate:[self delegate]];
    self.splitSelectedPageIdentifier = identifier;
    /* Give the active detail table the stable route identity.  The master is
     * still visible, but this prevents accessibility/probe traversal from
     * mistaking the inactive list for the selected detail. */
    self.tableView.accessibilityIdentifier = @"cydia.home.upgrading.master.rows";
    UIViewController *placeholder = self.guideSecondaryNavigation.viewControllers.firstObject;
    if (placeholder == nil || placeholder == child)
        placeholder = [self guideSplitPlaceholderController];
    [self.guideSecondaryNavigation setViewControllers:@[placeholder, child] animated:YES];
}

- (BOOL)popDisplayedSplitPage {
    if (self.guideSecondaryNavigation == nil)
        return NO;
    if (self.guideSecondaryNavigation.viewControllers.count > 1) {
        [self.guideSecondaryNavigation popViewControllerAnimated:NO];
        if (self.guideSecondaryNavigation.viewControllers.count == 1) {
            self.splitSelectedPageIdentifier = nil;
            self.tableView.accessibilityIdentifier = @"cydia.home.upgrading.rows";
            UINavigationController *primaryNavigation =
                (UINavigationController *)self.guideSplitViewController.viewControllers.firstObject;
            primaryNavigation.viewControllers.firstObject.navigationItem.leftBarButtonItem =
                [[UIBarButtonItem alloc] initWithTitle:UCLocalizeEx(@"HOME", @"Home")
                    style:UIBarButtonItemStylePlain target:self action:@selector(splitHomeButtonTapped:)];
        }
        return YES;
    }
    UIViewController *detail = self.guideSecondaryNavigation.topViewController;
    if (detail != nil && ![detail.title isEqualToString:
            UCLocalizeEx(@"HOME_UPGRADING_SELECT", @"Select a guide")]) {
        [self.guideSecondaryNavigation popViewControllerAnimated:NO];
        if (self.guideSecondaryNavigation.viewControllers.count == 1) {
            self.splitSelectedPageIdentifier = nil;
            self.tableView.accessibilityIdentifier = @"cydia.home.upgrading.rows";
            UINavigationController *primaryNavigation =
                (UINavigationController *)self.guideSplitViewController.viewControllers.firstObject;
            primaryNavigation.viewControllers.firstObject.navigationItem.leftBarButtonItem =
                [[UIBarButtonItem alloc] initWithTitle:UCLocalizeEx(@"HOME", @"Home")
                    style:UIBarButtonItemStylePlain target:self action:@selector(splitHomeButtonTapped:)];
        }
        return YES;
    }
    return NO;
}

- (BOOL)hasDisplayedSplitPage {
    return self.guideSecondaryNavigation != nil &&
        self.guideSecondaryNavigation.topViewController != nil &&
        ![self.guideSecondaryNavigation.topViewController.title isEqualToString:
            UCLocalizeEx(@"HOME_UPGRADING_SELECT", @"Select a guide")];
}

- (void)loadView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 64.0;
    _tableView.sectionHeaderHeight = 0.01;
    _tableView.sectionFooterHeight = 0.01;
    _tableView.accessibilityIdentifier = @"cydia.home.upgrading.rows";
    /* Keep the native guide's body/link groups close together like the
     * original page.  iOS 15 adds implicit top padding to grouped tables;
     * the availability guard preserves the iOS 12 path. */
    if (@available(iOS 15.0, *))
        _tableView.sectionHeaderTopPadding = 0.0;
    UIView *tableRoot = [[UIView alloc] initWithFrame:CGRectZero];
    tableRoot.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
        traitCollection:self.traitCollection];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [tableRoot addSubview:_tableView];
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.leadingAnchor constraintEqualToAnchor:tableRoot.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:tableRoot.trailingAnchor],
        [_tableView.topAnchor constraintEqualToAnchor:tableRoot.topAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:tableRoot.bottomAnchor],
    ]];
    self.view = tableRoot;
    [self applyColorAppearance];
    [self configureRegularWidthSplit];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if ([self hasLinkDetails])
        /* Keep each authored description and its action in one grouped card;
         * alternating one-row sections make the native layout look unrelated. */
        return 1 + (NSInteger)[[self detailLinkGroups] count];
    if ([self hasLinkGroups])
        return 1 + (NSInteger)[_page[@"groups"] count];
    if ([self hasRootBulletinLayout])
        return 4;
    return _bodyParts.count + ([self displayedResourceLinks].count != 0 ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self hasLinkDetails]) {
        if (section == 0)
            return 1;
        NSArray *groups = [self detailLinkGroups];
        return section > 0 && section - 1 < groups.count ?
            1 + [groups[section - 1] count] : 0;
    }
    if ([self hasLinkGroups]) {
        if (section == 0)
            return 0;
        NSArray *groups = _page[@"groups"];
        return section - 1 < groups.count ? [groups[section - 1][@"links"] count] : 0;
    }
    if ([self hasRootBulletinLayout])
        return section == 1 ? MIN((NSInteger)3, (NSInteger)[_page[@"links"] count]) :
            ([self isBodySection:section] ? 1 : 0);
    if ([self isBodySection:section])
        return 1;
    return section == _bodyParts.count ? [self displayedResourceLinks].count : 0;
}

- (NSDictionary *)linkAtIndexPath:(NSIndexPath *)path {
    if (path.section < 0 || path.row < 0 ||
            path.section >= [self numberOfSectionsInTableView:_tableView] ||
            path.row >= [self tableView:_tableView numberOfRowsInSection:path.section])
        return nil;
    if ([self hasLinkDetails]) {
        /* Row zero is the shared non-action detail; following rows dispatch
         * each action in that detail group. */
        if (path.section == 0 || path.row == 0)
            return nil;
        NSArray *groups = [self detailLinkGroups];
        NSInteger groupIndex = path.section - 1;
        NSInteger linkIndex = path.row - 1;
        return groupIndex >= 0 && groupIndex < groups.count &&
            linkIndex >= 0 && linkIndex < [groups[groupIndex] count] ?
            groups[groupIndex][linkIndex] : nil;
    }
    if ([self hasLinkGroups])
        return [self groupedLinkAtIndexPath:path];
    if ([self hasRootBulletinLayout])
        return path.section == 1 && path.row < 3 ? _page[@"links"][path.row] : nil;
    NSArray *resources = [self displayedResourceLinks];
    return path.section == _bodyParts.count && path.row < resources.count ?
        resources[path.row] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)path {
    CydiaGuideTableCell *cell = [[CydiaGuideTableCell alloc] init];
    cell.guideLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
        compatibleWithTraitCollection:self.traitCollection];
    cell.isAccessibilityElement = YES;
    if ([self hasLinkDetails] && path.section > 0) {
        NSArray *groups = [self detailLinkGroups];
        NSInteger groupIndex = path.section - 1;
        NSArray *group = groupIndex >= 0 && groupIndex < groups.count ?
            groups[groupIndex] : @[];
        NSDictionary *link = path.row > 0 && path.row - 1 < group.count ?
            group[path.row - 1] : nil;
        if (path.row == 0) {
            /* Compatibility descriptions are primary authored content, not
             * disabled actions. Preserve their readable black text. */
            cell.secondaryText = NO;
            cell.guideLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline
                compatibleWithTraitCollection:self.traitCollection];
            cell.guideLabel.text = GuideText(_pageIdentifier,
                [@"detail." stringByAppendingString:group.firstObject[@"id"]],
                group.firstObject[@"detail"]);
            BOOL emphasizeVersions = [_pageIdentifier isEqualToString:@"tools"] &&
                ![@[@"jailbreakme-star", @"spirit", @"blackra1n", @"purplera1n",
                    @"quickpwn-mac", @"quickpwn-win"] containsObject:group.firstObject[@"id"]];
            cell.guideLabel.attributedText = GuideAttributedText(cell.guideLabel.text,
                cell.guideLabel.font, group.firstObject[@"detailRuns"] ?: group.firstObject[@"runs"],
                emphasizeVersions, self.traitCollection);
            cell.accessibilityIdentifier = [@"cydia.home.upgrading.detail."
                stringByAppendingString:group.firstObject[@"id"]];
            cell.accessibilityTraits = UIAccessibilityTraitStaticText;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (link != nil) {
            cell.guideLabel.text = GuideText(_pageIdentifier,
                [@"link." stringByAppendingString:link[@"id"]], link[@"title"]);
            cell.accessibilityIdentifier = [@"cydia.home.upgrading.row."
                stringByAppendingString:link[@"id"]];
            cell.accessibilityTraits = UIAccessibilityTraitButton;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            NSString *asset = link[@"image"];
            if (asset != nil)
                [cell setGuideIcon:[UIImage imageNamed:[@"GuideAssets/" stringByAppendingString:asset]]];
        }
    } else if ([self hasLinkGroups] && path.section > 0) {
        NSDictionary *link = [self linkAtIndexPath:path];
        cell.guideLabel.text = GuideText(_pageIdentifier,
            [@"link." stringByAppendingString:link[@"id"]], link[@"title"]);
        cell.accessibilityIdentifier = [@"cydia.home.upgrading.row."
            stringByAppendingString:link[@"id"]];
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSString *asset = link[@"image"];
        if (asset != nil)
            [cell setGuideIcon:[UIImage imageNamed:[@"GuideAssets/" stringByAppendingString:asset]]];
    } else if ([self isBodySection:path.section]) {
        cell.guideLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline
            compatibleWithTraitCollection:self.traitCollection];
        NSInteger bodyIndex = [self bodyPartIndexForSection:path.section];
        cell.guideLabel.text = _bodyParts[bodyIndex];
        NSArray *runs = bodyIndex >= 0 && bodyIndex < _bodyRuns.count ?
            _bodyRuns[bodyIndex] : @[];
        if (runs.count != 0) {
            cell.guideLabel.hidden = YES;
            cell.guideTextView.hidden = NO;
            cell.guideTextView.delegate = self;
            cell.guideTextView.font = cell.guideLabel.font;
            cell.guideTextView.attributedText = GuideAttributedText(cell.guideLabel.text,
                cell.guideLabel.font, runs, NO, self.traitCollection);
        }
        cell.accessibilityIdentifier = bodyIndex == 0 ?
            @"cydia.home.upgrading.body.text" : @"cydia.home.upgrading.body.continuation";
        cell.accessibilityTraits = UIAccessibilityTraitStaticText;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSDictionary *link = [self linkAtIndexPath:path];
        cell.guideLabel.text = GuideText(_pageIdentifier,
            [@"link." stringByAppendingString:link[@"id"]], link[@"title"]);
        cell.accessibilityIdentifier = [@"cydia.home.upgrading.row."
            stringByAppendingString:link[@"id"]];
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        NSString *asset = link[@"image"];
        if (asset != nil)
            [cell setGuideIcon:[UIImage imageNamed:[@"GuideAssets/" stringByAppendingString:asset]]];
    }
    NSDictionary *resource = [self linkAtIndexPath:path];
    NSString *subtitle = resource[@"subtitle"];
    if ([subtitle isKindOfClass:[NSString class]] && subtitle.length != 0) {
        NSString *title = cell.guideLabel.text ?: @"";
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@\n%@", title, subtitle]
            attributes:@{NSFontAttributeName:cell.guideLabel.font,
                NSForegroundColorAttributeName:[UIColor cydiaColorForRole:CydiaColorRoleLabel
                    traitCollection:self.traitCollection]}];
        UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote
            compatibleWithTraitCollection:self.traitCollection];
        [text addAttributes:@{NSFontAttributeName:GuideRunFont(font, @{@"italic":@YES}),
            NSForegroundColorAttributeName:[UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                traitCollection:self.traitCollection]}
            range:NSMakeRange(title.length + 1, subtitle.length)];
        cell.guideLabel.attributedText = text;
    }
    cell.accessibilityLabel = cell.guideLabel.text;
    [self applyAppearanceToCell:cell];
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (![self hasLinkGroups] && ![self hasLinkDetails] &&
            ![self hasRootBulletinLayout] && section == _bodyParts.count)
        return _page[@"resourceTitle"];
    if (![self hasLinkGroups] || section == 0)
        return nil;
    NSDictionary *group = _page[@"groups"][section - 1];
    return GuideText(_pageIdentifier,
        [@"group." stringByAppendingString:group[@"id"]], group[@"title"]);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    /* Only grouped link pages have authored section titles. */
    return [self tableView:tableView titleForHeaderInSection:section].length != 0 ?
        UITableViewAutomaticDimension : 0.01;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if ([self hasLinkDetails])
        return section + 1 < [self numberOfSectionsInTableView:tableView] ? 12.0 : 0.01;
    return 12.0;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
        forRowAtIndexPath:(NSIndexPath *)path {
    [self applyAppearanceToCell:cell];
}

- (BOOL)openGuideDestinationURL:(NSURL *)URL {
    if (URL == nil)
        return NO;
    if ([URL.scheme isEqualToString:@"cydia"] && [URL.host isEqualToString:@"home"]) {
        UpgradingGuideController *child = [[UpgradingGuideController alloc]
            initWithPageIdentifier:URL.lastPathComponent];
        if (child != nil) {
            [child setDelegate:[self delegate]];
            if (self.guideSplitViewController != nil &&
                    [self.pageIdentifier isEqualToString:@"root"]) {
                [self showSplitGuidePage:URL.lastPathComponent];
                return YES;
            }
            [self.navigationController pushViewController:child animated:YES];
        }
        return child != nil;
    }
    /* Package links stay native; other links enter the existing browser
     * coordinator with the originating guide as their restoration referrer. */
    NSURL *route = [URL.scheme isEqualToString:@"cydia"] ? URL : CydiaExternalURLRouteURL(URL);
    id<CydiaGuideRouteDelegate> delegate = [self delegate];
    CydiaUIRouteContext *context = [CydiaUIRouteContext trustedNativeContext];
    if (route != nil && [delegate respondsToSelector:@selector(pageForURL:context:withReferrer:)]) {
        CyteViewController *destination = [delegate pageForURL:route context:context
            withReferrer:self.navigationURL.absoluteString];
        if (destination != nil && self.navigationController != nil) {
            [destination setDelegate:delegate];
            if (self.guideSecondaryNavigation != nil &&
                    [self.pageIdentifier isEqualToString:@"root"]) {
                self.splitSelectedPageIdentifier = nil;
                self.tableView.accessibilityIdentifier = @"cydia.home.upgrading.master.rows";
                UIViewController *placeholder = self.guideSecondaryNavigation.viewControllers.firstObject;
                if (placeholder == nil)
                    placeholder = [self guideSplitPlaceholderController];
                [self.guideSecondaryNavigation setViewControllers:@[placeholder, destination]
                    animated:YES];
                return YES;
            }
            [self.navigationController pushViewController:destination animated:YES];
            return YES;
        }
    }
    if (route != nil && [delegate respondsToSelector:@selector(openCydiaURL:context:)])
        return [delegate openCydiaURL:route context:context];
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSDictionary *link = [self linkAtIndexPath:path];
    if (link == nil)
        return;
    [self openGuideDestinationURL:[NSURL URLWithString:link[@"destination"]]];
}

- (BOOL)textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)URL
        inRange:(NSRange)characterRange {
    [self openGuideDestinationURL:URL];
    return NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.guideSplitViewController != nil)
        self.navigationController.navigationBarHidden = YES;
    [self applyColorAppearance];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.guideSplitViewController != nil)
        self.navigationController.navigationBarHidden = NO;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    CydiaCaptureNativeAccessibility(self, @"upgrading-guide");
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    BOOL sizeChanged = ![previous.preferredContentSizeCategory
        isEqualToString:self.traitCollection.preferredContentSizeCategory];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) || sizeChanged) {
        [_tableView reloadData];
        [self applyColorAppearance];
    }
}

- (void)applyAppearanceToCell:(UITableViewCell *)cell {
    UITraitCollection *traits = self.traitCollection;
    CydiaGuideTableCell *guideCell = (CydiaGuideTableCell *)cell;
    HomeApplyCellSurface(cell, CydiaColorRoleCellBackground, traits);
    /* Attributed labels own their primary/secondary span colors. Reapplying
     * UILabel.textColor would flatten resource URL subtitles; trait changes
     * reload the cells above and rebuild those spans with the current roles. */
    if (guideCell.guideLabel.attributedText == nil)
        guideCell.guideLabel.textColor = [UIColor cydiaColorForRole:
            (guideCell.secondaryText ? CydiaColorRoleSecondaryLabel : CydiaColorRoleLabel)
            traitCollection:traits];
    /* Attributed body colors include authored small-print spans. Setting
     * UITextView.textColor here would flatten those semantic attributes. */
    guideCell.guideTextView.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent
        traitCollection:traits];
    guideCell.guideTextView.linkTextAttributes = @{
        NSForegroundColorAttributeName: guideCell.guideTextView.tintColor,
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    };
    cell.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:traits];
}

- (void)applyColorAppearance {
    UITraitCollection *traits = self.traitCollection;
    _tableView.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:traits];
    _tableView.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:traits];
    for (UITableViewCell *cell in _tableView.visibleCells)
        [self applyAppearanceToCell:cell];
    NSArray<UINavigationBar *> *bars;
    if (self.guideSplitViewController == nil) {
        UINavigationBar *bar = self.navigationController.navigationBar;
        bars = bar == nil ? @[] : @[bar];
    } else {
        UINavigationController *primaryNavigation =
            (UINavigationController *)self.guideSplitViewController.viewControllers.firstObject;
        UINavigationController *secondaryNavigation =
            (UINavigationController *)self.guideSplitViewController.viewControllers.lastObject;
        bars = @[primaryNavigation.navigationBar, secondaryNavigation.navigationBar];
    }
    for (UINavigationBar *bar in bars) {
        bar.barStyle = traits.userInterfaceStyle == UIUserInterfaceStyleDark ? UIBarStyleBlack : UIBarStyleDefault;
        bar.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:traits];
        bar.barTintColor = _tableView.backgroundColor;
        bar.titleTextAttributes = @{NSForegroundColorAttributeName:
            [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits]};
    }
}
@end
