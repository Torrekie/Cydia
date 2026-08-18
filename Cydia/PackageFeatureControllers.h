/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_PackageFeatureControllers_H
#define Cydia_PackageFeatureControllers_H

#include "Cydia/PackageControllers.h"
#include "CyteKit/ViewController.h"

@class Database;

@interface PackageSettingsController : CyteViewController

- (id) initWithDatabase:(Database *)database package:(NSString *)package;

@end

@interface InstalledController : FilteredPackageListController

- (id) initWithDatabase:(Database *)database;
- (void) queueStatusDidChange;

@end

#endif//Cydia_PackageFeatureControllers_H
