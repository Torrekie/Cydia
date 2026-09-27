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

/* Exposed for the installed progress probe and accessibility contract.  The
 * values are derived from the current Dynamic Type font; the compact rhythm
 * never replaces a larger accessibility font with a smaller fixed size. */
@property(nonatomic, readonly) CGFloat messageLineHeight;
@property(nonatomic, readonly) CGFloat messageLineSpacing;
@property(nonatomic, readonly) CGFloat messageMinimumLineHeight;
@property(nonatomic, readonly) CGFloat messageMaximumLineHeight;
@property(nonatomic, readonly) UIEdgeInsets eventLayoutMargins;

- (void) configureWithEvent:(CydiaProgressPresentationEvent *)event;

@end

NS_ASSUME_NONNULL_END

#endif // Cydia_ProgressEventCell_H
