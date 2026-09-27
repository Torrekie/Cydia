/* Cydia depiction resource resolver.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/URLResourceResolver.h"

#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/PrivateServices.h"
#include "Cydia/URLProtocolPolicy.h"
#include "iPhonePrivate.h"

/* MobileCydia resolves this optional private provider before UIApplicationMain.
 * The resolver owns the storage because both legacy and public depiction
 * resource loaders consume it. */
NSData *(*$SBSCopyIconImagePNGDataForDisplayIdentifier)(NSString *);

namespace {

NSData *EncodeImage(UIImage *image) {
    if (image == nil)
        return nil;

    CGImageRef CGImage([image CGImage]);
    if (CGImage == NULL || !CydiaURLResourceImageDimensionsAreAllowed(
            CGImageGetWidth(CGImage), CGImageGetHeight(CGImage)))
        return nil;

    NSData *data(UIImagePNGRepresentation(image));
    return CydiaURLResourcePNGDataIsAllowed(data) ? data : nil;
}

UIImage *ApplicationIcon(NSString *identifier) {
    if ($SBSCopyIconImagePNGDataForDisplayIdentifier != NULL) {
        NSData *data($SBSCopyIconImagePNGDataForDisplayIdentifier(identifier));
        if (CydiaURLResourcePNGDataIsAllowed(data))
            return [UIImage imageWithData:data];
    }

    if (NSString *file = CydiaCopyIconImagePath(identifier))
        if (UIImage *image = [UIImage imageAtPath:file])
            return image;
    return [UIImage imageNamed:@"unknown.png"];
}

UIImage *PackageIcon(NSString *identifier) {
    Package *package([[Database sharedInstance] packageWithName:identifier]);
    if (package == nil)
        return nil;
    [package parse];
    return [package icon];
}

UIImage *SectionIcon(NSString *identifier) {
    NSString *name([identifier stringByReplacingOccurrencesOfString:@" "
                                                          withString:@"_"]);
    UIImage *image([UIImage imageAtPath:
        [NSString stringWithFormat:@"%@/Sections/%@.png", App_, name]]);
    return image ?: [UIImage imageNamed:@"unknown.png"];
}

} // namespace


CydiaURLResourceResolution CydiaResolveURLResourcePath(NSString *path,
                                                        NSData **PNGData) {
    if (PNGData != NULL)
        *PNGData = nil;
    if (![path isKindOfClass:[NSString class]])
        return CydiaURLResourceResolutionUnhandled;

    NSRange slash([path rangeOfString:@"/"]);
    NSString *command(slash.location == NSNotFound ? path :
        [path substringToIndex:slash.location]);
    CydiaURLResourceKind kind(CydiaURLResourceKindForCommand(command));
    if (kind == CydiaURLResourceKindUnknown)
        return CydiaURLResourceResolutionUnhandled;

    NSString *rawIdentifier(slash.location == NSNotFound ? nil :
        [path substringFromIndex:(slash.location + 1)]);
    NSString *identifier(CydiaURLResourceDecodeIdentifier(rawIdentifier, kind));
    if (identifier == nil)
        return CydiaURLResourceResolutionFailed;

    UIImage *image(nil);
    switch (kind) {
        case CydiaURLResourceKindApplicationIcon:
            image = ApplicationIcon(identifier);
            break;
        case CydiaURLResourceKindPackageIcon:
            image = PackageIcon(identifier);
            break;
        case CydiaURLResourceKindUIKitImage:
            image = _UIImageWithName(identifier);
            break;
        case CydiaURLResourceKindSectionIcon:
            image = SectionIcon(identifier);
            break;
        case CydiaURLResourceKindUnknown:
            return CydiaURLResourceResolutionUnhandled;
    }

    NSData *data(EncodeImage(image));
    if (data == nil)
        return CydiaURLResourceResolutionFailed;
    if (PNGData != NULL)
        *PNGData = data;
    return CydiaURLResourceResolutionSucceeded;
}
