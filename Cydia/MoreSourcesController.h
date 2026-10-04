/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "CyteKit/ViewController.h"
#import "Cydia/MoreSourcesProvider.h"
@interface MoreSourcesController : CyteViewController
- (instancetype)initWithProvider:(id<CydiaMoreSourcesProviding>)provider;
@end
