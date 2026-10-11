/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_KeyringImportController_H
#define Cydia_KeyringImportController_H
#import "CyteKit/ViewController.h"
@class Database;
@interface CydiaKeyringImportController : CyteViewController
- (instancetype)initWithDatabase:(Database *)database;
- (instancetype)initWithDatabase:(Database *)database importURL:(NSURL *)url;
@end
#endif
