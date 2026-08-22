/* Cydia Refurbished native progress event cell.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ProgressEventCell.h"

#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"

@implementation CydiaProgressEventCell {
    UILabel *markerLabel_;
    UILabel *messageLabel_;
    UIStackView *contentStackView_;
    CydiaProgressEventKind kind_;
}

- (instancetype) initWithStyle:(UITableViewCellStyle)style
                reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) != nil) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.preservesSuperviewLayoutMargins = NO;
        self.layoutMargins = UIEdgeInsetsMake(3.0, 9.0, 3.0, 9.0);
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitStaticText;

        markerLabel_ = [[UILabel alloc] init];
        markerLabel_.numberOfLines = 1;
        markerLabel_.textAlignment = NSTextAlignmentCenter;
        markerLabel_.isAccessibilityElement = NO;
        markerLabel_.accessibilityIdentifier = @"cydia.progress.event.marker";
        markerLabel_.hidden = YES;
        [markerLabel_ setContentHuggingPriority:UILayoutPriorityRequired
                                       forAxis:UILayoutConstraintAxisHorizontal];
        [markerLabel_ setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                    forAxis:UILayoutConstraintAxisHorizontal];

        messageLabel_ = [[UILabel alloc] init];
        messageLabel_.numberOfLines = 0;
        messageLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        messageLabel_.adjustsFontForContentSizeCategory = YES;
        messageLabel_.isAccessibilityElement = NO;
        messageLabel_.accessibilityIdentifier = @"cydia.progress.event.message";
        [messageLabel_ setContentHuggingPriority:UILayoutPriorityDefaultLow
                                        forAxis:UILayoutConstraintAxisHorizontal];

        contentStackView_ = [[UIStackView alloc]
            initWithArrangedSubviews:@[markerLabel_, messageLabel_]];
        contentStackView_.translatesAutoresizingMaskIntoConstraints = NO;
        contentStackView_.axis = UILayoutConstraintAxisHorizontal;
        contentStackView_.alignment = UIStackViewAlignmentFirstBaseline;
        contentStackView_.spacing = 4.0;
        [self.contentView addSubview:contentStackView_];

        UILayoutGuide *margins(self.contentView.layoutMarginsGuide);
        [NSLayoutConstraint activateConstraints:@[
            [contentStackView_.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [contentStackView_.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [contentStackView_.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [contentStackView_.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        ]];

        [self applyColorAppearance];
    }
    return self;
}

- (UIFont *) messageFontForKind:(CydiaProgressEventKind)kind {
    UIFont *font([UIFont preferredFontForTextStyle:UIFontTextStyleCaption1
                        compatibleWithTraitCollection:self.traitCollection]);
    if (kind != CydiaProgressEventKindStatus)
        return font;
    UIFontDescriptor *descriptor([[font fontDescriptor]
        fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold]);
    return descriptor == nil ? font : [UIFont fontWithDescriptor:descriptor size:0];
}

- (void) applyTypography {
    messageLabel_.font = [self messageFontForKind:kind_];
    markerLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1
                                compatibleWithTraitCollection:self.traitCollection];
}

- (void) configureWithEvent:(CydiaProgressPresentationEvent *)event {
    kind_ = event.kind;
    markerLabel_.hidden = YES;
    markerLabel_.text = nil;
    switch (event.kind) {
        case CydiaProgressEventKindWarning:
            markerLabel_.text = @"⚠︎";
            markerLabel_.hidden = NO;
            messageLabel_.text = event.displayMessage;
        break;
        case CydiaProgressEventKindError:
            markerLabel_.text = @"✖︎";
            markerLabel_.hidden = NO;
            messageLabel_.text = event.displayMessage;
        break;
        case CydiaProgressEventKindUnknown:
            messageLabel_.text = [event.rawType length] == 0 ? event.displayMessage :
                [NSString stringWithFormat:UCLocalize("COLON_DELIMITED"),
                    event.rawType, event.displayMessage];
        break;
        case CydiaProgressEventKindInformation:
        case CydiaProgressEventKindStatus:
            messageLabel_.text = event.displayMessage;
        break;
    }
    [self applyTypography];

    NSMutableArray<NSString *> *metadata([NSMutableArray arrayWithCapacity:2]);
    if ([event.packageIdentifier length] != 0)
        [metadata addObject:event.packageIdentifier];
    if ([event.version length] != 0)
        [metadata addObject:event.version];
    NSString *metadataText([metadata componentsJoinedByString:@" · "]);

    self.accessibilityLabel = event.accessibilityLabel;
    self.accessibilityValue = [metadataText length] == 0 ? nil : metadataText;
    self.accessibilityIdentifier = [event.packageIdentifier length] == 0 ?
        @"cydia.progress.event" :
        [@"cydia.progress.event." stringByAppendingString:event.packageIdentifier];
    [self applyColorAppearance];
}

- (void) applyColorAppearance {
    UITraitCollection *traits(self.traitCollection);
    self.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground
                                      traitCollection:traits];
    self.contentView.backgroundColor = self.backgroundColor;
    CydiaColorRole messageRole(CydiaColorRoleLabel);
    if (kind_ == CydiaProgressEventKindInformation)
        messageRole = CydiaColorRoleSecondaryLabel;
    else if (kind_ == CydiaProgressEventKindWarning)
        messageRole = CydiaColorRoleWarningLabel;
    else if (kind_ == CydiaProgressEventKindError)
        messageRole = CydiaColorRoleErrorLabel;
    messageLabel_.textColor = [UIColor cydiaColorForRole:messageRole
                                         traitCollection:traits];
    markerLabel_.textColor = messageLabel_.textColor;
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection))
        [self applyColorAppearance];
    if (previousTraitCollection == nil ||
        ![self.traitCollection.preferredContentSizeCategory isEqualToString:
            previousTraitCollection.preferredContentSizeCategory]) {
        [self applyTypography];
        [self.contentView setNeedsLayout];
    }
}

@end
