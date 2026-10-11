/* Cydia Refurbished package depiction table cell.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_PackageDetailDepictionCell_H
#define Cydia_PackageDetailDepictionCell_H

#include "Cydia/PackageDepictionView.h"

@interface CydiaPackageDepictionCell : UITableViewCell
@property(nonatomic, strong, readonly) UIView *contentHost;
@property(nonatomic, strong, readonly) UIActivityIndicatorView *activityIndicator;
@property(nonatomic, strong, readonly) UILabel *loadingLabel;
@property(nonatomic, strong, readonly) UILabel *errorLabel;
@property(nonatomic, strong, readonly) UIStackView *loadingContainer;
@property(nonatomic, strong, readonly) UIStackView *errorContainer;
@property(nonatomic, strong, readonly) UIStackView *buttonContainer;
@property(nonatomic, strong, readonly) UIButton *retryButton;
@property(nonatomic, strong, readonly) UIButton *externalButton;
@property(nonatomic, strong, readonly) NSLayoutConstraint *contentHeightConstraint;
@property(nonatomic, strong) PackageDepictionView *depictionView;
- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier;
- (void)applyDepictionPresentation;
- (void)applyColorAppearance:(UITraitCollection *)traits;
- (void)updateAccessibilityElementsForDepictionState:
        (CydiaPackageDepictionViewState)state;
@end

#endif // Cydia_PackageDetailDepictionCell_H
