/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
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

#ifndef Cydia_AppState_H
#define Cydia_AppState_H

#include "CyteKit/UCPlatform.h"
#include "Menes/ObjectHandle.h"

#include <Foundation/Foundation.h>

@class UIDevice;

/* Values initialized by the application bootstrap and consumed by web code. */
extern NSString *Cydia_;
extern const NSString *UI_;
extern BOOL Advanced_;
extern _H<NSString> UniqueID_;
extern NSMutableDictionary *Values_;
extern _H<NSMutableDictionary> SessionData_;
extern _H<NSMutableSet> BridgedHosts_;
extern _H<NSMutableSet> InsecureHosts_;

NSString *UniqueIdentifier(UIDevice *device = nil);
NSString *VerifySource(NSString *href);

#endif//Cydia_AppState_H
