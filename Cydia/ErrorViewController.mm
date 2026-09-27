/* Cydia Refurbished native error presentation.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Cydia/ErrorViewController.h"

#import "Cydia/Appearance.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"

@interface ErrorViewController ()
@property(nonatomic, strong, readwrite) CydiaErrorViewModel *viewModel;
@property(nonatomic, weak) id<ErrorViewControllerDelegate> delegate;
@property(nonatomic, readwrite, getter=isDetailsVisible) BOOL detailsVisible;
@property(nonatomic, readwrite, getter=isRetryAvailable) BOOL retryAvailable;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *summaryLabel;
@property(nonatomic, strong) UILabel *detailsLabel;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UIButton *detailsButton;
@end


@implementation ErrorViewController

- (instancetype)initWithViewModel:(CydiaErrorViewModel *)viewModel
                   retryAvailable:(BOOL)retryAvailable
                          delegate:(id<ErrorViewControllerDelegate>)delegate {
    if (![viewModel isKindOfClass:[CydiaErrorViewModel class]])
        return nil;
    if ((self = [super init]) != nil) {
        _viewModel = viewModel;
        _retryAvailable = retryAvailable;
        _delegate = delegate;
        self.title = UCLocalize("NETWORK_ERROR");
    }
    return self;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark)
        return UIStatusBarStyleLightContent;
    if (@available(iOS 13.0, *))
        return UIStatusBarStyleDarkContent;
    return UIStatusBarStyleDefault;
}

- (void)loadView {
    UIView *root([[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds]);
    root.accessibilityViewIsModal = YES;
    self.view = root;

    UIScrollView *scroll([[UIScrollView alloc] init]);
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = NO;
    scroll.accessibilityIdentifier = @"native-error.scroll";
    [root addSubview:scroll];

    UIStackView *stack([[UIStackView alloc] init]);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12.0;
    [scroll addSubview:stack];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.numberOfLines = 0;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.text = UCLocalize("UNABLE_TO_LOAD");
    _titleLabel.accessibilityIdentifier = @"native-error.title";
    _titleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    [stack addArrangedSubview:_titleLabel];

    _summaryLabel = [[UILabel alloc] init];
    _summaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _summaryLabel.adjustsFontForContentSizeCategory = YES;
    _summaryLabel.numberOfLines = 0;
    _summaryLabel.textAlignment = NSTextAlignmentCenter;
    _summaryLabel.text = _viewModel.summary;
    _summaryLabel.accessibilityIdentifier = @"native-error.summary";
    [stack addArrangedSubview:_summaryLabel];

    _detailsLabel = [[UILabel alloc] init];
    _detailsLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _detailsLabel.adjustsFontForContentSizeCategory = YES;
    _detailsLabel.numberOfLines = 0;
    _detailsLabel.textAlignment = NSTextAlignmentCenter;
    _detailsLabel.text = _viewModel.details;
    _detailsLabel.hidden = YES;
    _detailsLabel.accessibilityIdentifier = @"native-error.details";
    [stack addArrangedSubview:_detailsLabel];

    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _retryButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _retryButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    [_retryButton setTitle:UCLocalize("RELOAD") forState:UIControlStateNormal];
    [_retryButton addTarget:self action:@selector(retryButtonClicked)
        forControlEvents:UIControlEventTouchUpInside];
    _retryButton.hidden = !_retryAvailable;
    _retryButton.accessibilityIdentifier = @"native-error.retry";
    [stack addArrangedSubview:_retryButton];

    _detailsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _detailsButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _detailsButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    [_detailsButton setTitle:UCLocalize("MORE_INFORMATION")
        forState:UIControlStateNormal];
    [_detailsButton addTarget:self action:@selector(detailsButtonClicked)
        forControlEvents:UIControlEventTouchUpInside];
    _detailsButton.hidden = !_viewModel.hasDetails;
    _detailsButton.accessibilityIdentifier = @"native-error.more-information";
    [stack addArrangedSubview:_detailsButton];

    for (UIView *item in @[
            _titleLabel, _summaryLabel, _detailsLabel, _retryButton, _detailsButton])
        [item setContentHuggingPriority:UILayoutPriorityRequired
            forAxis:UILayoutConstraintAxisVertical];

    UILayoutGuide *safe(root.safeAreaLayoutGuide);
    UILayoutGuide *content(scroll.contentLayoutGuide);
    UILayoutGuide *frame(scroll.frameLayoutGuide);
    NSLayoutConstraint *verticalCenter([stack.centerYAnchor
        constraintEqualToAnchor:frame.centerYAnchor]);
    verticalCenter.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *top([stack.topAnchor
        constraintEqualToAnchor:content.topAnchor constant:32.0]);
    NSLayoutConstraint *bottom([stack.bottomAnchor
        constraintEqualToAnchor:content.bottomAnchor constant:-32.0]);
    top.priority = UILayoutPriorityDefaultLow;
    bottom.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor
            constant:24.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor
            constant:-24.0],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor
            constant:32.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor
            constant:-32.0],
        [stack.centerXAnchor constraintEqualToAnchor:frame.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:414.0],
        [content.widthAnchor constraintEqualToAnchor:frame.widthAnchor],
        [content.heightAnchor constraintGreaterThanOrEqualToAnchor:frame.heightAnchor],
        [_retryButton.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
        [_detailsButton.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
        top,
        bottom,
        verticalCenter,
    ]];

    [self applyColorAppearance];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous))
        [self applyColorAppearance];
}

- (void)applyColorAppearance {
    UITraitCollection *traits(self.traitCollection);
    UIColor *label([UIColor cydiaColorForRole:CydiaColorRoleLabel
        traitCollection:traits]);
    UIColor *accent([UIColor cydiaColorForRole:CydiaColorRoleAccent
        traitCollection:traits]);
    self.view.backgroundColor = [UIColor
        cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:traits];
    _titleLabel.textColor = label;
    _summaryLabel.textColor = label;
    _detailsLabel.textColor = [UIColor
        cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:traits];
    _retryButton.tintColor = accent;
    _detailsButton.tintColor = accent;
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)retryButtonClicked {
    if (!_retryAvailable)
        return;
    [_delegate errorViewControllerDidRequestRetry:self];
}

- (void)detailsButtonClicked {
    if (!_viewModel.hasDetails)
        return;
    self.detailsVisible = !self.detailsVisible;
    _detailsLabel.hidden = !self.detailsVisible;
    _detailsButton.accessibilityValue = self.detailsVisible ?
        _viewModel.details : nil;
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,
        self.detailsVisible ? _detailsLabel : _detailsButton);
}

@end
