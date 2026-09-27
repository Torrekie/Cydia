/* Cydia legacy package-metadata data boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageLegacyMetadataPolicy.h"

#include <stdint.h>
#include <string.h>

namespace {

static const NSUInteger kMaximumIdentityBytes = 1024;
static const NSUInteger kMaximumMetadataBytes = 64 * 1024;
static const NSUInteger kMaximumIconBytes = 512 * 1024;
static const NSUInteger kMaximumIconDimension = 512;
static const uint64_t kMaximumIconPixels = 512ULL * 512ULL;

BOOL PackageIdentityIsAllowed(NSString *identity) {
    if (![identity isKindOfClass:[NSString class]] || [identity length] == 0 ||
        [identity length] > kMaximumIdentityBytes)
        return NO;
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *allowed([
            [NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyz0123456789+.-"] mutableCopy]);
        invalid = [allowed invertedSet];
    });
    if ([identity rangeOfCharacterFromSet:invalid].location != NSNotFound ||
        ![[NSCharacterSet alphanumericCharacterSet]
            characterIsMember:[identity characterAtIndex:0]])
        return NO;
    NSData *bytes([identity dataUsingEncoding:NSUTF8StringEncoding
                          allowLossyConversion:NO]);
    return [bytes length] != 0 && [bytes length] <= kMaximumIdentityBytes;
}

NSData *JSONDataFromLegacyResponse(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || [data length] == 0 ||
        [data length] > kMaximumMetadataBytes)
        return nil;
    NSString *text([[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding]);
    if (text == nil)
        return nil;
    NSCharacterSet *space([NSCharacterSet whitespaceAndNewlineCharacterSet]);
    text = [text stringByTrimmingCharactersInSet:space];
    /* The live service returns a parenthesized JSON object because the old UI
     * evaluated it as JavaScript.  Native code accepts that exact wrapper but
     * never a callback, statement, or bare expression. */
    if (![text hasPrefix:@"("] || ![text hasSuffix:@")"] || [text length] < 2)
        return nil;
    text = [[text substringWithRange:NSMakeRange(1, [text length] - 2)]
        stringByTrimmingCharactersInSet:space];
    if (![text hasPrefix:@"{"] || ![text hasSuffix:@"}"])
        return nil;
    return [text dataUsingEncoding:NSUTF8StringEncoding
               allowLossyConversion:NO];
}

uint32_t ReadBigEndian32(const uint8_t *bytes) {
    return (static_cast<uint32_t>(bytes[0]) << 24) |
        (static_cast<uint32_t>(bytes[1]) << 16) |
        (static_cast<uint32_t>(bytes[2]) << 8) |
        static_cast<uint32_t>(bytes[3]);
}

BOOL IconPathIsAllowed(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || [path length] == 0 ||
        [path length] > kMaximumIdentityBytes + 16 ||
        [path rangeOfString:@"%"].location != NSNotFound ||
        [path rangeOfString:@"\\"].location != NSNotFound)
        return NO;
    NSString *prefix;
    if ([path hasPrefix:@"/icon@2x/"])
        prefix = @"/icon@2x/";
    else if ([path hasPrefix:@"/icon/"])
        prefix = @"/icon/";
    else
        return NO;
    NSString *name([path substringFromIndex:[prefix length]]);
    if ([name length] <= 4 || ![name hasSuffix:@".png"] ||
        [name rangeOfString:@"/"].location != NSNotFound)
        return NO;
    return PackageIdentityIsAllowed([name substringToIndex:[name length] - 4]);
}

} // namespace


NSUInteger CydiaPackageLegacyMetadataMaximumBytes(void) {
    return kMaximumMetadataBytes;
}

NSUInteger CydiaPackageLegacyIconMaximumBytes(void) {
    return kMaximumIconBytes;
}

NSURL *CydiaPackageLegacyMetadataURL(NSString *packageIdentity) {
    if (!PackageIdentityIsAllowed(packageIdentity))
        return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:
        @"https://cydia.saurik.com/api/package/%@", packageIdentity]];
}

BOOL CydiaPackageLegacyIconURLIsAllowed(NSURL *URL) {
    if (![URL isKindOfClass:[NSURL class]] || [[URL absoluteString] length] > 4096)
        return NO;
    NSURLComponents *components([NSURLComponents componentsWithURL:URL
                                           resolvingAgainstBaseURL:NO]);
    if (components == nil || [components user] != nil ||
        [components password] != nil || [components port] != nil ||
        [components query] != nil || [components fragment] != nil ||
        ![[components percentEncodedPath] isEqualToString:[components path]] ||
        !IconPathIsAllowed([components path]))
        return NO;
    NSString *scheme([[components scheme] lowercaseString]);
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
        return NO;
    NSString *host([[components host] lowercaseString]);
    return [host isEqualToString:@"cydia.saurik.com"];
}

NSURL *CydiaPackageLegacyAlternateIconURL(NSData *metadataData) {
    NSData *JSONData(JSONDataFromLegacyResponse(metadataData));
    if (JSONData == nil)
        return nil;
    id object([NSJSONSerialization JSONObjectWithData:JSONData options:0 error:NULL]);
    if (![object isKindOfClass:[NSDictionary class]])
        return nil;
    id value([(NSDictionary *)object objectForKey:@"icon"]);
    if (![value isKindOfClass:[NSString class]] || [value length] == 0 ||
        [value length] > 4096)
        return nil;
    NSURL *URL([NSURL URLWithString:value]);
    if (!CydiaPackageLegacyIconURLIsAllowed(URL))
        return nil;
    NSURLComponents *components([NSURLComponents componentsWithURL:URL
                                           resolvingAgainstBaseURL:NO]);
    components.scheme = @"https";
    return [components URL];
}

BOOL CydiaPackageLegacyIconPNGDataIsAllowed(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || [data length] < 33 ||
        [data length] > kMaximumIconBytes)
        return NO;
    const uint8_t *bytes(static_cast<const uint8_t *>([data bytes]));
    static const uint8_t signature[] = {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    };
    if (memcmp(bytes, signature, sizeof(signature)) != 0 ||
        ReadBigEndian32(bytes + 8) != 13 ||
        memcmp(bytes + 12, "IHDR", 4) != 0)
        return NO;
    NSUInteger width(ReadBigEndian32(bytes + 16));
    NSUInteger height(ReadBigEndian32(bytes + 20));
    if (width == 0 || height == 0 || width > kMaximumIconDimension ||
        height > kMaximumIconDimension)
        return NO;
    return static_cast<uint64_t>(width) * static_cast<uint64_t>(height) <=
        kMaximumIconPixels;
}
