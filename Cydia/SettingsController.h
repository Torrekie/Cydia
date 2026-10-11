/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SettingsController_H
#define Cydia_SettingsController_H
#import "CyteKit/ViewController.h"
@class Database;

@interface CydiaSettingsController : CyteViewController
- (instancetype)initWithDatabase:(Database *)database;
@end

void CydiaPresentAbout(UIViewController *presenter);
#endif
