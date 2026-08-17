/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
 */
/* }}} */

#ifndef Cydia_PackageControllers_H
#define Cydia_PackageControllers_H

#include "CyteKit/UCPlatform.h"
#include "Cydia/CydiaWebViewController.h"
#include "CyteKit/ListController.h"
#include "Menes/Function.h"
#include "Menes/ObjectHandle.h"

#include <UIKit/UIKit.h>

#include <utility>
#include <vector>

@class Database;
@class Package;

@interface CYPackageController : CydiaWebViewController <UIActionSheetDelegate> {
    __weak Database *database_;
    _H<Package> package_;
    _H<NSString> name_;
    bool commercial_;
    std::vector<std::pair<_H<NSString>, _H<NSString>>> buttons_;
    _H<UIActionSheet> sheet_;
    _H<UIBarButtonItem> button_;
    _H<NSArray> versions_;
}

- (id) initWithDatabase:(Database *)database forPackage:(NSString *)name withReferrer:(NSString *)referrer;

@end

@interface PackageListController : CyteListController <UITableViewDataSource, UITableViewDelegate> {
    __weak Database *database_;
    unsigned era_;
    _H<NSArray> packages_;
    _H<NSArray> sections_;

    _H<NSArray> thumbs_;
    std::vector<NSInteger> offset_;

    unsigned reloading_;
}

- (id) initWithDatabase:(Database *)database title:(NSString *)title;
- (void) didSelectPackage:(Package *)package;
- (NSArray *) sectionsForPackages:(NSMutableArray *)packages;

@end

typedef Function<bool, Package *> PackageFilter;
typedef Function<void, NSMutableArray *> PackageSorter;

@interface FilteredPackageListController : PackageListController {
    PackageFilter filter_;
    PackageSorter sorter_;
}

- (id) initWithDatabase:(Database *)database title:(NSString *)title filter:(PackageFilter)filter;
- (void) setFilter:(PackageFilter)filter;
- (void) setSorter:(PackageSorter)sorter;

@end

#endif//Cydia_PackageControllers_H
