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

#ifndef Cydia_PackageViews_H
#define Cydia_PackageViews_H

#include "CyteKit/UCPlatform.h"
#include "CyteKit/ListController.h"
#include "CyteKit/TableViewCell.h"
#include "Menes/ObjectHandle.h"

@class Database;
@class Package;
@class Section;

@interface PackageCell : CyteTableViewCell <CyteTableViewCellDelegate> {
    _H<UIImage> icon_;
    _H<NSString> name_;
    _H<NSString> description_;
    bool commercial_;
    _H<NSString> source_;
    _H<UIImage> badge_;
    _H<UIImage> placard_;
    bool installing_;
    bool removing_;
    bool summarized_;
}

- (PackageCell *) init;
- (void) setPackage:(Package *)package asSummary:(bool)summary;
- (void) drawContentRect:(CGRect)rect;

@end

@interface SectionCell : CyteTableViewCell <CyteTableViewCellDelegate> {
    _H<NSString> basic_;
    _H<NSString> section_;
    _H<NSString> name_;
    _H<NSString> count_;
    _H<UIImage> icon_;
    _H<UISwitch> switch_;
    BOOL editing_;
}

- (void) setSection:(Section *)section editing:(BOOL)editing;

@end

@interface FileTable : CyteListController <UITableViewDataSource, UITableViewDelegate> {
    __weak Database *database_;
    _H<Package> package_;
    _H<NSString> name_;
    _H<NSMutableArray> files_;
}

- (id) initWithDatabase:(Database *)database forPackage:(NSString *)name;

@end

#endif//Cydia_PackageViews_H
