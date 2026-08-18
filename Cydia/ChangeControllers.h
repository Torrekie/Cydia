/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_ChangeControllers_H
#define Cydia_ChangeControllers_H

#include "Cydia/PackageControllers.h"

@class Database;

@interface ChangesController : FilteredPackageListController

- (id) initWithDatabase:(Database *)database;

@end

@interface SearchController : FilteredPackageListController

- (id) initWithDatabase:(Database *)database query:(NSString *)query;
- (void) reloadData;

@end

#endif//Cydia_ChangeControllers_H
