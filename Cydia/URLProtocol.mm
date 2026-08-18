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

#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "iPhonePrivate.h"

// The application bootstrap resolves this private symbol before UIApplicationMain.
// Keeping the storage here preserves that timing while keeping the protocol header narrow.
NSData *(*$SBSCopyIconImagePNGDataForDisplayIdentifier)(NSString *);

@implementation CydiaURLProtocol

+ (NSString *) scheme {
    return @"cydia";
}

- (bool) loadForPath:(NSString *)path ofRequest:(NSURLRequest *)request {
    NSRange slash([path rangeOfString:@"/"]);

    NSString *command;
    if (slash.location == NSNotFound) {
        command = path;
        path = nil;
    } else {
        command = [path substringToIndex:slash.location];
        path = [path substringFromIndex:(slash.location + 1)];
    }

    Database *database([Database sharedInstance]);

    if (false);
    else if ([command isEqualToString:@"application-icon"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        UIImage *icon(nil);

        if (icon == nil && $SBSCopyIconImagePNGDataForDisplayIdentifier != NULL) {
            NSData *data($SBSCopyIconImagePNGDataForDisplayIdentifier(path));
            icon = [UIImage imageWithData:data];
        }

        if (icon == nil)
            if (NSString *file = SBSCopyIconImagePathForDisplayIdentifier(path))
                icon = [UIImage imageAtPath:file];

        if (icon == nil)
            icon = [UIImage imageNamed:@"unknown.png"];

        [self _returnPNGWithImage:icon forRequest:request];
    } else if ([command isEqualToString:@"package-icon"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        Package *package([database packageWithName:path]);
        if (package == nil)
            goto fail;
        [package parse];
        UIImage *icon([package icon]);
        [self _returnPNGWithImage:icon forRequest:request];
    } else if ([command isEqualToString:@"uikit-image"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        UIImage *icon(_UIImageWithName(path));
        [self _returnPNGWithImage:icon forRequest:request];
    } else if ([command isEqualToString:@"section-icon"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        UIImage *icon([UIImage imageAtPath:[NSString stringWithFormat:@"%@/Sections/%@.png", App_, [path stringByReplacingOccurrencesOfString:@" " withString:@"_"]]]);
        if (icon == nil)
            icon = [UIImage imageNamed:@"unknown.png"];
        [self _returnPNGWithImage:icon forRequest:request];
    } else fail: {
        return [super loadForPath:path ofRequest:request];
    }

    return true;
}

@end
