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

#ifndef Cydia_CydiaWebViewController_H
#define Cydia_CydiaWebViewController_H

#include "CyteKit/UCPlatform.h"
#include "CyteKit/CyteObject.h"
#include "CyteKit/WebViewController.h"
#include "Menes/ObjectHandle.h"

@class CydiaObject;

@interface CydiaObject : CyteObject {
    __weak id delegate_;
}

- (void) setDelegate:(id)delegate;

@end

@interface CydiaWebViewController : CyteWebViewController {
    _H<CydiaObject> cydia_;
}

+ (NSURLRequest *) requestWithHeaders:(NSURLRequest *)request;
+ (void) didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame withCydia:(CydiaObject *)cydia;
- (void) setDelegate:(id)delegate;

@end

@interface AppCacheController : CydiaWebViewController
@end

@interface NSURL (CydiaSecure)
- (bool) isCydiaSecure;
@end

#endif//Cydia_CydiaWebViewController_H
