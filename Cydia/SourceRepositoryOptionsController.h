/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceRepositoryOptionsController_H
#define Cydia_SourceRepositoryOptionsController_H
#import "CyteKit/ViewController.h"

/* Published, unverified options only. The caller applies the returned draft
 * values and performs APT validation; selecting choices never writes files. */
@interface CydiaSourceRepositoryOptionsController : CyteViewController
- (instancetype)initWithOptions:(NSArray<NSDictionary *> *)options
                 selectedSuite:(NSString *)suite selectedComponents:(NSSet<NSString *> *)components
                         saved:(void (^)(NSString *suite, NSSet<NSString *> *components))saved;
@end
#endif
