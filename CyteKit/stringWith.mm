/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
*/

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#include "CyteKit/UCPlatform.h"

#include "CyteKit/stringWith.h"

@implementation NSString (Cyte)

+ (NSString *) stringWithUTF8BytesNoCopy:(const char *)bytes length:(int)length {
    return [[NSString alloc] initWithBytesNoCopy:const_cast<char *>(bytes) length:length encoding:NSUTF8StringEncoding freeWhenDone:NO];
}

+ (NSString *) stringWithUTF8Bytes:(const char *)bytes length:(int)length {
    return [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
}

+ (NSString *) stringWithFormat:(NSString *)format :(size_t)count :(id const __unsafe_unretained *)args {
    switch (count) {
        case 0:
            return [[NSString alloc] initWithString:format];
        case 1:
            return [[NSString alloc] initWithFormat:format, args[0]];
        case 2:
            return [[NSString alloc] initWithFormat:format, args[0], args[1]];
        case 3:
            return [[NSString alloc] initWithFormat:format, args[0], args[1], args[2]];
        case 4:
            return [[NSString alloc] initWithFormat:format, args[0], args[1], args[2], args[3]];
        case 5:
            return [[NSString alloc] initWithFormat:format, args[0], args[1], args[2], args[3], args[4]];
        case 6:
            return [[NSString alloc] initWithFormat:format, args[0], args[1], args[2], args[3], args[4], args[5]];
        case 7:
            return [[NSString alloc] initWithFormat:format, args[0], args[1], args[2], args[3], args[4], args[5], args[6]];
        case 8:
            return [[NSString alloc] initWithFormat:format, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]];
        default:
            _assert(false);
    }
}

@end
