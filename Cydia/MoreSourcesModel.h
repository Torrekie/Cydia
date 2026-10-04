/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#import <Foundation/Foundation.h>

// Original, finite restoration catalog; not a cap on the user's source list.
FOUNDATION_EXPORT NSArray<NSDictionary *> *CydiaDefaultSourceCatalog(void);
FOUNDATION_EXPORT NSDictionary *CydiaDefaultSourceForIdentifier(NSString *identifier);
FOUNDATION_EXPORT NSArray<NSDictionary *> *CydiaMissingDefaultSources(NSArray<NSDictionary *> *configured);
