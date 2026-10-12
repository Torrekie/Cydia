/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceFormControls_H
#define Cydia_SourceFormControls_H
#import "CyteKit/ViewController.h"

NSString *CydiaSourceText(NSString *key);
void CydiaStyleSourceForm(UITableView *table, UITraitCollection *traits);
void CydiaStyleSourceFormCell(UITableViewCell *cell, UITraitCollection *traits);

/* Persistent labels and native bordered inputs make editability explicit. */
@interface CydiaSourceFieldCell : UITableViewCell
@property(nonatomic, readonly) UITextField *field;
- (instancetype)initWithTitle:(NSString *)title value:(NSString *)value placeholder:(NSString *)placeholder
                         URL:(BOOL)URL traits:(UITraitCollection *)traits;
@end
@interface CydiaSourceFormatCell : UITableViewCell
@property(nonatomic, readonly) UISegmentedControl *control;
- (instancetype)initWithTitle:(NSString *)title traits:(UITraitCollection *)traits;
@end
@interface CydiaSourceTextCell : UITableViewCell
@property(nonatomic, readonly) UITextView *editor;
- (instancetype)initWithText:(NSString *)text title:(NSString *)title traits:(UITraitCollection *)traits;
@end

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
