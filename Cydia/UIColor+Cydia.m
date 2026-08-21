/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Cydia/UIColor+Cydia.h"
#import <objc/message.h>

static UIColor *RGBA8(NSUInteger red, NSUInteger green, NSUInteger blue, NSUInteger alpha) {
    return [UIColor colorWithRed:red / 255.0f
                           green:green / 255.0f
                            blue:blue / 255.0f
                           alpha:alpha / 255.0f];
}

static BOOL SupportsDynamicColors(void) {
    return [UIColor respondsToSelector:@selector(colorWithDynamicProvider:)] &&
        [UIColor respondsToSelector:@selector(labelColor)];
}

static UIColor *UIColorClassColor(SEL selector) {
    return ((UIColor *(*)(id, SEL))objc_msgSend)(UIColor.class, selector);
}

static UITraitCollection *CurrentTraitCollection(void) {
    if ([UITraitCollection respondsToSelector:@selector(currentTraitCollection)])
        return ((UITraitCollection *(*)(id, SEL))objc_msgSend)(
            UITraitCollection.class, @selector(currentTraitCollection));
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
        case CydiaColorRoleWarningLabel:
            return dark ? RGBA8(255, 214, 10, 255) : RGBA8(138, 75, 0, 255);
        case CydiaColorRoleErrorLabel:
            return dark ? RGBA8(255, 105, 97, 255) : RGBA8(176, 0, 32, 255);
    }
}

static UIColor *CustomDynamicColor(CydiaColorRole role) {
    UIColor *(^provider)(UITraitCollection *) = ^UIColor *(UITraitCollection *traits) {
        return FixedColor(role, InterfaceStyle(traits));
    };
    return ((UIColor *(*)(id, SEL, UIColor *(^)(UITraitCollection *)))objc_msgSend)(
        UIColor.class, @selector(colorWithDynamicProvider:), provider);
}

static UIColor *DynamicColor(CydiaColorRole role) {
    switch (role) {
        case CydiaColorRoleBackground:
            return UIColorClassColor(@selector(systemBackgroundColor));
        case CydiaColorRoleGroupedBackground:
            return UIColorClassColor(@selector(systemGroupedBackgroundColor));
        case CydiaColorRoleLabel:
            return UIColorClassColor(@selector(labelColor));
        case CydiaColorRoleSecondaryLabel:
            return UIColorClassColor(@selector(secondaryLabelColor));
        case CydiaColorRoleFolderLabel:
            return UIColorClassColor(@selector(systemGrayColor));
        case CydiaColorRoleCommercialLabel:
            return UIColorClassColor(@selector(systemPurpleColor));
        case CydiaColorRoleSeparator:
            return UIColorClassColor(@selector(separatorColor));
        case CydiaColorRoleAccent:
            return UIColorClassColor(@selector(systemBlueColor));
        case CydiaColorRoleErrorLabel:
            return UIColorClassColor(@selector(systemRedColor));
        case CydiaColorRoleSelectedLabel:
        case CydiaColorRoleCommercialSecondaryLabel:
        case CydiaColorRoleInstallingBackground:
        case CydiaColorRoleRemovingBackground:
        case CydiaColorRoleWarningLabel:
            return CustomDynamicColor(role);
    }
}

@implementation UIColor (CydiaAppearance)

+ (UIColor *)cydiaColorForRole:(CydiaColorRole)role {
    if (SupportsDynamicColors())
        return DynamicColor(role);
    return FixedColor(role, InterfaceStyle([UIScreen mainScreen].traitCollection));
}

+ (UIColor *)cydiaColorForRole:(CydiaColorRole)role
               traitCollection:(UITraitCollection *)traitCollection {
    if (SupportsDynamicColors()) {
        UITraitCollection *traits = traitCollection;
        if (traits == nil)
            traits = CurrentTraitCollection();
        UIColor *color = [self cydiaColorForRole:role];
        return ((UIColor *(*)(id, SEL, UITraitCollection *))objc_msgSend)(
            color, @selector(resolvedColorWithTraitCollection:), traits);
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

+ (UIColor *)cydiaWarningLabelColor {
    return [self cydiaColorForRole:CydiaColorRoleWarningLabel];
}

+ (UIColor *)cydiaErrorLabelColor {
    return [self cydiaColorForRole:CydiaColorRoleErrorLabel];
}

@end

BOOL CydiaColorAppearanceDidChange(UITraitCollection *current, UITraitCollection *previous) {
    if (previous == nil)
        return YES;
    if ([current respondsToSelector:@selector(hasDifferentColorAppearanceComparedToTraitCollection:)])
        return ((BOOL (*)(id, SEL, UITraitCollection *))objc_msgSend)(
            current,
            @selector(hasDifferentColorAppearanceComparedToTraitCollection:),
            previous);
    return current.userInterfaceStyle != previous.userInterfaceStyle;
}

void CydiaSetColor(CydiaColorRole role, UITraitCollection *traitCollection) {
    UIColor *color = [UIColor cydiaColorForRole:role traitCollection:traitCollection];
    [color set];
}
