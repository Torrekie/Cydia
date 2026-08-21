/* Cydia Refurbished native progress event cell.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_ProgressEventCell_H
#define Cydia_ProgressEventCell_H

#include "Cydia/ProgressViewModel.h"

#include <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CydiaProgressEventCell : UITableViewCell

- (void) configureWithEvent:(CydiaProgressPresentationEvent *)event;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_ProgressEventCell_H
