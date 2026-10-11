/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_BootstrapAccessController_H
#define Cydia_BootstrapAccessController_H
#import "CyteKit/ViewController.h"
@class Database;
@interface CydiaBootstrapAccessController : CyteViewController
- (instancetype)initWithDatabase:(Database *)database;
@end
#endif
