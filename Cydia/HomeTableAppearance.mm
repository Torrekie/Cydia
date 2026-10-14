/* Cydia - iPhone UIKit Front-End for Debian APT
 * Refurbished work Copyright (C) 2026    Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/HomeTableAppearance.h"

/* Own only the resting surface. Opaque content or a fixed background
 * configuration masks UIKit's selected background and its press/fade states.
 * Assigning backgroundView also clears backgroundConfiguration on iOS 14+. */
void HomeApplyCellSurface(UITableViewCell *cell,
                          CydiaColorRole role,
                          UITraitCollection *traits) {
    if (cell == nil)
        return;
    UIColor *background([UIColor cydiaColorForRole:role
                                   traitCollection:traits]);
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle style(traits.userInterfaceStyle);
        if (style != UIUserInterfaceStyleUnspecified)
            cell.overrideUserInterfaceStyle = style;
    }
#endif
    cell.backgroundColor = background;
    cell.contentView.backgroundColor = UIColor.clearColor;

    UIView *surface(cell.backgroundView);
    if (surface == nil || surface.tag != 0xC1D1A) {
        surface = [[UIView alloc] init];
        surface.tag = 0xC1D1A;
        surface.userInteractionEnabled = NO;
    }
    surface.backgroundColor = background;
    cell.backgroundView = surface;
}

void HomeApplyTableSurface(UITableView *table, UIColor *background,
                           UITraitCollection *traits) {
    if (table == nil || background == nil)
        return;
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle style(traits.userInterfaceStyle);
        if (style != UIUserInterfaceStyleUnspecified)
            table.overrideUserInterfaceStyle = style;
    }
#endif
    table.backgroundColor = background;
    UIView *surface(table.backgroundView);
    if (surface == nil || surface.tag != 0xC1D1B) {
        surface = [[UIView alloc] init];
        surface.tag = 0xC1D1B;
        surface.userInteractionEnabled = NO;
        table.backgroundView = surface;
    }
    surface.backgroundColor = background;
}
