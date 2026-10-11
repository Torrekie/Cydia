/* Cydia Refurbished public UIKit compatibility declarations.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_TableViewCompatibility_H
#define Cydia_TableViewCompatibility_H

#include <UIKit/UITableView.h>

/* Preserve the iOS 15 appearance adjustment when building with older SDKs.
 * UIKit supplies this property at runtime; callers must check availability. */
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 150000
@interface UITableView (CydiaSectionHeaderTopPadding)
@property(nonatomic) CGFloat sectionHeaderTopPadding API_AVAILABLE(ios(15.0));
@end
#endif

#endif // Cydia_TableViewCompatibility_H
