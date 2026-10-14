/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/MoreSourcesController.h"
#import "Cydia/TableViewCompatibility.h"
#import "Cydia/MoreSourcesModel.h"
#import "Cydia/UIColor+Cydia.h"
#import "Cydia/HomeTableAppearance.h"
#import "Cydia/NativeAccessibilityTrace.h"
#import "Cydia/UIRouteContext.h"
#import "CyteKit/Localize.h"

@protocol CydiaMoreSourcesRouteDelegate <NSObject>
- (CyteViewController *)pageForURL:(NSURL *)URL
    context:(NSObject<CyteWebNavigationContext> *)context withReferrer:(NSString *)referrer;
@end

static NSString *MoreSourcesSetting(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"];
}

@interface CydiaMoreSourcesCell : UITableViewCell
@property(nonatomic, strong) UILabel *body;
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) NSLayoutConstraint *iconWidth, *iconGap;
@end
@implementation CydiaMoreSourcesCell
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil])) {
        _body = [[UILabel alloc] init]; _body.numberOfLines = 0;
        _body.adjustsFontForContentSizeCategory = YES; _body.isAccessibilityElement = NO;
        _icon = [[UIImageView alloc] init]; _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.isAccessibilityElement = NO;
        for (UIView *view in @[_body, _icon]) {
            view.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:view];
        }
        _iconWidth = [_icon.widthAnchor constraintEqualToConstant:0];
        _iconGap = [_body.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor];
        [NSLayoutConstraint activateConstraints:@[
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            [_icon.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            _iconWidth, [_icon.heightAnchor constraintEqualToConstant:32],
            [_icon.centerYAnchor constraintEqualToAnchor:_body.centerYAnchor], _iconGap,
            [_body.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_body.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_body.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10]
        ]];
        self.isAccessibilityElement = YES;
    }
    return self;
}
@end

@interface MoreSourcesController () <UITableViewDelegate, UITableViewDataSource>
@property(nonatomic, strong) id<CydiaMoreSourcesProviding> provider;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, copy) NSArray<NSDictionary *> *missing;
@property(nonatomic) BOOL restoring, visible;
@end

@implementation MoreSourcesController
- (instancetype)initWithProvider:(id<CydiaMoreSourcesProviding>)provider {
    if (!provider) return nil;
    if ((self = [super init])) {
        _provider = provider;
        self.title = UCLocalizeEx(@"MORE_SOURCES", @"More Sources");
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cancelRestoration)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    return self;
}
- (NSURL *)navigationURL { return [NSURL URLWithString:@"cydia://home/more-sources"]; }
- (void)loadView {
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _table.dataSource = self; _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension; _table.estimatedRowHeight = 64;
    _table.sectionHeaderHeight = 0.01; _table.sectionFooterHeight = 0.01;
    _table.estimatedSectionHeaderHeight = 28; _table.estimatedSectionFooterHeight = 44;
    _table.accessibilityIdentifier = @"cydia.home.more-sources.rows";
    if (@available(iOS 15.0, *))
        _table.sectionHeaderTopPadding = 0.0;
    UIView *root = [[UIView alloc] initWithFrame:CGRectZero];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_table];
    NSLayoutConstraint *preferredWidth = [_table.widthAnchor constraintEqualToAnchor:root.widthAnchor];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        preferredWidth, [_table.widthAnchor constraintLessThanOrEqualToConstant:560.0],
        [_table.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_table.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    self.view = root; [self applyAppearance];
}
- (void)reloadData {
    [super reloadData];
    [_table reloadData];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; _visible = YES;
    [self reloadData]; [self applyAppearance];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated]; CydiaCaptureNativeAccessibility(self, @"more-sources");
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated]; _visible = NO; [_provider cancelRestoration];
}
- (void)cancelRestoration { [_provider cancelRestoration]; }
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_provider cancelRestoration];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) {
        [self applyAppearance]; [_table reloadData];
    }
}
- (void)applyAppearance {
    _table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    self.view.backgroundColor = _table.backgroundColor;
    _table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
    self.view.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
    UINavigationBar *bar = self.navigationController.navigationBar;
    bar.barStyle = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? UIBarStyleBlack : UIBarStyleDefault;
    bar.tintColor = self.view.tintColor; bar.barTintColor = _table.backgroundColor;
    bar.titleTextAttributes = @{NSForegroundColorAttributeName:
        [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection]};
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 0.01;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return section < 2 ? 12.0 : 0.01;
}
- (void)styleSectionView:(UIView *)view {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    UILabel *label = [(UITableViewHeaderFooterView *)view textLabel];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote compatibleWithTraitCollection:self.traitCollection];
    label.adjustsFontForContentSizeCategory = YES; label.numberOfLines = 0;
    label.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    [self styleSectionView:view];
}
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    [self styleSectionView:view];
}
- (NSString *)textForRow:(NSIndexPath *)path {
    if (path.section == 0) return path.row == 0 ? UCLocalize("SOURCES") : MoreSourcesSetting(@"ADVANCED_SETTINGS");
    if (path.section == 2) return MoreSourcesSetting(@"BOOTSTRAP_REPOSITORIES_HELP");
    NSArray *paragraphs = @[
        UCLocalizeEx(@"MORE_SOURCES_HEADING", @"What are package sources?"),
        UCLocalizeEx(@"MORE_SOURCES_INTRO", @"Cydia is an open, decentralized platform that helps you install software packages hosted by independent repositories, also called sources."),
        UCLocalizeEx(@"MORE_SOURCES_OWNERS", @"Each source chooses the packages it hosts, how its pages look, and how it is run. They may choose to have ads."),
        UCLocalizeEx(@"MORE_SOURCES_HOSTING", @"Anyone can run their own source (a source is basically a specialized website viewable in Cydia)."),
        MoreSourcesSetting(@"REPOSITORY_SECURITY_EXPLANATION")
    ];
    return [paragraphs componentsJoinedByString:@"\n\n"];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    CydiaMoreSourcesCell *cell = [[CydiaMoreSourcesCell alloc] init];
    BOOL action = path.section == 0, enabled = action;
    cell.body.text = [self textForRow:path];
    cell.body.font = [UIFont preferredFontForTextStyle:action ?
        UIFontTextStyleBody : UIFontTextStyleSubheadline compatibleWithTraitCollection:self.traitCollection];
    if (path.section == 1) {
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
            initWithString:cell.body.text attributes:@{NSFontAttributeName:cell.body.font}];
        NSRange heading = [cell.body.text rangeOfString:@"\n\n"];
        UIFontDescriptor *bold = [cell.body.font.fontDescriptor
            fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
        if (heading.location != NSNotFound && bold != nil)
            [text addAttribute:NSFontAttributeName value:[UIFont fontWithDescriptor:bold
                size:cell.body.font.pointSize] range:NSMakeRange(0, heading.location)];
        cell.body.attributedText = text;
    }
    HomeApplyCellSurface(cell, CydiaColorRoleCellBackground, self.traitCollection);
    cell.body.textColor = [UIColor cydiaColorForRole:action && !enabled ? CydiaColorRoleSecondaryLabel :
        CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.tintColor = self.view.tintColor;
    cell.accessibilityLabel = cell.body.text;
    cell.accessibilityIdentifier = action ? [@"cydia.home.more-sources." stringByAppendingString:path.row == 0 ? @"sources" : @"advanced"] :
        [NSString stringWithFormat:@"cydia.home.more-sources.text.%ld.%ld", (long)path.section, (long)path.row];
    cell.accessibilityTraits = action ? UIAccessibilityTraitButton | (enabled ? 0 : UIAccessibilityTraitNotEnabled) :
        UIAccessibilityTraitStaticText | (path.section == 1 && path.row == 0 ? UIAccessibilityTraitHeader : 0);
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    if (action) {
        cell.accessoryType = enabled ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section != 0) return;
    id<CydiaMoreSourcesRouteDelegate> delegate(self.delegate);
    NSURL *URL([NSURL URLWithString:path.row == 0 ? @"cydia://sources" : @"cydia://home/settings/advanced"]);
    if (![delegate respondsToSelector:@selector(pageForURL:context:withReferrer:)]) return;
    CyteViewController *page([delegate pageForURL:URL context:[CydiaUIRouteContext trustedNativeContext]
        withReferrer:self.navigationURL.absoluteString]);
    if (page != nil) { page.delegate = self.delegate; [self.navigationController pushViewController:page animated:YES]; }
}
@end
