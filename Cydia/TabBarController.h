/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
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

#ifndef Cydia_TabBarController_H
#define Cydia_TabBarController_H

#include "CyteKit/TabBarController.h"

@class Database;
@protocol CydiaDelegate;

@interface CydiaTabBarController : CyteTabBarController

- (instancetype) initWithDatabase:(Database *)database;
- (void) beginUpdate;
- (void) cancelUpdate;
- (BOOL) updating;
- (void) setUpdateDelegate:(NSObject<CydiaDelegate> *)delegate;

@end

#endif//Cydia_TabBarController_H
