/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_CopyingFilesGuideController_H
#define Cydia_CopyingFilesGuideController_H
#import "Cydia/HomeGuideController.h"

// Bundled informational content only. Selecting a row navigates; it never
// executes a file-transfer command, changes a password or installs a tool.
@interface CopyingFilesGuideController : HomeGuideController
@end
#endif
