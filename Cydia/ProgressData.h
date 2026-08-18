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
**/
/* }}} */

#ifndef Cydia_ProgressData_H
#define Cydia_ProgressData_H

#include "CyteKit/UCPlatform.h"
#include "Menes/ObjectHandle.h"

#include <Foundation/Foundation.h>

@class CydiaProgressEvent;

@interface CydiaProgressData : NSObject {
    __weak id delegate_;

    bool running_;
    float percent_;

    float current_;
    float total_;
    float speed_;

    _H<NSMutableArray> events_;
    _H<NSString> title_;

    _H<NSString> status_;
    _H<NSString> finish_;
}

- (id) delegate;
- (void) setDelegate:(id)delegate;

- (void) setPercent:(float)value;
- (NSNumber *) percent;
- (void) setCurrent:(float)value;
- (NSNumber *) current;
- (void) setTotal:(float)value;
- (NSNumber *) total;
- (void) setSpeed:(float)value;
- (NSNumber *) speed;

- (NSArray *) events;
- (void) removeAllEvents;
- (void) addEvent:(CydiaProgressEvent *)event;

- (void) setTitle:(NSString *)text;
- (NSString *) title;
- (void) setFinish:(NSString *)text;
- (NSString *) finish;
- (void) setRunning:(bool)running;
- (NSNumber *) running;

@end

#endif//Cydia_ProgressData_H
