/* Cydia Refurbished legacy web-navigation metadata boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef CyteKit_WebNavigationContext_H
#define CyteKit_WebNavigationContext_H

#import <Foundation/Foundation.h>

/* CyteKit carries this object opaquely. The application-owned implementation
 * decides how caller authority changes when legacy web content opens another
 * route, keeping the legacy browser layer independent of policy enums. */
@protocol CyteWebNavigationContext <NSObject, NSCopying>

@property(nonatomic, readonly, copy) NSURL *initiatingOrigin;
@property(nonatomic, readonly, getter=isMainFrame) BOOL mainFrame;
@property(nonatomic, readonly, getter=hasUserGesture) BOOL userGesture;

- (NSObject<CyteWebNavigationContext> *) contextForRedirectWithOrigin:(NSURL *)origin
                                                            mainFrame:(BOOL)mainFrame
                                                          userGesture:(BOOL)userGesture;
- (NSObject<CyteWebNavigationContext> *) contextForPopupWithOrigin:(NSURL *)origin
                                                         mainFrame:(BOOL)mainFrame
                                                       userGesture:(BOOL)userGesture;

@end

#endif // CyteKit_WebNavigationContext_H
