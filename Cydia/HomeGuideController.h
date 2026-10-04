/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "CyteKit/ViewController.h"

// Finite bundled guide/legal documents. No HTML renderer or command execution.
@interface HomeGuideController : CyteViewController
- (instancetype)initWithPageIdentifier:(NSString *)identifier;
// Other first-party guide controllers may reuse the renderer with bundled data.
- (instancetype)initWithPageIdentifier:(NSString *)identifier page:(NSDictionary *)page;
- (void)scrollToRowIdentifier:(NSString *)identifier;
- (void)openGuideDestinationURL:(NSURL *)URL;
@end
