/* Cydia Refurbished native progress event cell.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ProgressEventCell.h"

#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"

@implementation CydiaProgressEventCell {
    UILabel *messageLabel_;
    UILabel *metadataLabel_;
    CydiaProgressEventKind kind_;
}

- (instancetype) initWithStyle:(UITableViewCellStyle)style
                reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) != nil) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.preservesSuperviewLayoutMargins = YES;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitStaticText;

        messageLabel_ = [[UILabel alloc] init];
        messageLabel_.translatesAutoresizingMaskIntoConstraints = NO;
        messageLabel_.numberOfLines = 0;
        messageLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        messageLabel_.adjustsFontForContentSizeCategory = YES;
        messageLabel_.isAccessibilityElement = NO;
        messageLabel_.accessibilityIdentifier = @"cydia.progress.event.message";
        [self.contentView addSubview:messageLabel_];

        metadataLabel_ = [[UILabel alloc] init];
        metadataLabel_.translatesAutoresizingMaskIntoConstraints = NO;
        metadataLabel_.numberOfLines = 0;
        metadataLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        metadataLabel_.adjustsFontForContentSizeCategory = YES;
        metadataLabel_.isAccessibilityElement = NO;
        [self.contentView addSubview:metadataLabel_];

        UILayoutGuide *margins(self.contentView.layoutMarginsGuide);
        [NSLayoutConstraint activateConstraints:@[
            [messageLabel_.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [messageLabel_.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [messageLabel_.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [metadataLabel_.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [metadataLabel_.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [metadataLabel_.topAnchor constraintEqualToAnchor:messageLabel_.bottomAnchor constant:3.0],
            [metadataLabel_.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        ]];

        [self applyColorAppearance];
    }
    return self;
}

- (UIFont *) messageFontForKind:(CydiaProgressEventKind)kind {
    UIFont *font([UIFont preferredFontForTextStyle:UIFontTextStyleBody
                        compatibleWithTraitCollection:self.traitCollection]);
    if (kind != CydiaProgressEventKindWarning && kind != CydiaProgressEventKindError)
        return font;
    UIFontDescriptor *descriptor([[font fontDescriptor]
        fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold]);
    return descriptor == nil ? font : [UIFont fontWithDescriptor:descriptor size:0];
}

- (void) applyTypography {
    messageLabel_.font = [self messageFontForKind:kind_];
    metadataLabel_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1
                                  compatibleWithTraitCollection:self.traitCollection];
}

- (void) configureWithEvent:(CydiaProgressPresentationEvent *)event {
    kind_ = event.kind;
    switch (event.kind) {
        case CydiaProgressEventKindWarning:
        case CydiaProgressEventKindError:
            messageLabel_.text = event.accessibilityLabel;
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
    metadataLabel_.text = metadataText;
    metadataLabel_.hidden = [metadataText length] == 0;

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
    if (kind_ == CydiaProgressEventKindWarning)
        messageRole = CydiaColorRoleWarningLabel;
    else if (kind_ == CydiaProgressEventKindError)
        messageRole = CydiaColorRoleErrorLabel;
    messageLabel_.textColor = [UIColor cydiaColorForRole:messageRole
                                         traitCollection:traits];
    metadataLabel_.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                          traitCollection:traits];
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
