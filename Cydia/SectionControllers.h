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

#ifndef Cydia_SectionControllers_H
#define Cydia_SectionControllers_H

#include "Cydia/PackageControllers.h"
#include "CyteKit/ViewController.h"

@class Database;
@class Source;

@interface SectionController : FilteredPackageListController

- (id) initWithDatabase:(Database *)database source:(Source *)source section:(NSString *)section;

@end

@interface SectionsController : CyteViewController

- (id) initWithDatabase:(Database *)database source:(Source *)source;

@end

#endif//Cydia_SectionControllers_H
