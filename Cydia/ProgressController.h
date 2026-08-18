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

#ifndef Cydia_ProgressController_H
#define Cydia_ProgressController_H

#include "Cydia/CydiaWebViewController.h"
#include "Cydia/ProgressData.h"
#include "Cydia/ProgressEvent.h"
#include "Menes/ObjectHandle.h"

@class Database;

@interface ProgressController : CydiaWebViewController <ProgressDelegate> {
    _transient Database *database_;
    _H<CydiaProgressData, 1> progress_;
    unsigned cancel_;
}

- (id) initWithDatabase:(Database *)database delegate:(id)delegate;
- (void) invoke:(NSInvocation *)invocation withTitle:(NSString *)title;
- (void) setTitle:(NSString *)title;
- (void) setCancellable:(bool)cancellable;

@end

#endif//Cydia_ProgressController_H
