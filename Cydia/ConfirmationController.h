/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished UIKit work Copyright (C) 2026 Torrekie
 */

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
 */
/* }}} */

#ifndef Cydia_ConfirmationController_H
#define Cydia_ConfirmationController_H

#include "CyteKit/ViewController.h"
#include <TargetConditionals.h>

@class Database;
@class CydiaConfirmationViewModel;

@protocol ConfirmationControllerDelegate
- (void) cancelAndClear:(bool)clear;
- (void) confirmWithNavigationController:(UINavigationController *)navigation;
/* Retained for source compatibility with the application delegate. Continue
   Queuing is deliberately dispatched through cancelAndClear:false. */
- (void) queue;
@end

@interface ConfirmationController : CyteViewController

- (instancetype) initWithDatabase:(Database *)database;

#if TARGET_OS_SIMULATOR
/* Simulator probe seam: callers supply a typed immutable snapshot, while the
 * production table, alerts, and delegate dispatch remain unchanged. */
- (instancetype) initWithViewModel:(CydiaConfirmationViewModel *)viewModel
                          delegate:(id<ConfirmationControllerDelegate>)delegate;
#endif

@end

#endif//Cydia_ConfirmationController_H
