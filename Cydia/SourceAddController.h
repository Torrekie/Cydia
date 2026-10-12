/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceAddController_H
#define Cydia_SourceAddController_H
#import "CyteKit/ViewController.h"
#include "Cydia/SourceDocument.hpp"
@class Database, CydiaSourceDefinition;
@interface CydiaSourceAddController : CyteViewController
+ (void)showURLPromptWithDatabase:(Database *)database presenter:(CyteViewController *)presenter URL:(NSString *)URL;
+ (void)showAdvancedWithDatabase:(Database *)database presenter:(CyteViewController *)presenter
                            URL:(NSString *)URL access:(CydiaSources::Access)access;
+ (void)showDefinition:(NSString *)definition database:(Database *)database
            presenter:(CyteViewController *)presenter access:(CydiaSources::Access)access;
+ (void)editDefinition:(CydiaSourceDefinition *)row database:(Database *)database
            presenter:(CyteViewController *)presenter access:(CydiaSources::Access)access;
@end
#endif
