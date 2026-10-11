/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_CapabilityController_H
#define Cydia_CapabilityController_H
#import "CyteKit/ViewController.h"
@class Database;
@interface CydiaCapabilityController : CyteViewController
- (instancetype)initWithDatabase:(Database *)database;
@end
#endif
