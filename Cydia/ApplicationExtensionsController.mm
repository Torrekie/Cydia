/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/ApplicationExtensionsController.h"
#include "Cydia/UIRouteContext.h"
#include "Cydia/UIColor+Cydia.h"
#include "Cydia/NativeAccessibilityTrace.h"
#include "Cydia/URLProtocolPolicy.h"
#include "CyteKit/Localize.h"

@protocol CydiaExtensionsRouteDelegate <NSObject>
- (CyteViewController *)pageForURL:(NSURL *)URL
    context:(NSObject<CyteWebNavigationContext> *)context withReferrer:(NSString *)referrer;
@end

@interface CydiaExtensionsCell : UITableViewCell
@property(nonatomic, strong) UILabel *nameLabel, *authorLabel, *summaryLabel, *badgeLabel;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UIStackView *header;
@property(nonatomic, copy) NSString *representedIconKey;
@property(nonatomic, strong) NSLayoutConstraint *iconWidth, *iconGap, *badgeWidth;
@end
@implementation CydiaExtensionsCell
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil])) {
        _nameLabel = [[UILabel alloc] init]; _authorLabel = [[UILabel alloc] init];
        _summaryLabel = [[UILabel alloc] init]; _badgeLabel = [[UILabel alloc] init];
        for (UILabel *label in @[_nameLabel, _authorLabel, _summaryLabel, _badgeLabel]) {
            label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = YES;
            label.isAccessibilityElement = NO;
        }
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.isAccessibilityElement = NO;
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _header = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _badgeLabel]];
        _header.alignment = UIStackViewAlignmentTop; _header.spacing = 10;
        // Prices/counts keep their intrinsic width instead of stealing the
        // title's free space. Large accessibility text stacks them below.
        [_badgeLabel setContentHuggingPriority:UILayoutPriorityRequired
            forAxis:UILayoutConstraintAxisHorizontal];
        [_badgeLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh
            forAxis:UILayoutConstraintAxisHorizontal];
        _badgeWidth = [_badgeLabel.widthAnchor constraintLessThanOrEqualToConstant:145];
        _badgeWidth.active = YES;
        UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_header, _authorLabel, _summaryLabel]];
        text.axis = UILayoutConstraintAxisVertical; text.spacing = 4;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_iconView]; [self.contentView addSubview:text];
        _iconWidth = [_iconView.widthAnchor constraintEqualToConstant:32];
        _iconGap = [text.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12];
        [NSLayoutConstraint activateConstraints:@[
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
            [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            _iconWidth, [_iconView.heightAnchor constraintEqualToConstant:32],
            [_iconView.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:6],
            [_iconView.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-6],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            _iconGap, [text.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [text.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [text.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10]
        ]];
        self.isAccessibilityElement = YES;
    }
    return self;
}
@end

@interface ApplicationExtensionsController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, copy, readwrite) NSString *bundleIdentifier;
@property(nonatomic, strong) id<CydiaApplicationExtensionsProviding> provider;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, copy) NSArray<CydiaApplicationExtensionRow *> *rows;
@property(nonatomic, strong) NSError *loadError;
@property(nonatomic, strong) id<CydiaExtensionsRequest> request;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id<CydiaExtensionsRequest>> *imageRequests;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSHashTable<CydiaExtensionsCell *> *> *imageCells;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *images;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL loading, requested, visible;
@end

@implementation ApplicationExtensionsController
- (instancetype)init { return [self initWithBundleIdentifier:nil]; }
- (instancetype)initWithBundleIdentifier:(NSString *)identifier {
    return [self initWithBundleIdentifier:identifier provider:[[CydiaApplicationExtensionsProvider alloc] init]];
}
- (instancetype)initWithBundleIdentifier:(NSString *)identifier provider:(id<CydiaApplicationExtensionsProviding>)provider {
    if ((identifier != nil && !CydiaExtensionIdentifierIsValid(identifier)) || provider == nil) return nil;
    if ((self = [super init])) {
        _bundleIdentifier = [identifier copy]; _provider = provider;
        _imageRequests = [NSMutableDictionary dictionary];
        _imageCells = [NSMutableDictionary dictionary];
        _images = [[NSCache alloc] init]; _images.countLimit = 128; _images.totalCostLimit = 8 * 1024 * 1024;
        self.title = identifier == nil ? UCLocalizeEx(@"EXTENSIONS_APPLICATIONS", @"Applications") :
            ([provider localizedNameForBundleIdentifier:identifier] ?: identifier);
    }
    return self;
}
- (NSURL *)navigationURL {
    NSString *route = @"cydia://home/application-extensions";
    if (_bundleIdentifier) route = [route stringByAppendingFormat:@"/%@", _bundleIdentifier];
    return [NSURL URLWithString:route];
}
- (void)loadView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    _tableView.dataSource = self; _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension; _tableView.estimatedRowHeight = 80;
    _tableView.sectionHeaderHeight = 0.01; _tableView.sectionFooterHeight = 0.01;
    if (@available(iOS 15.0, *))
        _tableView.sectionHeaderTopPadding = 0.0;
    _tableView.accessibilityIdentifier = @"cydia.home.extensions.rows";
    _tableView.refreshControl = [[UIRefreshControl alloc] init];
    [_tableView.refreshControl addTarget:self action:@selector(reloadCatalog) forControlEvents:UIControlEventValueChanged];
    self.view = _tableView;
    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    [refresh setTitle:UCLocalize("REFRESH") forState:UIControlStateNormal];
    refresh.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    refresh.titleLabel.adjustsFontForContentSizeCategory = YES;
    [refresh addTarget:self action:@selector(reloadCatalog) forControlEvents:UIControlEventTouchUpInside];
    refresh.accessibilityIdentifier = @"cydia.home.extensions.refresh";
    [NSLayoutConstraint activateConstraints:@[
        [refresh.widthAnchor constraintGreaterThanOrEqualToConstant:44.0],
        [refresh.heightAnchor constraintGreaterThanOrEqualToConstant:44.0]
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:refresh];
    [self applyAppearance];
}
- (void)stopRequests {
    ++_generation;
    [_request cancel]; _request = nil;
    for (id<CydiaExtensionsRequest> request in _imageRequests.allValues) [request cancel];
    [_imageRequests removeAllObjects];
    [_imageCells removeAllObjects];
    if (_loading) { _loading = NO; _requested = NO; }
    [_tableView.refreshControl endRefreshing];
}
- (void)dealloc {
    [_request cancel];
    for (id<CydiaExtensionsRequest> request in _imageRequests.allValues) [request cancel];
}
- (void)reloadCatalog {
    [self stopRequests];
    _requested = YES; _loading = YES; _loadError = nil; _rows = nil;
    [_tableView reloadData];
    NSUInteger generation = _generation;
    __weak ApplicationExtensionsController *weakSelf = self;
    _request = [_provider loadRowsForBundleIdentifier:_bundleIdentifier
        completion:^(NSArray<CydiaApplicationExtensionRow *> *rows, NSError *error) {
            ApplicationExtensionsController *self = weakSelf;
            if (self == nil || !self.visible || self.generation != generation) return;
            self.loading = NO; self.request = nil;
            self.rows = rows; self.loadError = error;
            [self.tableView.refreshControl endRefreshing];
            [self.tableView reloadData];
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
            CydiaCaptureNativeAccessibility(self, @"application-extensions");
        }];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; _visible = YES;
    [self applyAppearance];
    if (!_requested) {
        if (_bundleIdentifier == nil)
            [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"v0:badge-application"];
        [self reloadCatalog];
    } else {
        // Back must resume cancelled visible artwork without reloading rows
        // (and losing the caller's scroll position).
        for (NSIndexPath *path in _tableView.indexPathsForVisibleRows)
            [self loadCatalogIconForCell:(CydiaExtensionsCell *)[_tableView cellForRowAtIndexPath:path] atIndexPath:path];
    }
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    CydiaCaptureNativeAccessibility(self, @"application-extensions");
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated]; _visible = NO; [self stopRequests];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory]) {
        [_tableView reloadData]; [self applyAppearance];
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _bundleIdentifier ? 1 : 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (_bundleIdentifier == nil && section == 0) ? 1 : MAX((NSUInteger)1, _rows.count);
}
- (NSString *)stateText {
    if (_loading) return UCLocalize("LOADING");
    if (_loadError != nil) return UCLocalizeEx(@"EXTENSIONS_LOAD_ERROR",
        @"Unable to load extensions. Check your connection and application access, then tap to retry.");
    return UCLocalizeEx(@"EXTENSIONS_EMPTY", @"No extensions are listed for these applications.");
}
- (void)applyCellAppearance:(CydiaExtensionsCell *)cell {
    UITraitCollection *traits = self.traitCollection;
    UIColor *background = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:traits];
    cell.backgroundColor = background; cell.contentView.backgroundColor = UIColor.clearColor;
    cell.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:traits];
    cell.nameLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits];
    for (UILabel *label in @[cell.authorLabel, cell.summaryLabel])
        label.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:traits];
    cell.badgeLabel.textColor = cell.tintColor;
    if (@available(iOS 14.0, *)) {
        UIBackgroundConfiguration *configuration = [UIBackgroundConfiguration listGroupedCellConfiguration];
        configuration.backgroundColor = background; cell.backgroundConfiguration = configuration;
    }
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    CydiaExtensionsCell *cell = [[CydiaExtensionsCell alloc] init];
    UITraitCollection *traits = self.traitCollection;
    BOOL accessibilitySize = UIContentSizeCategoryIsAccessibilityCategory(traits.preferredContentSizeCategory);
    cell.header.axis = accessibilitySize ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    cell.header.alignment = accessibilitySize ? UIStackViewAlignmentLeading : UIStackViewAlignmentTop;
    cell.header.spacing = accessibilitySize ? 4 : 10;
    cell.badgeWidth.active = !accessibilitySize;
    cell.nameLabel.font = [UIFont preferredFontForTextStyle:_bundleIdentifier ?
        UIFontTextStyleHeadline : UIFontTextStyleBody compatibleWithTraitCollection:traits];
    cell.authorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline compatibleWithTraitCollection:traits];
    cell.summaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:traits];
    cell.badgeLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline compatibleWithTraitCollection:traits];
    BOOL intro = _bundleIdentifier == nil && path.section == 0;
    BOOL status = !intro && _rows.count == 0;
    if (intro || status) {
        cell.iconWidth.constant = 0; cell.iconGap.constant = 0;
        cell.nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline
            compatibleWithTraitCollection:traits];
        cell.nameLabel.text = intro ? UCLocalizeEx(@"EXTENSIONS_INTRO",
            @"Here are lists of extensions (from the default sources) that can add features to your installed apps. "
             "Cydia automatically builds these lists by looking for packages that seem to use Substrate to modify these apps. "
             "Note that it may list results that a human wouldn't list, and it may list results that aren't compatible with your iOS version. "
             "We found these lists fun to look at, and maybe you'll like them too. "
             "(The lists are presented in a random order, to give a fair chance to every extension. ;P)") : [self stateText];
        cell.authorLabel.hidden = YES; cell.summaryLabel.hidden = YES; cell.badgeLabel.hidden = YES;
        cell.accessibilityIdentifier = intro ? @"cydia.home.extensions.intro" : @"cydia.home.extensions.state";
        cell.accessibilityTraits = !intro && _loadError ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
        cell.selectionStyle = !intro && _loadError ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.accessibilityLabel = cell.nameLabel.text;
    } else {
        CydiaApplicationExtensionRow *row = _rows[path.row];
        cell.nameLabel.text = row.name;
        cell.authorLabel.text = row.author; cell.authorLabel.hidden = !row.author.length;
        cell.summaryLabel.text = row.summary; cell.summaryLabel.hidden = !row.summary.length;
        cell.badgeLabel.text = _bundleIdentifier ? row.price : [NSString stringWithFormat:
            UCLocalizeEx(@"EXTENSIONS_COUNT", @"Extensions: %lu"), (unsigned long)row.extensionCount];
        cell.badgeLabel.hidden = !cell.badgeLabel.text.length;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.home.extensions.%@.%@",
            _bundleIdentifier ? @"package" : @"app", row.identifier];
        NSMutableArray *labels = [NSMutableArray arrayWithObject:row.name];
        if (row.author.length) [labels addObject:row.author];
        if (row.summary.length) [labels addObject:row.summary];
        cell.accessibilityLabel = [labels componentsJoinedByString:@", "];
        cell.accessibilityValue = cell.badgeLabel.text;
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        cell.iconView.image = (row.localIconPath ? [UIImage imageWithContentsOfFile:row.localIconPath] : nil) ?:
            [UIImage imageNamed:@"unknown.png"];
        if (_bundleIdentifier == nil) {
            // Same optional SpringBoard PNG source as application-icon/ URLs;
            // retain the local file and unknown.png fallbacks when unavailable.
            NSData *localIcon = [_provider localIconDataForBundleIdentifier:row.identifier];
            if (CydiaURLResourcePNGDataIsAllowed(localIcon))
                cell.iconView.image = [UIImage imageWithData:localIcon] ?: cell.iconView.image;
        }
        NSString *key = row.iconURL.absoluteString;
        cell.representedIconKey = key;
        UIImage *cached = key == nil ? nil : [_images objectForKey:key];
        if (cached) cell.iconView.image = cached;
        cell.iconView.accessibilityIdentifier = [NSString stringWithFormat:@"cydia.home.extensions.icon.%@.%@",
            row.identifier, cached ? @"loaded" : @"placeholder"];
    }
    [self applyCellAppearance:cell];
    return cell;
}
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)path {
    [self loadCatalogIconForCell:(CydiaExtensionsCell *)cell atIndexPath:path];
}
- (void)loadCatalogIconForCell:(CydiaExtensionsCell *)cell atIndexPath:(NSIndexPath *)path {
    if (!_visible || _bundleIdentifier == nil || path.row >= _rows.count || cell == nil) return;
    CydiaApplicationExtensionRow *row = _rows[path.row];
    NSString *key = row.iconURL.absoluteString;
    if (key == nil) return;
    NSString *identifier = [NSString stringWithFormat:@"cydia.home.extensions.icon.%@.loaded", row.identifier];
    UIImage *cached = [_images objectForKey:key];
    if (cached) {
        cell.iconView.image = cached; cell.iconView.accessibilityIdentifier = identifier; return;
    }
    NSHashTable *waiting = _imageCells[key];
    if (waiting == nil) _imageCells[key] = waiting = [NSHashTable weakObjectsHashTable];
    [waiting addObject:cell];
    if (_imageRequests[key] != nil) return;
    // UIKit/AX may ask for offscreen cells to measure/enumerate the whole
    // catalog. Start work only when a row is actually displayed, not during
    // cellForRow. Otherwise offscreen requests churn the bounded icon cache.
    NSUInteger generation = _generation;
    __weak ApplicationExtensionsController *weakSelf = self;
    _imageRequests[key] = [_provider loadIconURL:row.iconURL completion:^(NSData *data) {
        ApplicationExtensionsController *self = weakSelf;
        if (!self || self.generation != generation || !self.visible) return;
        [self.imageRequests removeObjectForKey:key];
        NSArray<CydiaExtensionsCell *> *cells = self.imageCells[key].allObjects;
        [self.imageCells removeObjectForKey:key];
        UIImage *image = CydiaURLResourcePNGDataIsAllowed(data) ? [UIImage imageWithData:data] : nil;
        if (!image) return;
        [self.images setObject:image forKey:key cost:(NSUInteger)(image.size.width * image.size.height * 4)];
        // willDisplay can precede visibleCells membership. Bind weak prepared
        // cells too, including duplicate icon URLs; never keep a cell alive or
        // apply an old result to a different represented row.
        for (CydiaExtensionsCell *waitingCell in cells) {
            if ([waitingCell.representedIconKey isEqual:key]) {
                waitingCell.iconView.image = image;
                waitingCell.iconView.accessibilityIdentifier = identifier;
            }
        }
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (_bundleIdentifier == nil && path.section == 0) return;
    if (_rows.count == 0) { if (_loadError) [self reloadCatalog]; return; }
    if (path.row >= _rows.count) return;
    CydiaApplicationExtensionRow *row = _rows[path.row];
    if (_bundleIdentifier == nil) {
        ApplicationExtensionsController *child = [[ApplicationExtensionsController alloc]
            initWithBundleIdentifier:row.identifier provider:_provider];
        [child setDelegate:self.delegate];
        [self.navigationController pushViewController:child animated:YES];
        return;
    }
    NSURL *URL = [NSURL URLWithString:[@"cydia://package/" stringByAppendingString:row.identifier]];
    id<CydiaExtensionsRouteDelegate> delegate = self.delegate;
    CyteViewController *destination = nil;
    if ([delegate respondsToSelector:@selector(pageForURL:context:withReferrer:)])
        destination = [delegate pageForURL:URL context:[CydiaUIRouteContext trustedNativeContext]
            withReferrer:self.navigationURL.absoluteString];
    if (destination) {
        [destination setDelegate:delegate];
        [self.navigationController pushViewController:destination animated:YES];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:row.name
            message:UCLocalizeEx(@"EXTENSIONS_PACKAGE_UNAVAILABLE",
                @"This package is not available in your configured sources. No source or package has been changed.")
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
- (void)applyAppearance {
    _tableView.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection];
    _tableView.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator traitCollection:self.traitCollection];
    for (CydiaExtensionsCell *cell in _tableView.visibleCells) [self applyCellAppearance:cell];
    UINavigationBar *bar = self.navigationController.navigationBar;
    bar.barStyle = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? UIBarStyleBlack : UIBarStyleDefault;
    bar.tintColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
    bar.barTintColor = _tableView.backgroundColor;
    bar.titleTextAttributes = @{NSForegroundColorAttributeName:
        [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:self.traitCollection]};
}
@end
