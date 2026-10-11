/* Cydia Refurbished package depiction table cell.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "Cydia/PackageDetailDepictionCell.h"

#include "Cydia/Appearance.h"
#include "CyteKit/Localize.h"

#include <algorithm>
#include <cmath>

@implementation CydiaPackageDepictionCell

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault
                      reuseIdentifier:reuseIdentifier]) != nil) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.accessibilityIdentifier = @"cydia.package.depiction.cell";
        self.isAccessibilityElement = NO;

        _contentHost = [[UIView alloc] init];
        _contentHost.translatesAutoresizingMaskIntoConstraints = NO;
        _contentHost.clipsToBounds = YES;
        [self.contentView addSubview:_contentHost];
        [NSLayoutConstraint activateConstraints:@[
            [_contentHost.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_contentHost.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_contentHost.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_contentHost.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];
        _contentHeightConstraint = [_contentHost.heightAnchor constraintEqualToConstant:52.0];
        _contentHeightConstraint.priority = UILayoutPriorityRequired;
        _contentHeightConstraint.active = YES;

        _activityIndicator = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        _activityIndicator.accessibilityIdentifier = @"cydia.package.depiction.loading.indicator";
        [_activityIndicator startAnimating];
        _loadingLabel = [[UILabel alloc] init];
        _loadingLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _loadingLabel.adjustsFontForContentSizeCategory = YES;
        _loadingLabel.text = UCLocalize("LOADING");
        _loadingLabel.accessibilityIdentifier = @"cydia.package.depiction.loading";

        _loadingContainer = [[UIStackView alloc]
            initWithArrangedSubviews:@[_activityIndicator, _loadingLabel]];
        _loadingContainer.translatesAutoresizingMaskIntoConstraints = NO;
        _loadingContainer.axis = UILayoutConstraintAxisHorizontal;
        _loadingContainer.alignment = UIStackViewAlignmentCenter;
        _loadingContainer.spacing = 9.0;
        _loadingContainer.accessibilityIdentifier = @"cydia.package.depiction.loading.container";
        [_contentHost addSubview:_loadingContainer];
        [NSLayoutConstraint activateConstraints:@[
            [_loadingContainer.centerXAnchor constraintEqualToAnchor:_contentHost.centerXAnchor],
            [_loadingContainer.centerYAnchor constraintEqualToAnchor:_contentHost.centerYAnchor],
            [_loadingContainer.leadingAnchor constraintGreaterThanOrEqualToAnchor:
                _contentHost.layoutMarginsGuide.leadingAnchor],
            [_loadingContainer.trailingAnchor constraintLessThanOrEqualToAnchor:
                _contentHost.layoutMarginsGuide.trailingAnchor],
        ]];

        _errorLabel = [[UILabel alloc] init];
        _errorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _errorLabel.adjustsFontForContentSizeCategory = YES;
        _errorLabel.numberOfLines = 0;
        _errorLabel.textAlignment = NSTextAlignmentCenter;
        _errorLabel.text = UCLocalize("UNABLE_TO_LOAD");
        _errorLabel.accessibilityIdentifier = @"cydia.package.depiction.error";

        _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _retryButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _retryButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        _retryButton.titleLabel.numberOfLines = 0;
        _retryButton.titleLabel.textAlignment = NSTextAlignmentCenter;
        [_retryButton setTitle:UCLocalize("RELOAD") forState:UIControlStateNormal];
        _retryButton.accessibilityIdentifier = @"cydia.package.depiction.retry";
        [_retryButton.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;

        _externalButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _externalButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _externalButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        _externalButton.titleLabel.numberOfLines = 0;
        _externalButton.titleLabel.textAlignment = NSTextAlignmentCenter;
        [_externalButton setTitle:UCLocalize("MORE_INFORMATION")
                         forState:UIControlStateNormal];
        _externalButton.accessibilityIdentifier = @"cydia.package.depiction.external";
        [_externalButton.heightAnchor constraintGreaterThanOrEqualToConstant:44.0].active = YES;

        _buttonContainer = [[UIStackView alloc]
            initWithArrangedSubviews:@[_retryButton, _externalButton]];
        _buttonContainer.axis = UILayoutConstraintAxisHorizontal;
        _buttonContainer.alignment = UIStackViewAlignmentFill;
        _buttonContainer.distribution = UIStackViewDistributionFillEqually;
        _buttonContainer.spacing = 12.0;

        _errorContainer = [[UIStackView alloc]
            initWithArrangedSubviews:@[_errorLabel, _buttonContainer]];
        _errorContainer.translatesAutoresizingMaskIntoConstraints = NO;
        _errorContainer.axis = UILayoutConstraintAxisVertical;
        _errorContainer.alignment = UIStackViewAlignmentFill;
        _errorContainer.spacing = 4.0;
        _errorContainer.accessibilityIdentifier = @"cydia.package.depiction.error.container";
        _errorContainer.hidden = YES;
        [_contentHost addSubview:_errorContainer];
        [NSLayoutConstraint activateConstraints:@[
            [_errorContainer.leadingAnchor constraintEqualToAnchor:
                _contentHost.layoutMarginsGuide.leadingAnchor],
            [_errorContainer.trailingAnchor constraintEqualToAnchor:
                _contentHost.layoutMarginsGuide.trailingAnchor],
            [_errorContainer.topAnchor constraintEqualToAnchor:
                _contentHost.layoutMarginsGuide.topAnchor],
            [_errorContainer.bottomAnchor constraintEqualToAnchor:
                _contentHost.layoutMarginsGuide.bottomAnchor],
        ]];
    }
    return self;
}

- (void)setDepictionView:(PackageDepictionView *)depictionView {
    if (_depictionView == depictionView)
        return;
    [_depictionView removeFromSuperview];
    _depictionView = depictionView;
    if (_depictionView != nil) {
        _depictionView.translatesAutoresizingMaskIntoConstraints = NO;
        [_contentHost insertSubview:_depictionView atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [_depictionView.leadingAnchor constraintEqualToAnchor:_contentHost.leadingAnchor],
            [_depictionView.trailingAnchor constraintEqualToAnchor:_contentHost.trailingAnchor],
            [_depictionView.topAnchor constraintEqualToAnchor:_contentHost.topAnchor],
            [_depictionView.bottomAnchor constraintEqualToAnchor:_contentHost.bottomAnchor],
        ]];
    }
    [self applyDepictionPresentation];
}

- (void)applyDepictionPresentation {
    CydiaPackageDepictionViewState state([_depictionView state]);
    BOOL failed(state == CydiaPackageDepictionViewStateFailed ||
                state == CydiaPackageDepictionViewStatePathologicalContent);
    BOOL loaded(state == CydiaPackageDepictionViewStateLoaded);
    _loadingContainer.hidden = failed || loaded;
    _errorContainer.hidden = !failed;
    _depictionView.hidden = !loaded;
    if (failed || loaded)
        [_activityIndicator stopAnimating];
    else
        [_activityIndicator startAnimating];
    if (loaded)
        _contentHeightConstraint.constant = std::max<CGFloat>(44.0, [_depictionView contentHeight]);
    else if (failed) {
        CGFloat fitting([_errorContainer systemLayoutSizeFittingSize:
            UILayoutFittingCompressedSize].height + _contentHost.layoutMargins.top +
            _contentHost.layoutMargins.bottom);
        _contentHeightConstraint.constant = std::max<CGFloat>(108.0, std::ceil(fitting));
    } else {
        CGFloat fitting([_loadingContainer systemLayoutSizeFittingSize:
            UILayoutFittingCompressedSize].height + 16.0);
        _contentHeightConstraint.constant = std::max<CGFloat>(52.0, std::ceil(fitting));
    }
    [self updateAccessibilityElementsForDepictionState:state];
}

- (void)updateAccessibilityElementsForDepictionState:
        (CydiaPackageDepictionViewState)state {
    /* Do not let UITableView synthesize one blank UITableTextAccessibilityElement
     * for the whole loaded depiction. Expose the native depiction container and
     * its web-content accessibility descendants; expose only the concrete
     * loading/error controls for the other states. */
    if (state == CydiaPackageDepictionViewStateLoaded)
        self.accessibilityElements = @[_depictionView];
    else if (state == CydiaPackageDepictionViewStateFailed ||
             state == CydiaPackageDepictionViewStatePathologicalContent)
        self.accessibilityElements = @[_errorLabel, _retryButton, _externalButton];
    else
        self.accessibilityElements = @[_loadingLabel];
}

- (void)applyColorAppearance:(UITraitCollection *)traits {
    UIColor *background([UIColor cydiaColorForRole:CydiaColorRoleCellBackground
                                    traitCollection:traits]);
    self.backgroundColor = background;
    _contentHost.backgroundColor = background;
    _loadingLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                          traitCollection:traits];
    _errorLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleErrorLabel
                                        traitCollection:traits];
    _activityIndicator.color = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                           traitCollection:traits];
    _buttonContainer.axis = UIContentSizeCategoryIsAccessibilityCategory(
        traits.preferredContentSizeCategory) ? UILayoutConstraintAxisVertical :
                                               UILayoutConstraintAxisHorizontal;
    [self applyDepictionPresentation];
}

@end
