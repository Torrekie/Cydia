/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_CydiaDelegate_H
#define Cydia_CydiaDelegate_H

#include "CyteKit/UCPlatform.h"

#include <UIKit/UIKit.h>

@class Package;
@class UIProgressHUD;

@protocol CydiaDelegate
- (void) returnToCydia;
- (void) saveState;
- (void) retainNetworkActivityIndicator;
- (void) releaseNetworkActivityIndicator;
- (void) clearPackage:(Package *)package;
- (void) installPackage:(Package *)package;
- (void) installPackages:(NSArray *)packages;
- (void) removePackage:(Package *)package;
- (void) beginUpdate;
- (void) cancelUpdate;
- (BOOL) updating;
- (bool) requestUpdate;
- (void) distUpgrade;
- (void) queue;
- (void) loadData;
- (void) updateData;
- (void) _saveConfig;
- (void) syncData;
- (void) addSource:(NSDictionary *)source;
- (BOOL) addTrivialSource:(NSString *)href;
- (UIProgressHUD *) addProgressHUD;
- (void) removeProgressHUD:(UIProgressHUD *)hud;
- (void) showActionSheet:(UIActionSheet *)sheet fromItem:(UIBarButtonItem *)item;
- (void) reloadDataWithInvocation:(NSInvocation *)invocation;
@end

#endif//Cydia_CydiaDelegate_H
