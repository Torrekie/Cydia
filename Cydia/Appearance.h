/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_Appearance_H
#define Cydia_Appearance_H

#include "CyteKit/UCPlatform.h"
#include "Cydia/CYColor.hpp"
#include "Menes/ObjectHandle.h"

#include <UIKit/UIKit.h>

// Shared UIKit layout value used by controllers outside MobileCydia.mm.
static const NSUInteger CydiaAutoresizingFlexibleBoth = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

extern CYColor Blue_;
extern CYColor Blueish_;
extern CYColor Black_;
extern CYColor Folder_;
extern CYColor Off_;
extern CYColor White_;
extern CYColor Gray_;
extern CYColor Green_;
extern CYColor Purple_;
extern CYColor Purplish_;

extern UIColor *InstallingColor_;
extern UIColor *RemovingColor_;

extern _H<UIFont> Font12_;
extern _H<UIFont> Font12Bold_;
extern _H<UIFont> Font14_;
extern _H<UIFont> Font18_;
extern _H<UIFont> Font18Bold_;
extern _H<UIFont> Font22Bold_;

UIColor *whiteIfNotDark(bool white);
void overrideUserInterfaceStyle(NSInteger style);

#endif//Cydia_Appearance_H
