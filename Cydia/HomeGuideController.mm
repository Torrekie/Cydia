/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/HomeGuideController.h"
#import "Cydia/TableViewCompatibility.h"
#import "Cydia/UIRouteContext.h"
#import "Cydia/ExternalURLPolicy.h"
#import "Cydia/UIColor+Cydia.h"
#import "Cydia/NativeAccessibilityTrace.h"
#import "CyteKit/Localize.h"

@protocol CydiaHomeGuideRouteDelegate <NSObject>
- (CyteViewController *)pageForURL:(NSURL *)URL
    context:(NSObject<CyteWebNavigationContext> *)context withReferrer:(NSString *)referrer;
- (BOOL)openCydiaURL:(NSURL *)URL context:(CydiaUIRouteContext *)context;
@end

@interface CydiaHomeGuideCell : UITableViewCell
@property(nonatomic, strong) UITextView *body;
@property(nonatomic, strong) UIImageView *artwork;
@property(nonatomic, strong) NSLayoutConstraint *topPadding;
@property(nonatomic, strong) NSLayoutConstraint *bottomPadding;
@property(nonatomic) BOOL terminal;
@property(nonatomic) BOOL warning;
@end
@implementation CydiaHomeGuideCell
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil])) {
        _body = [[UITextView alloc] init];
        _body.editable = NO;
        _body.selectable = YES;
        _body.scrollEnabled = NO;
        _body.backgroundColor = UIColor.clearColor;
        _body.textContainerInset = UIEdgeInsetsZero;
        _body.textContainer.lineFragmentPadding = 0.0;
        _body.adjustsFontForContentSizeCategory = YES;
        _body.isAccessibilityElement = NO;
        _artwork = [[UIImageView alloc] init];
        _artwork.contentMode = UIViewContentModeScaleAspectFit;
        _artwork.isAccessibilityElement = NO;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_artwork, _body]];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 12;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        NSLayoutConstraint *width = [_artwork.widthAnchor constraintEqualToConstant:29];
        width.priority = UILayoutPriorityDefaultHigh; // Hidden artwork collapses.
        _topPadding = [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10];
        _bottomPadding = [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10];
        [NSLayoutConstraint activateConstraints:@[
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
            [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            _topPadding, _bottomPadding,
            width, [_artwork.heightAnchor constraintEqualToConstant:29]
        ]];
        self.isAccessibilityElement = YES;
    }
    return self;
}
@end

@interface HomeGuideController () <UITableViewDataSource, UITableViewDelegate, UITextViewDelegate>
@property(nonatomic, copy) NSString *pageIdentifier;
@property(nonatomic, copy) NSArray<NSDictionary *> *sections;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, copy) NSString *pendingRowIdentifier;
- (void)scrollToPendingRow;
- (void)applySeparatorToCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)path;
@end

@implementation HomeGuideController
- (instancetype)initWithPageIdentifier:(NSString *)identifier {
    if (![@[@"openssh", @"root-password", @"developer-resources", @"credits", @"privacy", @"console"] containsObject:identifier])
        return nil;
    if ([identifier isEqualToString:@"console"]) {
        // The purpose::console destination is an informational Cydia page,
        // not a repository depiction. Keep its original notice native.
        return [self initWithPageIdentifier:identifier page:@{
            @"title_key": @"CONSOLE", @"title": @"Console",
            @"sections": @[@{@"rows": @[@{@"id": @"console-notice", @"kind": @"text",
                @"text": @"This package does not have an icon, nor should it. To use this package you must SSH into your device or use MobileTerminal. If you do not recognize this package you probably should not be using it."}]}]
        }];
    }
    NSURL *URL = [[NSBundle mainBundle] URLForResource:@"HomeGuides" withExtension:@"json"];
    NSData *data = URL ? [NSData dataWithContentsOfURL:URL] : nil;
    NSDictionary *document = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![document isKindOfClass:NSDictionary.class] || ![document[@"schema"] isEqual:@1] ||
        ![document[@"pages"] isKindOfClass:NSDictionary.class]) return nil;
    return [self initWithPageIdentifier:identifier page:document[@"pages"][identifier]];
}
- (instancetype)initWithPageIdentifier:(NSString *)identifier page:(NSDictionary *)page {
    if ([identifier length] == 0 || ![page isKindOfClass:NSDictionary.class] ||
        ![page[@"sections"] isKindOfClass:NSArray.class] || ![page[@"sections"] count])
        return nil;
    if ((self = [super init])) {
        _pageIdentifier = [identifier copy];
        _sections = [page[@"sections"] copy];
        self.title = UCLocalizeEx(page[@"title_key"] ?: identifier, page[@"title"]);
    }
    return self;
}
- (NSURL *)navigationURL {
    return [NSURL URLWithString:[@"cydia://home/" stringByAppendingString:_pageIdentifier]];
}
- (void)loadView {
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _table.dataSource = self; _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension; _table.estimatedRowHeight = 72;
    _table.sectionHeaderHeight = 0.01; _table.sectionFooterHeight = 0.01;
    _table.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.home.%@.rows", _pageIdentifier];
    if (@available(iOS 15.0, *))
        _table.sectionHeaderTopPadding = 0.0;
    /* Keep article lines readable on a wide iPad without changing the
     * existing push/split navigation model. Compact screens stay full width. */
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
    self.view = root;
    [self applyAppearance];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [_sections[section][@"title"] length] != 0 ? UITableViewAutomaticDimension : 0.01;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSDictionary *group = _sections[section];
    return group[@"title"] ? UCLocalizeEx(group[@"title_id"] ?: group[@"title"], group[@"title"]) : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 12.0;
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
            traitCollection:self.traitCollection];
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_sections[section][@"rows"] count];
}
- (NSDictionary *)rowAtIndexPath:(NSIndexPath *)path {
    if (path.section < 0 || path.section >= _sections.count || path.row < 0) return nil;
    NSArray *rows = _sections[path.section][@"rows"];
    return path.row < rows.count ? rows[path.row] : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *row = [self rowAtIndexPath:path];
    BOOL action = [row[@"kind"] isEqual:@"link"], heading = [row[@"kind"] isEqual:@"heading"];
    CydiaHomeGuideCell *cell = [[CydiaHomeGuideCell alloc] init];
    cell.terminal = [row[@"kind"] isEqual:@"terminal"];
    cell.warning = [row[@"warning"] boolValue] || [_sections[path.section][@"warning"] boolValue];
    if (action) { cell.topPadding.constant = 6.0; cell.bottomPadding.constant = -6.0; }
    UIFont *font = [UIFont preferredFontForTextStyle:heading ? UIFontTextStyleHeadline :
        (action ? UIFontTextStyleBody : UIFontTextStyleSubheadline)
        compatibleWithTraitCollection:self.traitCollection];
    if (cell.terminal) {
        // Menlo + UIFontMetrics work on iOS12; monospacedSystemFont is iOS13+.
        UIFont *fixed = [UIFont fontWithName:@"Menlo" size:16] ?: [UIFont systemFontOfSize:16];
        font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:fixed
            compatibleWithTraitCollection:self.traitCollection];
    }
    cell.body.font = font;
    cell.body.textContainer.lineBreakMode = cell.terminal ? NSLineBreakByCharWrapping : NSLineBreakByWordWrapping;
    cell.body.delegate = self;
    NSString *localized = UCLocalizeEx([@"HOME_GUIDE_" stringByAppendingString:row[@"id"]], row[@"text"]);
    cell.body.text = localized;
    NSMutableString *spoken = [NSMutableString string];
    BOOL inlineLinks = NO;
    if ([localized isEqual:row[@"text"]] && [row[@"runs"] count]) {
        NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
        for (NSDictionary *run in row[@"runs"]) {
            UIFontDescriptorSymbolicTraits flags = font.fontDescriptor.symbolicTraits;
            if ([run[@"bold"] boolValue]) flags |= UIFontDescriptorTraitBold;
            if ([run[@"italic"] boolValue]) flags |= UIFontDescriptorTraitItalic;
            UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:flags];
            CGFloat scale = [run[@"scale"] doubleValue];
            if (scale <= 0.0) scale = 1.0;
            NSMutableDictionary *attributes = [@{NSFontAttributeName: descriptor ?
                [UIFont fontWithDescriptor:descriptor size:font.pointSize * scale] : font} mutableCopy];
            NSURL *destination = [run[@"link"] isKindOfClass:NSString.class] ?
                [NSURL URLWithString:run[@"link"]] : nil;
            if (destination) {
                attributes[NSLinkAttributeName] = destination;
                inlineLinks = YES;
            }
            if ([run[@"image"] isKindOfClass:NSString.class]) {
                NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
                attachment.image = [UIImage imageNamed:run[@"image"]];
                attachment.bounds = CGRectMake(0.0, -4.0, 20.0, 20.0);
                if (attachment.image) attributes[NSAttachmentAttributeName] = attachment;
            }
            if ([run[@"obsolete"] boolValue]) {
                attributes[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
                [spoken appendFormat:@"%@ %@. ", UCLocalizeEx(@"HOME_GUIDE_OBSOLETE", @"Obsolete:"), run[@"text"]];
            } else if (!run[@"image"]) [spoken appendString:run[@"text"]];
            [body appendAttributedString:[[NSAttributedString alloc] initWithString:run[@"text"] attributes:attributes]];
        }
        cell.body.attributedText = body;
    } else [spoken appendString:localized];
    if (row[@"image_description"])
        [spoken appendFormat:@" %@", UCLocalizeEx(@"HOME_GUIDE_NETWORK_DETAILS", row[@"image_description"])];
    cell.artwork.image = row[@"icon"] ? [UIImage imageNamed:row[@"icon"]] : nil;
    cell.artwork.hidden = cell.artwork.image == nil;
    cell.accessibilityIdentifier = [@"cydia.home.guide." stringByAppendingString:row[@"id"]];
    cell.accessibilityLabel = spoken;
    cell.isAccessibilityElement = !inlineLinks;
    cell.body.isAccessibilityElement = inlineLinks;
    cell.body.accessibilityIdentifier = [cell.accessibilityIdentifier stringByAppendingString:@".richText"];
    cell.body.accessibilityLabel = spoken;
    cell.body.userInteractionEnabled = inlineLinks;
    cell.accessibilityTraits = action ? UIAccessibilityTraitButton :
        UIAccessibilityTraitStaticText | (heading ? UIAccessibilityTraitHeader : 0);
    cell.selectionStyle = action ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessoryType = action ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    [self applyAppearanceToCell:cell];
    return cell;
}
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)path {
    [self applyAppearanceToCell:(CydiaHomeGuideCell *)cell];
    [self applySeparatorToCell:cell atIndexPath:path];
}
- (void)applySeparatorToCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)path {
    NSDictionary *row = [self rowAtIndexPath:path];
    NSIndexPath *nextPath = [NSIndexPath indexPathForRow:path.row + 1 inSection:path.section];
    NSDictionary *next = [self rowAtIndexPath:nextPath];
    BOOL uninterruptedProse = next && ![row[@"kind"] isEqual:@"link"] && ![next[@"kind"] isEqual:@"link"];
    cell.separatorInset = uninterruptedProse ? UIEdgeInsetsMake(0.0, _table.bounds.size.width, 0.0, 0.0) :
        _table.separatorInset;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (UITableViewCell *cell in _table.visibleCells) {
        NSIndexPath *path = [_table indexPathForCell:cell];
        if (path) [self applySeparatorToCell:cell atIndexPath:path];
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSDictionary *row = [self rowAtIndexPath:path];
    if (![row[@"kind"] isEqual:@"link"]) return;
    [self openGuideDestinationURL:[NSURL URLWithString:row[@"destination"]]];
}
- (BOOL)textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)URL inRange:(NSRange)range {
    [self openGuideDestinationURL:URL];
    return NO;
}
- (void)openGuideDestinationURL:(NSURL *)URL {
    if (!URL) return;
    CydiaUIRouteDescriptor *descriptor = CydiaUIParseRouteURL(URL, NULL);
    BOOL nativeGuide = descriptor && (descriptor.kind == CydiaUIRouteKindPackage ||
        descriptor.kind == CydiaUIRouteKindHomeGuide || descriptor.kind == CydiaUIRouteKindFAQ ||
        descriptor.kind == CydiaUIRouteKindCopyingFiles || descriptor.kind == CydiaUIRouteKindUpgradingGuide);
    NSURL *route = nativeGuide ? URL : CydiaExternalURLRouteURL(URL);
    if (!route) return;
    id<CydiaHomeGuideRouteDelegate> delegate = [self delegate];
    CydiaUIRouteContext *context = [CydiaUIRouteContext trustedNativeContext];
    if ([delegate respondsToSelector:@selector(pageForURL:context:withReferrer:)]) {
        CyteViewController *page = [delegate pageForURL:route context:context withReferrer:self.navigationURL.absoluteString];
        if (page && self.navigationController) {
            [page setDelegate:delegate];
            [self.navigationController pushViewController:page animated:YES];
            return;
        }
    }
    if ([delegate respondsToSelector:@selector(openCydiaURL:context:)])
        [delegate openCydiaURL:route context:context];
}
- (void)scrollToRowIdentifier:(NSString *)identifier {
    _pendingRowIdentifier = [identifier copy];
    if (self.isViewLoaded && self.view.window) [self scrollToPendingRow];
}
- (void)scrollToPendingRow {
    if ([_pendingRowIdentifier length] == 0) return;
    for (NSUInteger section = 0; section < _sections.count; ++section) {
        NSArray *rows = _sections[section][@"rows"];
        for (NSUInteger row = 0; row < rows.count; ++row) {
            if (![rows[row][@"id"] isEqual:_pendingRowIdentifier]) continue;
            [_table layoutIfNeeded];
            [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]
                atScrollPosition:UITableViewScrollPositionTop animated:NO];
            _pendingRowIdentifier = nil;
            return;
        }
    }
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self applyAppearance]; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated]; [self scrollToPendingRow];
    CydiaCaptureNativeAccessibility(self, @"home-guide");
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) {
        [_table reloadData]; [self applyAppearance];
    }
}
- (void)applyAppearanceToCell:(CydiaHomeGuideCell *)cell {
    UIColor *background = cell.terminal ? UIColor.blackColor :
        [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
    if (cell.warning && !cell.terminal) background = [[UIColor cydiaColorForRole:CydiaColorRoleErrorLabel
        traitCollection:self.traitCollection] colorWithAlphaComponent:0.12];
    cell.backgroundColor = background; cell.contentView.backgroundColor = UIColor.clearColor;
    cell.body.textColor = cell.terminal ? UIColor.whiteColor :
        [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection];
    cell.body.linkTextAttributes = @{NSForegroundColorAttributeName:
        [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)};
    cell.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
    if (!cell.selectedBackgroundView) cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = [[UIColor cydiaColorForRole:CydiaColorRoleAccent
        traitCollection:self.traitCollection] colorWithAlphaComponent:0.12];
}
- (void)applyAppearance {
    _table.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    self.view.backgroundColor = _table.backgroundColor;
    _table.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
    for (CydiaHomeGuideCell *cell in _table.visibleCells) [self applyAppearanceToCell:cell];
    self.view.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
    UINavigationBar *bar = self.navigationController.navigationBar;
    bar.barStyle = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? UIBarStyleBlack : UIBarStyleDefault;
    bar.tintColor = self.view.tintColor; bar.barTintColor = _table.backgroundColor;
    bar.titleTextAttributes = @{NSForegroundColorAttributeName:
        [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection]};
}
@end
