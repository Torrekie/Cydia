/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#import "Cydia/UIColor+Cydia.h"

static UIColor *RGBA8(NSUInteger red, NSUInteger green, NSUInteger blue, NSUInteger alpha) {
    return [UIColor colorWithRed:red / 255.0f
                           green:green / 255.0f
                            blue:blue / 255.0f
                           alpha:alpha / 255.0f];
}

static UITraitCollection *CurrentTraitCollection(void) {
    if (@available(iOS 13.0, *))
        return [UITraitCollection currentTraitCollection];
    return [UIScreen mainScreen].traitCollection;
}

static UIUserInterfaceStyle InterfaceStyle(UITraitCollection *traits) {
    if (traits == nil)
        traits = CurrentTraitCollection();
    return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
}

static UIColor *FixedColor(CydiaColorRole role, UIUserInterfaceStyle style) {
    const BOOL dark = style == UIUserInterfaceStyleDark;
    switch (role) {
        case CydiaColorRoleBackground:
            return dark ? RGBA8(0, 0, 0, 255) : RGBA8(255, 255, 255, 255);
        case CydiaColorRoleGroupedBackground:
            return dark ? RGBA8(0, 0, 0, 255) : RGBA8(239, 239, 244, 255);
        case CydiaColorRoleLabel:
            return dark ? RGBA8(255, 255, 255, 255) : RGBA8(0, 0, 0, 255);
        case CydiaColorRoleSecondaryLabel:
            return dark ? RGBA8(235, 235, 245, 153) : RGBA8(60, 60, 67, 153);
        case CydiaColorRoleSelectedLabel:
            return RGBA8(255, 255, 255, 255);
        case CydiaColorRoleFolderLabel:
            return RGBA8(142, 142, 147, 255);
        case CydiaColorRoleCommercialLabel:
            return dark ? RGBA8(191, 90, 242, 255) : RGBA8(175, 82, 222, 255);
        case CydiaColorRoleCommercialSecondaryLabel:
            return dark ? RGBA8(218, 164, 247, 255) : RGBA8(102, 102, 204, 255);
        case CydiaColorRoleInstallingBackground:
            return dark ? RGBA8(20, 55, 32, 255) : RGBA8(224, 255, 224, 255);
        case CydiaColorRoleRemovingBackground:
            return dark ? RGBA8(61, 23, 23, 255) : RGBA8(255, 224, 224, 255);
        case CydiaColorRoleSeparator:
            return dark ? RGBA8(84, 84, 88, 153) : RGBA8(60, 60, 67, 74);
        case CydiaColorRoleAccent:
            return dark ? RGBA8(10, 132, 255, 255) : RGBA8(0, 122, 255, 255);
    }
}

static UIColor *CustomDynamicColor(CydiaColorRole role) API_AVAILABLE(ios(13.0)) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return FixedColor(role, InterfaceStyle(traits));
    }];
}

static UIColor *DynamicColor(CydiaColorRole role) API_AVAILABLE(ios(13.0)) {
    switch (role) {
        case CydiaColorRoleBackground:
            return UIColor.systemBackgroundColor;
        case CydiaColorRoleGroupedBackground:
            return UIColor.systemGroupedBackgroundColor;
        case CydiaColorRoleLabel:
            return UIColor.labelColor;
        case CydiaColorRoleSecondaryLabel:
            return UIColor.secondaryLabelColor;
        case CydiaColorRoleFolderLabel:
            return UIColor.systemGrayColor;
        case CydiaColorRoleCommercialLabel:
            return UIColor.systemPurpleColor;
        case CydiaColorRoleSeparator:
            return UIColor.separatorColor;
        case CydiaColorRoleAccent:
            return UIColor.systemBlueColor;
        case CydiaColorRoleSelectedLabel:
        case CydiaColorRoleCommercialSecondaryLabel:
        case CydiaColorRoleInstallingBackground:
        case CydiaColorRoleRemovingBackground:
            return CustomDynamicColor(role);
    }
}

@implementation UIColor (CydiaAppearance)

+ (UIColor *)cydiaColorForRole:(CydiaColorRole)role {
    if (@available(iOS 13.0, *))
        return DynamicColor(role);
    return FixedColor(role, InterfaceStyle([UIScreen mainScreen].traitCollection));
}

+ (UIColor *)cydiaColorForRole:(CydiaColorRole)role
               traitCollection:(UITraitCollection *)traitCollection {
    if (@available(iOS 13.0, *)) {
        UITraitCollection *traits = traitCollection;
        if (traits == nil)
            traits = CurrentTraitCollection();
        return [[self cydiaColorForRole:role] resolvedColorWithTraitCollection:traits];
    }
    return FixedColor(role, InterfaceStyle(traitCollection));
}

+ (UIColor *)cydiaBackgroundColor {
    return [self cydiaColorForRole:CydiaColorRoleBackground];
}

+ (UIColor *)cydiaGroupedBackgroundColor {
    return [self cydiaColorForRole:CydiaColorRoleGroupedBackground];
}

+ (UIColor *)cydiaLabelColor {
    return [self cydiaColorForRole:CydiaColorRoleLabel];
}

+ (UIColor *)cydiaSecondaryLabelColor {
    return [self cydiaColorForRole:CydiaColorRoleSecondaryLabel];
}

+ (UIColor *)cydiaSelectedLabelColor {
    return [self cydiaColorForRole:CydiaColorRoleSelectedLabel];
}

+ (UIColor *)cydiaFolderLabelColor {
    return [self cydiaColorForRole:CydiaColorRoleFolderLabel];
}

+ (UIColor *)cydiaCommercialLabelColor {
    return [self cydiaColorForRole:CydiaColorRoleCommercialLabel];
}

+ (UIColor *)cydiaCommercialSecondaryLabelColor {
    return [self cydiaColorForRole:CydiaColorRoleCommercialSecondaryLabel];
}

+ (UIColor *)cydiaInstallingBackgroundColor {
    return [self cydiaColorForRole:CydiaColorRoleInstallingBackground];
}

+ (UIColor *)cydiaRemovingBackgroundColor {
    return [self cydiaColorForRole:CydiaColorRoleRemovingBackground];
}

+ (UIColor *)cydiaSeparatorColor {
    return [self cydiaColorForRole:CydiaColorRoleSeparator];
}

+ (UIColor *)cydiaAccentColor {
    return [self cydiaColorForRole:CydiaColorRoleAccent];
}

@end

BOOL CydiaColorAppearanceDidChange(UITraitCollection *current, UITraitCollection *previous) {
    if (previous == nil)
        return YES;
    if (@available(iOS 13.0, *))
        return [current hasDifferentColorAppearanceComparedToTraitCollection:previous];
    return current.userInterfaceStyle != previous.userInterfaceStyle;
}

void CydiaSetColor(CydiaColorRole role, UITraitCollection *traitCollection) {
    UIColor *color = [UIColor cydiaColorForRole:role traitCollection:traitCollection];
    [color set];
}
