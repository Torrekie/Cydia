/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#import <Foundation/Foundation.h>
@class Database, CyteViewController;
@protocol CydiaMoreSourcesProviding <NSObject>
- (NSArray<NSDictionary *> *)configuredSources;
- (BOOL)canEditSources;
- (void)restoreSourceIdentifier:(NSString *)identifier presenter:(CyteViewController *)presenter
    completion:(void (^)(BOOL added))completion;
- (void)cancelRestoration;
@end
@interface CydiaMoreSourcesProvider : NSObject <CydiaMoreSourcesProviding>
- (instancetype)initWithDatabase:(Database *)database;
@end
