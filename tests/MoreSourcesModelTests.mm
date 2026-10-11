/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/MoreSourcesModel.h"
#include <cassert>
#include <cstdio>
int main() { @autoreleasepool {
    assert(CydiaDefaultSourceCatalog().count == 0);
    assert(CydiaMissingDefaultSources(@[]).count == 0);
    assert(CydiaMissingDefaultSources(@[@{@"rooturi":@"https://example.invalid/", @"distribution":@"stable"}]).count == 0);
    assert(CydiaDefaultSourceForIdentifier(@"bigboss") == nil);
    assert(CydiaDefaultSourceForIdentifier(nil) == nil);
    puts("[more-sources] PASS: no assumed or restorable bootstrap repositories");
} }
