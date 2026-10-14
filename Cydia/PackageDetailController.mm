/* Cydia Refurbished native package-detail shell.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "Cydia/PackageDetailController.h"
#import "Cydia/PackageDetailController+Accounts.h"
#import "Cydia/RepositoryAccountsController.h"
#import "Cydia/RepositoryPackagePresentation.h"
#import "Cydia/RepositoryAccountService.h"
#import "Cydia/RepositoryIdentity.h"
#include "Cydia/PackageDetailDepictionCell.h"
#include "Cydia/PackageDetailMetadata.h"

#include "Cydia/Appearance.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/NativeAccessibilityTrace.h"
#include "Cydia/PackageDepictionPolicy.h"
#include "Cydia/PackageDepictionView.h"
#include "Cydia/PackageDescriptionFormatting.h"
#include "CyteKit/Localize.h"

#include <algorithm>
#include <cmath>
namespace {
typedef NS_ENUM(NSUInteger, CydiaPackageDetailSectionKind) {
    CydiaPackageDetailSectionKindQueue,
    CydiaPackageDetailSectionKindActions,
    CydiaPackageDetailSectionKindAccount,
    CydiaPackageDetailSectionKindMetadata,
    CydiaPackageDetailSectionKindWarnings,
    CydiaPackageDetailSectionKindDepiction,
    CydiaPackageDetailSectionKindDescription,
    CydiaPackageDetailSectionKindHomepage,
    CydiaPackageDetailSectionKindInstalled,
    CydiaPackageDetailSectionKindSource,
};
NSString *PackageSizeDescription(uint64_t bytes) {
    if (bytes == 0)
        return nil;
    double kilobytes(static_cast<double>(bytes) / 1024.0);
    if (std::floor(kilobytes) == kilobytes)
        return [NSString stringWithFormat:@"%.0f kB", kilobytes];
    return [NSString stringWithFormat:@"%.1f kB", kilobytes];
}
NSString *ContactTitle(CydiaPackageDetailViewModel *viewModel) {
    switch ([viewModel contactKind]) {
        case CydiaPackageDetailContactKindAuthor:
        case CydiaPackageDetailContactKindMaintainer:
            return UCLocalize("AUTHOR");
        case CydiaPackageDetailContactKindPackageSupport:
            return UCLocalizeEx(@"PACKAGE_SUPPORT", @"Package Support");
    }
}
UIImage *PackageRowImage(UIImage *image) {
    if (image == nil)
        return nil;
    if (image.size.width <= 0.0 || image.size.height <= 0.0)
        return image;
    CGSize box(CGSizeMake(29.0, 29.0));
    /* Keep the small pre-iOS-7 glyphs at their authored scale. Upscaling
     * their premultiplied bitmap makes the gear/envelope look washed out;
     * newer 64px assets are still reduced to the same 29pt cell box. */
    CGFloat scale(std::min<CGFloat>(1.0,
        std::min(box.width / image.size.width, box.height / image.size.height)));
    CGSize size(CGSizeMake(std::max<CGFloat>(1.0, std::floor(image.size.width * scale)),
                           std::max<CGFloat>(1.0, std::floor(image.size.height * scale))));
    UIGraphicsBeginImageContextWithOptions(box, NO, 0.0);
    [image drawInRect:CGRectMake((box.width - size.width) / 2.0,
                                 (box.height - size.height) / 2.0,
                                 size.width, size.height)];
    UIImage *result(UIGraphicsGetImageFromCurrentImageContext());
    UIGraphicsEndImageContext();
    return result;
}
UIImage *LocalPackageImage(NSString *name) {
    return PackageRowImage([UIImage imageNamed:name]);
}
/* The retained package page uses a distinct 32-point glyph for each queued
 * operation.  Keep the input closed over the historical operation names so a
 * malformed or future mode can never turn into an arbitrary resource path. */
NSString *PackageModeAsset(NSString *mode) {
    if (![mode isKindOfClass:[NSString class]])
        return @"installing.png";
    NSString *normalized([mode uppercaseString]);
    if ([normalized isEqualToString:@"NEW_INSTALL"])
        normalized = @"INSTALL";
    static NSSet<NSString *> *knownModes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        knownModes = [NSSet setWithObjects:
            @"DOWNGRADE", @"INSTALL", @"PURGE", @"REINSTALL", @"REMOVE",
            @"UPGRADE", nil];
    });
    if (![knownModes containsObject:normalized])
        return @"installing.png";
    NSString *asset([NSString stringWithFormat:@"Modes/%@.png", normalized]);
    return [UIImage imageNamed:asset] == nil ? @"installing.png" : asset;
}
void SetLegacyPackageRowImage(UITableViewCell *cell, NSString *name) {
    UIImage *image(LocalPackageImage(name));
    cell.imageView.image = image;
    cell.imageView.accessibilityIdentifier = name;
}
UIImage *LocalPackageImageForURLString(NSString *URLString, NSString *fallback) {
    NSURL *URL([NSURL URLWithString:URLString]);
    if ([URL isFileURL]) {
        UIImage *image([UIImage imageWithContentsOfFile:[URL path]]);
        if (image != nil)
            return PackageRowImage(image);
    }
    return LocalPackageImage(fallback);
}
NSString *FooterDetail(CydiaPackageDetailViewModel *viewModel) {
    NSString *source([[viewModel source] name]);
    NSString *section([viewModel localizedSection]);
    if ([source length] != 0 && [section length] != 0)
        return [NSString stringWithFormat:@"%@ · %@", source, section];
    return [source length] != 0 ? source : section;
}

NSString *ContactURLString(CydiaPackageDetailViewModel *viewModel) {
    /* The legacy package page always opened its support popup.  The popup
     * then selected the author/maintainer mail address (or package support
     * URL), preserving the old page boundary instead of handing a raw
     * mailto to the external URL controller. */
    if ([[viewModel identity] length] == 0)
        return nil;
    if ([viewModel contactKind] == CydiaPackageDetailContactKindPackageSupport &&
        [[viewModel supportURLString] length] == 0)
        return nil;
    return [NSString stringWithFormat:@"cydia://package/%@/support", [viewModel identity]];
}

} // namespace
@interface CydiaMinimumTargetButton : UIButton
@end

@implementation CydiaMinimumTargetButton

- (CGSize)intrinsicContentSize {
    CGSize size([super intrinsicContentSize]);
    return CGSizeMake(std::max<CGFloat>(44.0, size.width),
                      std::max<CGFloat>(44.0, size.height));
}

@end
@interface CydiaPackageDetailHeaderView : UIView
@property(nonatomic, strong, readonly) UIImageView *iconView;
@property(nonatomic, strong, readonly) UILabel *nameLabel;
@property(nonatomic, strong, readonly) UILabel *architectureLabel;
@property(nonatomic, strong, readonly) UILabel *versionLabel;
@property(nonatomic, strong, readonly) UILabel *sizeLabel;
- (instancetype)initWithViewModel:(CydiaPackageDetailViewModel *)viewModel
                              icon:(UIImage *)icon;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
- (void)applyColorAppearance;
@end

@implementation CydiaPackageDetailHeaderView

- (instancetype)initWithViewModel:(CydiaPackageDetailViewModel *)viewModel
                              icon:(UIImage *)icon {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 320, 88)]) != nil) {
        self.accessibilityIdentifier = @"cydia.package.header";

        _iconView = [[UIImageView alloc] initWithImage:icon];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 9.0;
        _iconView.layer.masksToBounds = YES;
        _iconView.isAccessibilityElement = YES;
        _iconView.accessibilityIdentifier = @"cydia.package.header.icon";
        _iconView.accessibilityLabel = [viewModel displayName];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _nameLabel.adjustsFontForContentSizeCategory = YES;
        _nameLabel.numberOfLines = 2;
        _nameLabel.text = [viewModel displayName];
        _nameLabel.accessibilityIdentifier = @"cydia.package.header.name";

        _architectureLabel = [[UILabel alloc] init];
        _architectureLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _architectureLabel.adjustsFontForContentSizeCategory = YES;
        _architectureLabel.numberOfLines = 0;
        _architectureLabel.text = [viewModel architectureCaption];
        _architectureLabel.hidden = [_architectureLabel.text length] == 0;
        _architectureLabel.accessibilityIdentifier = @"cydia.package.header.architecture";

        _versionLabel = [[UILabel alloc] init];
        _versionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _versionLabel.adjustsFontForContentSizeCategory = YES;
        _versionLabel.text = [viewModel latestVersion];
        _versionLabel.accessibilityIdentifier = @"cydia.package.header.version";

        _sizeLabel = [[UILabel alloc] init];
        _sizeLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _sizeLabel.adjustsFontForContentSizeCategory = YES;
        _sizeLabel.textAlignment = NSTextAlignmentRight;
        _sizeLabel.text = PackageSizeDescription([viewModel installedSizeBytes]);
        _sizeLabel.accessibilityIdentifier = @"cydia.package.header.size";

        UIStackView *metadata([[UIStackView alloc]
            initWithArrangedSubviews:@[_versionLabel, _sizeLabel]]);
        metadata.axis = UILayoutConstraintAxisHorizontal;
        metadata.alignment = UIStackViewAlignmentFirstBaseline;
        metadata.distribution = UIStackViewDistributionFill;
        metadata.spacing = 8.0;

        UIStackView *text([[UIStackView alloc]
            initWithArrangedSubviews:@[_nameLabel, _architectureLabel, metadata]]);
        text.translatesAutoresizingMaskIntoConstraints = NO;
        text.axis = UILayoutConstraintAxisVertical;
        text.alignment = UIStackViewAlignmentFill;
        text.spacing = 7.0;

        [self addSubview:_iconView];
        [self addSubview:text];
        UILayoutGuide *margins(self.layoutMarginsGuide);
        [NSLayoutConstraint activateConstraints:@[
            [_iconView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_iconView.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:64.0],
            [_iconView.heightAnchor constraintEqualToConstant:64.0],
            [text.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:10.0],
            [text.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [text.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [text.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
            [_iconView.bottomAnchor constraintLessThanOrEqualToAnchor:margins.bottomAnchor],
        ]];
        [_nameLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                      forAxis:UILayoutConstraintAxisVertical];
        [_sizeLabel setContentHuggingPriority:UILayoutPriorityRequired
                                       forAxis:UILayoutConstraintAxisHorizontal];
        [self applyColorAppearance];
    }
    return self;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    UIEdgeInsets margins(self.layoutMargins);
    CGFloat textWidth(std::max<CGFloat>(1.0,
        width - margins.left - margins.right - 64.0 - 10.0));
    CGFloat nameHeight(std::ceil([_nameLabel
        sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height));
    CGFloat versionHeight(std::ceil([_versionLabel
        sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height));
    CGFloat sizeHeight(std::ceil([_sizeLabel
        sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height));
    CGFloat textHeight(nameHeight + 7.0 + std::max(versionHeight, sizeHeight));
    if (!_architectureLabel.hidden)
        textHeight += 7.0 + std::ceil([_architectureLabel
            sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height);
    return std::ceil(margins.top + std::max<CGFloat>(64.0, textHeight) + margins.bottom);
}

- (void)applyColorAppearance {
    UITraitCollection *traits(self.traitCollection);
    /* The package topper is part of the page canvas, not another metadata
     * card. The legacy page painted this region with the grouped surface. */
    self.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                       traitCollection:traits];
    _nameLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
                                       traitCollection:traits];
    _architectureLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                               traitCollection:traits];
    _versionLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleCommercialSecondaryLabel
                                          traitCollection:traits];
    _sizeLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleCommercialSecondaryLabel
                                       traitCollection:traits];
}

@end
@interface CydiaPackageDetailBodyCell : UITableViewCell
@property(nonatomic, strong, readonly) UILabel *bodyLabel;
@end

@implementation CydiaPackageDetailBodyCell

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault
                      reuseIdentifier:reuseIdentifier]) != nil) {
        _bodyLabel = [[UILabel alloc] init];
        _bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _bodyLabel.numberOfLines = 0;
        _bodyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _bodyLabel.adjustsFontForContentSizeCategory = YES;
        [self.contentView addSubview:_bodyLabel];
        UILayoutGuide *margins(self.contentView.layoutMarginsGuide);
        [NSLayoutConstraint activateConstraints:@[
            [_bodyLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_bodyLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [_bodyLabel.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [_bodyLabel.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
        ]];
    }
    return self;
}

@end


@interface PackageDetailController () <UITableViewDataSource, UITableViewDelegate,
                                        PackageDepictionViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) CydiaPackageDetailHeaderView *packageHeaderView;
@property(nonatomic, strong) UIView *packageFooterView;
@property(nonatomic, strong) UILabel *packageFooterLabel;
@property(nonatomic, copy) NSArray<NSNumber *> *sections;
@property(nonatomic, copy) NSArray<NSDictionary *> *metadataRows;
@property(nonatomic) BOOL depictionEligible;
@property(nonatomic, strong) PackageDepictionView *depictionView;
@property(nonatomic, strong) CydiaPackageDepictionCell *depictionCell;
@property(nonatomic) BOOL depictionTableUpdateScheduled;
@property(nonatomic) BOOL depictionAccessibilityFocusSeeded;
@property(nonatomic, strong) CydiaRepositoryPackagePresentation *repositoryPresentation;
@property(nonatomic, copy) NSString *repositoryAccountNotice;
@property(nonatomic, copy) NSString *repositoryRequestUserAgent;
@property(nonatomic) NSUInteger repositoryRequestGeneration;
@property(nonatomic) BOOL repositoryInfoLoading, repositoryInfoLoaded;
/* CyteViewController.delegate remains the application coordinator.  Keep the
 * package-shell callbacks on a distinct weak channel so production routing can
 * install both delegates without one silently replacing the other. */
@property(nonatomic, weak) id<PackageDetailControllerDelegate> packageDelegate;
@end

@implementation PackageDetailController

- (UIStatusBarStyle)preferredStatusBarStyle {
    return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ?
        UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}

- (instancetype)initWithViewModel:(CydiaPackageDetailViewModel *)viewModel
                       headerIcon:(UIImage *)headerIcon
                         delegate:(id<PackageDetailControllerDelegate>)delegate {
    NSParameterAssert(viewModel != nil);
    if ((self = [super init]) != nil) {
        _viewModel = viewModel;
        _headerIcon = headerIcon ?: [UIImage imageNamed:@"unknown.png"] ?: [[UIImage alloc] init];
        _depictionEligible = [[CydiaPackageDepictionPolicy alloc]
            initWithURLString:[viewModel depictionURLString]] != nil;
        _packageDelegate = delegate;
        [self rebuildSections];
    }
    return self;
}

- (void)configureNavigationItem {
    self.navigationItem.title = UCLocalize("DETAILS");
    NSString *key([_viewModel primaryModifyTitleLocalizationKey]);
    if (key == nil) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    /* A title-only UIBarButtonItem can expose a sub-44pt AX frame for short
     * localized titles.  Keep the same bar-item anchor while giving VoiceOver
     * and UIKit a concrete 44x44 minimum target. */
    CydiaMinimumTargetButton *modifyButton(
        [CydiaMinimumTargetButton buttonWithType:UIButtonTypeSystem]);
    modifyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [modifyButton setTitle:([key isEqualToString:@"ACCOUNTS"] ? CydiaAccountLocalize(key) : [key hasPrefix:@"PACKAGE_"] ?
        [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Actions"] : UCLocalizeEx(key))
        forState:UIControlStateNormal];
    modifyButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    modifyButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    modifyButton.accessibilityIdentifier = @"cydia.package.modify";
    [modifyButton addTarget:self action:@selector(modifyButtonClicked)
           forControlEvents:UIControlEventTouchUpInside];
    [modifyButton.widthAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;
    [modifyButton.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithCustomView:modifyButton];
}

- (void)updateFooterLabel {
    NSString *detail(FooterDetail(_viewModel));
    _packageFooterLabel.text = [detail length] == 0 ? [_viewModel identity] :
        [NSString stringWithFormat:@"%@\n%@", [_viewModel identity], detail];
    _packageFooterLabel.accessibilityLabel = [_viewModel identity];
    _packageFooterLabel.accessibilityValue = detail;
}

- (void)updateWithViewModel:(CydiaPackageDetailViewModel *)viewModel
                 headerIcon:(UIImage *)headerIcon
                 reloadTable:(BOOL)reloadTable {
    NSParameterAssert(viewModel != nil);
    NSString *previousDepictionURL([_viewModel depictionURLString]);
    NSString *nextDepictionURL([viewModel depictionURLString]);
    BOOL nextDepictionEligible([[CydiaPackageDepictionPolicy alloc]
        initWithURLString:nextDepictionURL] != nil);
    BOOL preserveDepictionView(_depictionView != nil && _depictionCell != nil &&
        _depictionEligible && nextDepictionEligible &&
        [previousDepictionURL length] != 0 &&
        [previousDepictionURL isEqualToString:nextDepictionURL]);
    _viewModel = viewModel;
    ++_repositoryRequestGeneration;
    _repositoryPresentation = nil; _repositoryAccountNotice = nil;
    _repositoryInfoLoading = NO; _repositoryInfoLoaded = NO;
    _headerIcon = headerIcon ?: [UIImage imageNamed:@"unknown.png"] ?: [[UIImage alloc] init];
    _depictionEligible = nextDepictionEligible;
    if (!preserveDepictionView) {
        _depictionView = nil;
        _depictionCell = nil;
    }
    [self rebuildSections];
    if (![self isViewLoaded])
        return;

    _packageHeaderView = [[CydiaPackageDetailHeaderView alloc]
        initWithViewModel:_viewModel icon:_headerIcon];
    _tableView.tableHeaderView = _packageHeaderView;
    [self updateFooterLabel];
    [self configureNavigationItem];
    if (reloadTable)
        [_tableView reloadData];
    [self applyColorAppearance];
    [self.view setNeedsLayout];
    if (self.view.window != nil) [self loadRepositoryPackagePrice];
}

- (void)updateWithViewModel:(CydiaPackageDetailViewModel *)viewModel
                 headerIcon:(UIImage *)headerIcon {
    [self updateWithViewModel:viewModel headerIcon:headerIcon reloadTable:YES];
}

- (void)updateHeaderIcon:(UIImage *)headerIcon {
    _headerIcon = headerIcon ?: [UIImage imageNamed:@"unknown.png"] ?: [[UIImage alloc] init];
    if (![self isViewLoaded])
        return;
    _packageHeaderView.iconView.image = _headerIcon;
    [_packageHeaderView setNeedsLayout];
}

- (NSURL *)navigationURL {
    if (_viewModel.readOnly) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@",
                                                          [_viewModel identity]]];
}

- (void)rebuildSections {
    NSMutableArray<NSNumber *> *sections([NSMutableArray array]);
    _metadataRows = _viewModel.readOnly ? CydiaPackageDetailMetadataRows(_viewModel) : @[];
    if ([_viewModel modeLocalizationKey] != nil)
        [sections addObject:@(CydiaPackageDetailSectionKindQueue)];
    if (!_viewModel.readOnly) [sections addObject:@(CydiaPackageDetailSectionKindActions)];
    if (!_viewModel.readOnly && _viewModel.isCommercial && _viewModel.source.repositoryURLString.length)
        [sections addObject:@(CydiaPackageDetailSectionKindAccount)];
    if ([[_viewModel warnings] count] != 0)
        [sections addObject:@(CydiaPackageDetailSectionKindWarnings)];
    if (_metadataRows.count) [sections addObject:@(CydiaPackageDetailSectionKindMetadata)];
    if (_viewModel.readOnly && _depictionEligible && _viewModel.displayDescription.length)
        [sections addObject:@(CydiaPackageDetailSectionKindDescription)];
    if (_depictionEligible) {
        [sections addObject:@(CydiaPackageDetailSectionKindDepiction)];
    } else {
        if ([[_viewModel displayDescription] length] != 0)
            [sections addObject:@(CydiaPackageDetailSectionKindDescription)];
        if (!_viewModel.readOnly && [[_viewModel homepageURLString] length] != 0)
            [sections addObject:@(CydiaPackageDetailSectionKindHomepage)];
    }
    if ([_viewModel isInstalled])
        [sections addObject:@(CydiaPackageDetailSectionKindInstalled)];
    if ([_viewModel source] != nil)
        [sections addObject:@(CydiaPackageDetailSectionKindSource)];
    _sections = [sections copy];
}

- (void)loadView {
    UIView *root([[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]]);
    root.backgroundColor = UIColor.cydiaGroupedBackgroundColor;
    [self setView:root];

    UITableView *table([[UITableView alloc] initWithFrame:CGRectZero
                                                    style:UITableViewStyleGrouped]);
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.dataSource = self;
    table.delegate = self;
    table.estimatedRowHeight = 52.0;
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedSectionHeaderHeight = 0.0;
    table.estimatedSectionFooterHeight = 0.0;
    table.accessibilityIdentifier = @"cydia.package.table";
    if ([table respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)])
        table.cellLayoutMarginsFollowReadableWidth = NO;
    [root addSubview:table];
    UILayoutGuide *safe(root.safeAreaLayoutGuide);
    NSLayoutConstraint *fullWidth([table.widthAnchor constraintEqualToAnchor:safe.widthAnchor]);
    fullWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [table.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [table.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [table.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [table.widthAnchor constraintLessThanOrEqualToConstant:414.0],
        [table.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor],
        [table.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor],
        fullWidth,
    ]];
    _tableView = table;

    _packageHeaderView = [[CydiaPackageDetailHeaderView alloc]
        initWithViewModel:_viewModel icon:_headerIcon];
    table.tableHeaderView = _packageHeaderView;

    UIView *footer([[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 66)]);
    UILabel *footerLabel([[UILabel alloc] init]);
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    footerLabel.numberOfLines = 2;
    footerLabel.textAlignment = NSTextAlignmentCenter;
    footerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footerLabel.adjustsFontForContentSizeCategory = YES;
    footerLabel.accessibilityIdentifier = @"cydia.package.footer";
    [footer addSubview:footerLabel];
    UILayoutGuide *footerMargins(footer.layoutMarginsGuide);
    [NSLayoutConstraint activateConstraints:@[
        [footerLabel.leadingAnchor constraintEqualToAnchor:footerMargins.leadingAnchor],
        [footerLabel.trailingAnchor constraintEqualToAnchor:footerMargins.trailingAnchor],
        [footerLabel.topAnchor constraintEqualToAnchor:footerMargins.topAnchor],
        [footerLabel.bottomAnchor constraintEqualToAnchor:footerMargins.bottomAnchor],
    ]];
    _packageFooterView = footer;
    _packageFooterLabel = footerLabel;
    [self updateFooterLabel];
    table.tableFooterView = footer;
    [self applyColorAppearance];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self configureNavigationItem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(packageVoiceOverStatusDidChange:)
                                                 name:UIAccessibilityVoiceOverStatusDidChangeNotification
                                               object:nil];
}

- (void)seedPackageDepictionAccessibilityFocus {
    CydiaPackageDepictionViewState state([_depictionView state]);
    BOOL failed(state == CydiaPackageDepictionViewStateFailed || state == CydiaPackageDepictionViewStatePathologicalContent);
    if (!failed) return;
    if (_depictionAccessibilityFocusSeeded || !UIAccessibilityIsVoiceOverRunning() || _depictionCell == nil || _depictionCell.retryButton == nil)
        return;
    void (^seed)(void) = ^{
        CydiaPackageDepictionViewState current(self.depictionView.state);
        if (self.depictionAccessibilityFocusSeeded || self.view.window == nil || self.depictionCell.window == nil || self.navigationController.topViewController != self || self.navigationController.presentedViewController != nil || self.tabBarController.presentedViewController != nil || self.presentedViewController != nil ||
            (current != CydiaPackageDepictionViewStateFailed && current != CydiaPackageDepictionViewStatePathologicalContent) ||
            !UIAccessibilityIsVoiceOverRunning())
            return;
        self.depictionAccessibilityFocusSeeded = YES;
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.depictionCell.retryButton);
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.depictionCell.retryButton);
    };
    for (NSUInteger delay = 0; delay <= 1500; delay += 250)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC), dispatch_get_main_queue(), seed);
}
- (void)packageVoiceOverStatusDidChange:(NSNotification *)notification {
    (void)notification;
    self.depictionAccessibilityFocusSeeded = NO;
    if (UIAccessibilityIsVoiceOverRunning())
        [self seedPackageDepictionAccessibilityFocus];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self resizeTableSupplementaryView:_packageHeaderView minimumHeight:80.0 header:YES];
    [self resizeTableSupplementaryView:_packageFooterView minimumHeight:66.0 header:NO];
}

- (void)resizeTableSupplementaryView:(UIView *)view
                       minimumHeight:(CGFloat)minimumHeight
                              header:(BOOL)header {
    if (view == nil || CGRectGetWidth(_tableView.bounds) <= 0.0)
        return;
    CGRect frame(view.frame);
    frame.size.width = CGRectGetWidth(_tableView.bounds);
    view.frame = frame;
    CGFloat height([view systemLayoutSizeFittingSize:CGSizeMake(frame.size.width, 0.0)
                       withHorizontalFittingPriority:UILayoutPriorityRequired
                             verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
    if (header)
        height = std::max(height, [_packageHeaderView preferredHeightForWidth:frame.size.width]);
    height = std::max(minimumHeight, std::ceil(height));
    if (std::fabs(CGRectGetHeight(frame) - height) < 0.5)
        return;
    frame.size.height = height;
    view.frame = frame;
    if (header)
        _tableView.tableHeaderView = view;
    else
        _tableView.tableFooterView = view;
}

- (void)applyColorAppearance {
    UITraitCollection *traits(self.traitCollection);
    UIColor *grouped([UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                 traitCollection:traits]);
    UIColor *label([UIColor cydiaColorForRole:CydiaColorRoleLabel
                              traitCollection:traits]);
    UIColor *accent([UIColor cydiaColorForRole:CydiaColorRoleAccent
                               traitCollection:traits]);
    self.view.backgroundColor = grouped;
    _tableView.backgroundColor = grouped;
    _tableView.separatorColor = [UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                           traitCollection:traits];
    [_packageHeaderView applyColorAppearance];
    _packageFooterView.backgroundColor = grouped;
    _packageFooterLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                                traitCollection:traits];
    [_depictionCell applyColorAppearance:traits];
    if (self.navigationController != nil) {
        UINavigationBar *navigationBar(self.navigationController.navigationBar);
        navigationBar.barStyle = traits.userInterfaceStyle == UIUserInterfaceStyleDark ?
            UIBarStyleBlack : UIBarStyleDefault;
        navigationBar.tintColor = accent;
        navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: label};
    }
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection) ||
        ![self.traitCollection.preferredContentSizeCategory
            isEqualToString:previousTraitCollection.preferredContentSizeCategory]) {
        [self applyColorAppearance];
        [_tableView reloadData];
        [self.view setNeedsLayout];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyColorAppearance];
    if (![_repositoryRequestUserAgent isEqual:CydiaRepositoryUserAgent()]) {
        _repositoryInfoLoading = NO; _repositoryInfoLoaded = NO;
        _repositoryPresentation = nil; _repositoryAccountNotice = nil;
        ++_repositoryRequestGeneration;
    }
    if (!_repositoryInfoLoading && !_repositoryInfoLoaded) [self loadRepositoryPackagePrice];
}

- (void)loadRepositoryPackagePrice {
    CydiaPackageDetailViewModel *selection = _viewModel;
    if (selection.readOnly || !selection.isCommercial || !selection.source.repositoryURLString.length) return;
    _repositoryRequestUserAgent = CydiaRepositoryUserAgent();
    _repositoryInfoLoading = YES;
    NSUInteger generation = ++_repositoryRequestGeneration;
    __weak PackageDetailController *weakSelf = self;
    CydiaRepositoryAccountService *service = [CydiaRepositoryAccountService sharedService];
    [service discoverSource:[NSURL URLWithString:selection.source.repositoryURLString] name:selection.source.name
        completion:^(CydiaRepositoryAccount *account, NSError *error) {
        PackageDetailController *self = weakSelf;
        if (!self || self.repositoryRequestGeneration != generation || self.viewModel != selection) return;
        self.repositoryAccountNotice = error.localizedDescription;
        if (!account || !account.supportsAccountIntegration) {
            self.repositoryInfoLoading = NO; self.repositoryInfoLoaded = YES; [self reloadRepositoryPackageRow]; return;
        }
        /* Public package metadata does not send a token or device identifier.
         * Ownership is checked only in the source-scoped account interface. */
        [service anonymousPackageInfo:selection.baseIdentity ?: selection.identity account:account
            completion:^(NSDictionary *info, NSError *packageError) {
            PackageDetailController *self = weakSelf;
            if (!self || self.repositoryRequestGeneration != generation || self.viewModel != selection) return;
            self.repositoryInfoLoading = NO; self.repositoryInfoLoaded = YES;
            self.repositoryPresentation = [[CydiaRepositoryPackagePresentation alloc] initWithInfo:packageError ? nil : info
                signedIn:NO supported:account.supportsAccountIntegration downloadAvailable:NO
                downloadSupported:(account.capabilities & CydiaRepositoryCapabilityDownload) != 0
                purchaseAvailable:NO purchaseURL:nil];
            if (packageError) self.repositoryAccountNotice = packageError.localizedDescription;
            [self reloadRepositoryPackageRow];
        }];
    }];
}
- (void)reloadRepositoryPackageRow {
    NSUInteger section = [_sections indexOfObject:@(CydiaPackageDetailSectionKindAccount)];
    if (section == NSNotFound || !_tableView) return;
    [_tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:section]]
        withRowAnimation:UITableViewRowAnimationNone];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    CydiaCaptureNativeAccessibility(self, @"package");
    [self seedPackageDepictionAccessibilityFocus];
}

- (void)reloadData {
    [super reloadData];
    [_tableView reloadData];
}

- (void)releaseSubviews {
    _tableView = nil;
    _packageHeaderView = nil;
    _packageFooterView = nil;
    _packageFooterLabel = nil;
    _depictionView = nil;
    _depictionCell = nil;
    [super releaseSubviews];
}

- (CydiaPackageDetailSectionKind)sectionKind:(NSInteger)section {
    return static_cast<CydiaPackageDetailSectionKind>([[_sections objectAtIndex:section]
        unsignedIntegerValue]);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return [_sections count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch ([self sectionKind:section]) {
        case CydiaPackageDetailSectionKindMetadata: return _metadataRows.count;
        case CydiaPackageDetailSectionKindQueue:
        case CydiaPackageDetailSectionKindDepiction:
        case CydiaPackageDetailSectionKindDescription:
        case CydiaPackageDetailSectionKindHomepage:
        case CydiaPackageDetailSectionKindAccount:
            return 1;
        case CydiaPackageDetailSectionKindActions:
            return 2 + ([_viewModel isConsolePackage] ? 1 : 0) +
                [[_viewModel applications] count];
        case CydiaPackageDetailSectionKindWarnings:
            return [[_viewModel warnings] count];
        case CydiaPackageDetailSectionKindInstalled:
            return 2;
        case CydiaPackageDetailSectionKindSource:
            return [[[_viewModel source] sourceDescription] length] == 0 ? 1 : 2;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch ([self sectionKind:section]) {
        case CydiaPackageDetailSectionKindInstalled:
            return UCLocalize("INSTALLED_DETAILS");
        case CydiaPackageDetailSectionKindSource:
            return UCLocalize("SOURCE_DETAILS");
        default:
            return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    CydiaPackageDetailSectionKind kind([self sectionKind:section]);
    if (kind == CydiaPackageDetailSectionKindDepiction)
        return 0.01;
    return kind == CydiaPackageDetailSectionKindInstalled ||
           kind == CydiaPackageDetailSectionKindSource ? 28.0 : 9.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 0.01;
}

- (CGFloat)tableView:(UITableView *)tableView
 heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    CydiaPackageDetailSectionKind kind([self sectionKind:indexPath.section]);
    /* Keep shipped one-line metadata rows at the legacy 44-point touch
     * target. Description, warning, source-description, and depiction rows
     * remain automatic so long content and Dynamic Type can expand safely. */
    BOOL fixed(kind == CydiaPackageDetailSectionKindQueue ||
               kind == CydiaPackageDetailSectionKindActions ||
               kind == CydiaPackageDetailSectionKindHomepage ||
               kind == CydiaPackageDetailSectionKindInstalled ||
               (kind == CydiaPackageDetailSectionKindSource && indexPath.row == 0));
    if (!fixed || UIContentSizeCategoryIsAccessibilityCategory(
            self.traitCollection.preferredContentSizeCategory))
        return UITableViewAutomaticDimension;
    return 44.0;
}

- (UITableViewCell *)standardCellForTable:(UITableView *)tableView {
    static NSString *identifier = @"CydiaPackageDetailValue";
    UITableViewCell *cell([tableView dequeueReusableCellWithIdentifier:identifier]);
    if (cell == nil)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:identifier];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.numberOfLines = 1;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    cell.imageView.accessibilityIdentifier = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessibilityIdentifier = nil;
    cell.accessibilityLabel = nil;
    cell.accessibilityValue = nil;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground
                                      traitCollection:self.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
                                          traitCollection:self.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                                traitCollection:self.traitCollection];
    return cell;
}

- (UITableViewCell *)bodyCellForTable:(UITableView *)tableView {
    static NSString *identifier = @"CydiaPackageDetailBody";
    CydiaPackageDetailBodyCell *cell((CydiaPackageDetailBodyCell *)
        [tableView dequeueReusableCellWithIdentifier:identifier]);
    if (cell == nil)
        cell = [[CydiaPackageDetailBodyCell alloc] initWithReuseIdentifier:identifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.isAccessibilityElement = YES;
    cell.accessibilityTraits = UIAccessibilityTraitStaticText;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground
                                      traitCollection:self.traitCollection];
    cell.bodyLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
                                          traitCollection:self.traitCollection];
    return cell;
}

- (UITableViewCell *)depictionCellForTable:(UITableView *)tableView {
    (void)tableView;
    if (_depictionCell == nil) {
        _depictionCell = [[CydiaPackageDepictionCell alloc]
            initWithReuseIdentifier:@"CydiaPackageDepiction"];
        [_depictionCell.retryButton addTarget:self action:@selector(retryDepiction)
                               forControlEvents:UIControlEventTouchUpInside];
        [_depictionCell.externalButton addTarget:self
                                          action:@selector(openDepictionExternally)
                                forControlEvents:UIControlEventTouchUpInside];
        _depictionView = [[PackageDepictionView alloc]
            initWithURLString:[_viewModel depictionURLString]
            compatibilitySnapshot:[_viewModel legacyDepictionSnapshot]
            delegate:self];
        _depictionCell.depictionView = _depictionView;
        [_depictionCell applyColorAppearance:self.traitCollection];
        [_depictionView startLoading];
    }
    [_depictionCell applyDepictionPresentation];
    return _depictionCell;
}

- (void)configureActionCell:(UITableViewCell *)cell row:(NSInteger)row {
    if (row == 0) {
        cell.textLabel.text = UCLocalize("CHANGE_PACKAGE_SETTINGS");
        SetLegacyPackageRowImage(cell, @"settings.png");
        cell.accessibilityIdentifier = @"cydia.package.action.settings";
    } else if (row == 1) {
        cell.textLabel.text = ContactTitle(_viewModel);
        cell.detailTextLabel.text = [_viewModel contactName];
        SetLegacyPackageRowImage(cell, @"email.png");
        cell.accessibilityIdentifier = @"cydia.package.action.contact";
        NSString *contactURL(ContactURLString(_viewModel));
        cell.selectionStyle = [contactURL length] == 0 ?
            UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        return;
    } else {
        NSInteger offset(row - 2);
        if ([_viewModel isConsolePackage]) {
            if (offset == 0) {
                cell.textLabel.text = UCLocalize("CONSOLE_PACKAGE");
                SetLegacyPackageRowImage(cell, @"console.png");
                cell.accessibilityIdentifier = @"cydia.package.action.console";
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                return;
            }
            --offset;
        }
        CydiaPackageDetailApplication *application([[_viewModel applications]
            objectAtIndex:offset]);
        cell.textLabel.text = [application displayName];
        cell.imageView.image = LocalPackageImageForURLString(
            [application iconURLString], @"Icon-Small.png");
        cell.accessibilityIdentifier = [NSString stringWithFormat:
            @"cydia.package.action.application.%ld", (long)offset];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    CydiaPackageDetailSectionKind kind([self sectionKind:indexPath.section]);
    if (kind == CydiaPackageDetailSectionKindMetadata)
        return CydiaPackageDetailMetadataCell(tableView, _metadataRows[indexPath.row], self.traitCollection);
    if (kind == CydiaPackageDetailSectionKindAccount) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CydiaPackageAccount"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"CydiaPackageAccount"];
        cell.textLabel.text = CydiaAccountLocalize(@"ACCOUNT_PURCHASE_OPTIONS");
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
        cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
        cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:self.traitCollection];
        cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:self.traitCollection];
        NSMutableArray *details = [NSMutableArray array];
        if (_repositoryInfoLoading) [details addObject:UCLocalize("LOADING")];
        if (_repositoryPresentation.price.length) [details addObject:_repositoryPresentation.price];
        if (_repositoryAccountNotice.length) [details addObject:_repositoryAccountNotice];
        cell.detailTextLabel.text = [details componentsJoinedByString:@"\n"];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = @"cydia.package.account";
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        return cell;
    }
    if (kind == CydiaPackageDetailSectionKindDepiction)
        return [self depictionCellForTable:tableView];
    if (kind == CydiaPackageDetailSectionKindDescription) {
        CydiaPackageDetailBodyCell *cell((CydiaPackageDetailBodyCell *)
            [self bodyCellForTable:tableView]);
        NSString *raw([_viewModel legacyDepictionSnapshot][@"package"][@"fields"][@"Description"]);
        cell.bodyLabel.text = [raw isKindOfClass:[NSString class]] ?
            CydiaPackageDescriptionForDisplay(raw, [_viewModel shortDescription]) :
            [_viewModel displayDescription];
        // Menlo/UIFontMetrics are available on iOS 12. Keep raw metadata and
        // depiction APIs unchanged; only the native reading surface reflows.
        UIFont *fixed([UIFont fontWithName:@"Menlo" size:13.0] ?: [UIFont systemFontOfSize:13.0]);
        cell.bodyLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
            scaledFontForFont:fixed compatibleWithTraitCollection:self.traitCollection];
        cell.accessibilityIdentifier = @"cydia.package.description";
        cell.accessibilityLabel = cell.bodyLabel.text;
        return cell;
    }

    UITableViewCell *cell([self standardCellForTable:tableView]);
    switch (kind) {
        case CydiaPackageDetailSectionKindQueue: {
            cell.textLabel.text = UCLocalize("PACKAGE_QUEUE");
            cell.detailTextLabel.text = UCLocalizeEx([_viewModel modeLocalizationKey]);
            NSString *modeAsset(PackageModeAsset([_viewModel modeLocalizationKey]));
            cell.imageView.image = LocalPackageImage(modeAsset);
            cell.imageView.accessibilityIdentifier = modeAsset;
            cell.accessibilityIdentifier = @"cydia.package.queue";
            break;
        }
        case CydiaPackageDetailSectionKindActions:
            [self configureActionCell:cell row:indexPath.row];
            break;
        case CydiaPackageDetailSectionKindWarnings:
            cell.textLabel.text = [[_viewModel warnings] objectAtIndex:indexPath.row];
            cell.textLabel.numberOfLines = 0;
            SetLegacyPackageRowImage(cell, @"warning.png");
            cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleRemovingBackground
                                              traitCollection:self.traitCollection];
            cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleErrorLabel
                                                  traitCollection:self.traitCollection];
            cell.accessibilityIdentifier = [NSString stringWithFormat:
                @"cydia.package.warning.%ld", (long)indexPath.row];
            cell.accessibilityLabel = [NSString stringWithFormat:@"%@: %@",
                UCLocalize("WARNING"), cell.textLabel.text];
            break;
        case CydiaPackageDetailSectionKindDepiction:
        case CydiaPackageDetailSectionKindAccount:
        case CydiaPackageDetailSectionKindMetadata:
            break;
        case CydiaPackageDetailSectionKindHomepage:
            cell.textLabel.text = UCLocalize("MORE_INFORMATION");
            SetLegacyPackageRowImage(cell, @"web.png");
            cell.accessibilityIdentifier = @"cydia.package.action.homepage";
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        case CydiaPackageDetailSectionKindInstalled:
            if (indexPath.row == 0) {
                cell.textLabel.text = UCLocalize("VERSION");
                cell.detailTextLabel.text = [_viewModel installedVersion];
                SetLegacyPackageRowImage(cell, @"version.png");
                cell.accessibilityIdentifier = @"cydia.package.installed.version";
            } else {
                cell.textLabel.text = UCLocalize("FILESYSTEM_CONTENT");
                SetLegacyPackageRowImage(cell, @"filesystem.png");
                cell.accessibilityIdentifier = @"cydia.package.action.files";
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
            break;
        case CydiaPackageDetailSectionKindSource:
            if (indexPath.row == 0) {
                cell.textLabel.text = [[_viewModel source] name];
                cell.detailTextLabel.text = [[_viewModel source] host];
                cell.imageView.image = LocalPackageImageForURLString(
                    [[_viewModel source] iconURLString], @"folder.png");
                cell.accessibilityIdentifier = @"cydia.package.source.name";
            } else {
                cell.textLabel.text = [[_viewModel source] sourceDescription];
                cell.textLabel.numberOfLines = 0;
                cell.accessibilityIdentifier = @"cydia.package.source.description";
            }
            break;
        case CydiaPackageDetailSectionKindDescription:
            break;
    }
    cell.isAccessibilityElement = YES;
    if (cell.selectionStyle != UITableViewCellSelectionStyleNone)
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (cell.accessibilityLabel == nil)
        cell.accessibilityLabel = cell.textLabel.text;
    if ([cell.detailTextLabel.text length] != 0)
        cell.accessibilityValue = cell.detailTextLabel.text;
    cell.accessibilityTraits = cell.selectionStyle == UITableViewCellSelectionStyleNone ?
        UIAccessibilityTraitStaticText : UIAccessibilityTraitButton;
    return cell;
}

- (void)scheduleDepictionTableUpdate {
    if (_depictionTableUpdateScheduled)
        return;
    _depictionTableUpdateScheduled = YES;
    __weak PackageDetailController *weakSelf(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        PackageDetailController *strongSelf(weakSelf);
        strongSelf.depictionTableUpdateScheduled = NO;
        if (strongSelf.depictionCell == nil || strongSelf.tableView == nil)
            return;
        [strongSelf.depictionCell applyDepictionPresentation];
        [UIView performWithoutAnimation:^{
            [strongSelf.tableView beginUpdates];
            [strongSelf.tableView endUpdates];
        }];
        [strongSelf seedPackageDepictionAccessibilityFocus];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [strongSelf seedPackageDepictionAccessibilityFocus]; });
    });
}

- (void)packageDepictionViewDidChangePresentation:(PackageDepictionView *)view {
    if (view == _depictionView) {
        [self scheduleDepictionTableUpdate];
    }
}

- (void)packageDepictionView:(PackageDepictionView *)view
       didRequestURLHandoff:(NSURL *)URL {
    if (view != _depictionView || URL == nil)
        return;
    [_packageDelegate packageDetailController:self
                      didSelectNavigationKind:CydiaPackageDetailNavigationKindDepictionLink
                                    URLString:[URL absoluteString]
                                   identifier:[_viewModel identity]];
}

- (void)retryDepiction {
    _depictionAccessibilityFocusSeeded = NO;
    [_depictionView retryLoading];
}

- (void)openDepictionExternally {
    [self packageDepictionView:_depictionView
          didRequestURLHandoff:[_depictionView initialURL]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id<PackageDetailControllerDelegate> delegate(_packageDelegate);
    if (delegate == nil)
        return;
    CydiaPackageDetailSectionKind kind([self sectionKind:indexPath.section]);
    CydiaPackageDetailNavigationKind navigationKind;
    NSString *URLString(nil);
    NSString *identifier(nil);
    if (kind == CydiaPackageDetailSectionKindMetadata) {
        URLString = _metadataRows[indexPath.row][@"url"];
        if (!URLString.length) return;
        navigationKind = [URLString.lowercaseString hasPrefix:@"mailto:"] ?
            CydiaPackageDetailNavigationKindContact : CydiaPackageDetailNavigationKindHomepage;
    } else if (kind == CydiaPackageDetailSectionKindAccount) {
        for (CydiaPackageDetailModifyAction *action in _viewModel.modifyActions) {
            if (action.kind == CydiaPackageDetailModifyActionKindAccount) { [self selectModifyAction:action]; break; }
        }
        return;
    } else if (kind == CydiaPackageDetailSectionKindActions) {
        if (indexPath.row == 0) {
            navigationKind = CydiaPackageDetailNavigationKindSettings;
            URLString = [NSString stringWithFormat:@"cydia://package/%@/settings",
                                                   [_viewModel identity]];
        } else if (indexPath.row == 1) {
            navigationKind = CydiaPackageDetailNavigationKindContact;
            URLString = ContactURLString(_viewModel);
            if ([URLString length] == 0)
                return;
            identifier = [_viewModel identity];
        } else {
            NSInteger offset(indexPath.row - 2);
            if ([_viewModel isConsolePackage]) {
                if (offset == 0) {
                    navigationKind = CydiaPackageDetailNavigationKindConsole;
                    URLString = @"cydia://home/console";
                    goto dispatch;
                }
                --offset;
            }
            CydiaPackageDetailApplication *application([[_viewModel applications]
                objectAtIndex:offset]);
            navigationKind = CydiaPackageDetailNavigationKindApplication;
            identifier = [application bundleIdentifier];
        }
    } else if (kind == CydiaPackageDetailSectionKindHomepage) {
        navigationKind = CydiaPackageDetailNavigationKindHomepage;
        URLString = [_viewModel homepageURLString];
    } else if (kind == CydiaPackageDetailSectionKindInstalled && indexPath.row == 1) {
        navigationKind = CydiaPackageDetailNavigationKindFiles;
        URLString = [NSString stringWithFormat:@"cydia://package/%@/files",
                                               [_viewModel identity]];
    } else {
        return;
    }

dispatch:
    [delegate packageDetailController:self
              didSelectNavigationKind:navigationKind
                            URLString:URLString
                           identifier:identifier];
}

- (void)modifyButtonClicked {
    NSArray<CydiaPackageDetailModifyAction *> *actions([_viewModel modifyActions]);
    if ([actions count] == 1) {
        [self selectModifyAction:[actions objectAtIndex:0]];
        return;
    }
    UIAlertController *sheet([UIAlertController
        alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet]);
    for (CydiaPackageDetailModifyAction *action in actions) {
        NSString *key([action titleLocalizationKey]);
        NSString *title([key isEqualToString:@"ACCOUNTS"] ? CydiaAccountLocalize(key) : [key hasPrefix:@"PACKAGE_"] ? [[NSBundle mainBundle]
            localizedStringForKey:key value:key table:@"Actions"] : UCLocalizeEx(key));
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *selected) {
            [self selectModifyAction:action];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL")
                                              style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)selectModifyAction:(CydiaPackageDetailModifyAction *)action {
    if ([action kind] == CydiaPackageDetailModifyActionKindAccount) {
        [self showRepositoryAccount];
        return;
    }
    if ([action kind] != CydiaPackageDetailModifyActionKindVersions) {
        [_packageDelegate packageDetailController:self
                            didSelectModifyAction:action
                                     versionChoice:nil];
        return;
    }
    UIAlertController *sheet([UIAlertController
        alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet]);
    for (CydiaPackageDetailVersionChoice *choice in [action versions]) {
        NSMutableArray *details([NSMutableArray array]);
        if ([choice architectureCaption] != nil) [details addObject:[choice architectureCaption]];
        NSString *priority([[NSBundle mainBundle] localizedStringForKey:@"PACKAGE_PRIORITY"
            value:@"PACKAGE_PRIORITY" table:@"Actions"]);
        [details addObject:[NSString stringWithFormat:priority, (long)[choice priority]]];
        if ([choice candidate]) [details addObject:[[NSBundle mainBundle]
            localizedStringForKey:@"PACKAGE_CANDIDATE" value:@"PACKAGE_CANDIDATE" table:@"Actions"]];
        if ([choice installed]) [details addObject:UCLocalize("INSTALLED")];
        NSString *title([NSString stringWithFormat:@"%@ (%@)", [choice version],
            [details componentsJoinedByString:@", "]]);
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *selected) {
            [self.packageDelegate packageDetailController:self
                                    didSelectModifyAction:action
                                             versionChoice:choice];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL")
                                              style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
