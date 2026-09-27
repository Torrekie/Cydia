/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Refurbished work Copyright (C) 2026    Torrekie
 */

#include "Cydia/HomeSplitDisclosure.h"

#include <UIKit/UIKit.h>

UITableViewCell *CydiaHomeSystemDisclosureAccessory(void) {
    UITableViewCell *cell([[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = NO;
    cell.isAccessibilityElement = NO;
    cell.accessibilityElementsHidden = YES;
    cell.opaque = NO;
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    /* A detached donor has no table-provided trailing margin. */
    cell.preservesSuperviewLayoutMargins = NO;
    cell.layoutMargins = UIEdgeInsetsMake(0, 16, 0, 16);
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        cell.automaticallyUpdatesBackgroundConfiguration = NO;
        cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    }
#endif
    return cell;
}

void CydiaHomeApplySplitButtonInsets(UIButton *button) {
    if (button == nil)
        return;
    BOOL rightToLeft(button.effectiveUserInterfaceLayoutDirection ==
        UIUserInterfaceLayoutDirectionRightToLeft);
    /* These are physical insets on iOS 12, so mirror them explicitly. */
    UIEdgeInsets contentInsets(rightToLeft ?
        UIEdgeInsetsMake(7, 34, 7, 15) : UIEdgeInsetsMake(7, 15, 7, 34));
    UIEdgeInsets titleInsets(rightToLeft ?
        UIEdgeInsetsMake(0, -15, 0, 15) : UIEdgeInsetsMake(0, 15, 0, -15));
    if (!UIEdgeInsetsEqualToEdgeInsets(button.contentEdgeInsets, contentInsets))
        button.contentEdgeInsets = contentInsets;
    if (!UIEdgeInsetsEqualToEdgeInsets(button.titleEdgeInsets, titleInsets))
        button.titleEdgeInsets = titleInsets;
}
