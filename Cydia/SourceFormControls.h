/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceFormControls_H
#define Cydia_SourceFormControls_H
#import "CyteKit/ViewController.h"

NSString *CydiaSourceText(NSString *key);
void CydiaStyleSourceForm(UITableView *table, UITraitCollection *traits);
void CydiaStyleSourceFormCell(UITableViewCell *cell, UITraitCollection *traits);

/* Draft editors return values only. They never write APT configuration. */
@interface CydiaSourceTextController : CyteViewController
- (instancetype)initWithTitle:(NSString *)title value:(NSString *)value
                  explanation:(NSString *)explanation URL:(BOOL)URL multiline:(BOOL)multiline
                         saved:(void (^)(NSString *value))saved;
@end

@interface CydiaSourceChoicesController : CyteViewController
- (instancetype)initWithTitle:(NSString *)title choices:(NSArray<NSDictionary *> *)choices
                     selected:(NSSet<NSString *> *)selected multiple:(BOOL)multiple
                  explanation:(NSString *)explanation saved:(void (^)(NSSet<NSString *> *values))saved;
@end
#endif
