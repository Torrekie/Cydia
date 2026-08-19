/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#ifndef Cydia_UIColor_Cydia_H
#define Cydia_UIColor_Cydia_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/* Semantic roles used by Cydia-owned UIKit and custom drawing.  Keeping the
 * role at the call site lets iOS 12 resolve a color from the owning view's
 * trait collection instead of relying on a process-global appearance value. */
typedef NS_ENUM(NSUInteger, CydiaColorRole) {
    CydiaColorRoleBackground,
    CydiaColorRoleGroupedBackground,
    CydiaColorRoleLabel,
    CydiaColorRoleSecondaryLabel,
    CydiaColorRoleSelectedLabel,
    CydiaColorRoleFolderLabel,
    CydiaColorRoleCommercialLabel,
    CydiaColorRoleCommercialSecondaryLabel,
    CydiaColorRoleInstallingBackground,
    CydiaColorRoleRemovingBackground,
    CydiaColorRoleSeparator,
    CydiaColorRoleAccent,
};

@interface UIColor (CydiaAppearance)

/* Returns a native dynamic UIColor on iOS 13 and newer.  On iOS 12 it uses
 * the current trait collection and returns the calibrated concrete color. */
+ (UIColor *)cydiaColorForRole:(CydiaColorRole)role;

/* Resolve a semantic role for a specific view or drawing context.  Custom
 * drawing should use this form so iOS 12 dark traits supplied by the runtime
 * or an appearance tweak are handled without global state. */
+ (UIColor *)cydiaColorForRole:(CydiaColorRole)role
               traitCollection:(nullable UITraitCollection *)traitCollection;

@property(class, nonatomic, readonly) UIColor *cydiaBackgroundColor;
@property(class, nonatomic, readonly) UIColor *cydiaGroupedBackgroundColor;
@property(class, nonatomic, readonly) UIColor *cydiaLabelColor;
@property(class, nonatomic, readonly) UIColor *cydiaSecondaryLabelColor;
@property(class, nonatomic, readonly) UIColor *cydiaSelectedLabelColor;
@property(class, nonatomic, readonly) UIColor *cydiaFolderLabelColor;
@property(class, nonatomic, readonly) UIColor *cydiaCommercialLabelColor;
@property(class, nonatomic, readonly) UIColor *cydiaCommercialSecondaryLabelColor;
@property(class, nonatomic, readonly) UIColor *cydiaInstallingBackgroundColor;
@property(class, nonatomic, readonly) UIColor *cydiaRemovingBackgroundColor;
@property(class, nonatomic, readonly) UIColor *cydiaSeparatorColor;
@property(class, nonatomic, readonly) UIColor *cydiaAccentColor;

@end

/* Includes accessibility contrast and gamut changes on iOS 13+, and retains
 * the iOS 12 user-interface-style comparison needed by custom draw views. */
FOUNDATION_EXPORT BOOL CydiaColorAppearanceDidChange(UITraitCollection *current,
                                                      UITraitCollection * _Nullable previous);

/* Apply a resolved role to the current UIKit drawing context.  This avoids
 * converting a dynamic UIColor to a long-lived CGColor. */
FOUNDATION_EXPORT void CydiaSetColor(CydiaColorRole role,
                                     UITraitCollection * _Nullable traitCollection);

NS_ASSUME_NONNULL_END

#endif // Cydia_UIColor_Cydia_H
