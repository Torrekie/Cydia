/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RecoveryController_H
#define Cydia_RecoveryController_H
#import "CyteKit/ViewController.h"
@class Database;
@interface CydiaRecoveryController : CyteViewController
- (instancetype)initWithDatabase:(Database *)database packages:(NSArray *)packages;
@end
#endif
