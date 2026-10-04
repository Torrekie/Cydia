/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once
#import <UIKit/UIKit.h>

/* Main thread, after real appearance/rendering. No focus/input/setting mutation.
 * With no valid opt-in path, no observers, queued capture or file are created. */
void CydiaCaptureNativeAccessibility(UIViewController *controller, NSString *surface);
