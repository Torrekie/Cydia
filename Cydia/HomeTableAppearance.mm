/* Cydia - iPhone UIKit Front-End for Debian APT
 * Refurbished work Copyright (C) 2026    Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/HomeTableAppearance.h"

/* UITableViewStyleGrouped may install an internal, trait-bound background
 * view after -cellForRowAtIndexPath:.  Keeping only cell.backgroundColor then
 * leaves that view stuck in the previous appearance (the root/table can be
 * light while the rows remain dark).  iOS 14's backgroundConfiguration takes
 * precedence over backgroundView, so update that configuration when present;
 * older systems retain the app-owned plain surface fallback. */
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
    cell.contentView.backgroundColor = background;

#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        UIBackgroundConfiguration *configuration(cell.backgroundConfiguration);
        if (configuration == nil)
            configuration = [UIBackgroundConfiguration clearConfiguration];
        /* A stale transformer can resolve the previously active dark color
         * after this method returns.  Use the concrete trait-resolved color
         * and make the configuration honor it as-is. */
        configuration.backgroundColorTransformer = nil;
        configuration.backgroundColor = background;
        cell.backgroundConfiguration = configuration;
        return;
    }
#endif

    UIView *surface(cell.backgroundView);
    if (surface == nil || surface.tag != 0xC1D1A) {
        surface = [[UIView alloc] init];
        surface.tag = 0xC1D1A;
        surface.userInteractionEnabled = NO;
        cell.backgroundView = surface;
    }
    surface.backgroundColor = background;
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
