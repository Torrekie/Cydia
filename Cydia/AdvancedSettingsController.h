/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AdvancedSettingsController_H
#define Cydia_AdvancedSettingsController_H
#import "CyteKit/ViewController.h"
@class Database;
@interface CydiaAdvancedSettingsController : CyteViewController
- (instancetype)initWithDatabase:(Database *)database;
@end
#endif
