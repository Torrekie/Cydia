/* Cydia - iPhone UIKit Front-End for Debian APT
 * Refurbished work Copyright (C) 2026    Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_HomeTableAppearance_H
#define Cydia_HomeTableAppearance_H

#include "Cydia/UIColor+Cydia.h"

/* Refresh the grouped table and row surfaces using the owning window traits. */
void HomeApplyCellSurface(UITableViewCell *cell, CydiaColorRole role,
                          UITraitCollection *traits);
void HomeApplyTableSurface(UITableView *table, UIColor *background,
                           UITraitCollection *traits);

#endif
