/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/MoreSourcesModel.h"

// Compatibility entry points do not prescribe repositories for a bootstrap.
NSArray<NSDictionary *> *CydiaDefaultSourceCatalog() { return @[]; }
NSDictionary *CydiaDefaultSourceForIdentifier(NSString *identifier) { (void)identifier; return nil; }
NSArray<NSDictionary *> *CydiaMissingDefaultSources(NSArray<NSDictionary *> *configured) {
    (void)configured; return @[];
}
