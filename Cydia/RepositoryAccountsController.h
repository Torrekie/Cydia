/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "CyteKit/ViewController.h"

@interface RepositoryAccountsController : CyteViewController
- (instancetype)init;
- (instancetype)initWithSourceURL:(NSURL *)sourceURL name:(NSString *)name package:(NSString *)package;
@end
