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

#include "Cydia/URLProtocol.h"

#include "Cydia/URLResourceResolver.h"

@implementation CydiaURLProtocol

+ (NSString *) scheme {
    return @"cydia";
}

- (bool) loadForPath:(NSString *)path ofRequest:(NSURLRequest *)request {
    NSData *data(nil);
    switch (CydiaResolveURLResourcePath(path, &data)) {
        case CydiaURLResourceResolutionUnhandled:
            return [super loadForPath:path ofRequest:request];
        case CydiaURLResourceResolutionFailed:
            [self _returnPNGData:nil forRequest:request];
            return true;
        case CydiaURLResourceResolutionSucceeded:
            [self _returnPNGData:data forRequest:request];
            return true;
    }
    return [super loadForPath:path ofRequest:request];
}

@end
