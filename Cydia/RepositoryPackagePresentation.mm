/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RepositoryPackagePresentation.h"
#import <CoreFoundation/CoreFoundation.h>

namespace {
bool JSONBoolean(id value, bool *result) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return false;
    *result = [value boolValue]; return true;
}
NSURL *PublicPurchaseURL(NSURL *URL) {
    if (![URL isKindOfClass:NSURL.class] || !URL.absoluteString.length ||
        URL.absoluteString.length > 8192 ||
        [URL.absoluteString rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (![parts.scheme.lowercaseString isEqualToString:@"https"] || !parts.host.length ||
        parts.user != nil || parts.password != nil || parts.fragment != nil || parts.query != nil ||
        (parts.port != nil && (parts.port.integerValue < 1 || parts.port.integerValue > 65535))) return nil;
    NSString *decoded = URL.absoluteString.stringByRemovingPercentEncoding;
    if (decoded == nil || [decoded rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return nil;
    return [URL copy];
}
} // namespace

NSURL *CydiaRepositoryPublicWebsite(NSURL *URL) { return PublicPurchaseURL(URL); }
NSURL *CydiaRepositoryPurchaseWebsite(NSURL *sourceURL, NSURL *packageWebsite) {
    NSURL *website = PublicPurchaseURL(packageWebsite);
    NSURL *source = PublicPurchaseURL(sourceURL);
    /* Chariz documents explicit product buy pages, not a package-ID to slug
     * mapping. Use only the URL supplied by the selected package record. */
    if (![source.host.lowercaseString isEqual:@"repo.chariz.com"] ||
        ![website.host.lowercaseString isEqual:@"chariz.com"] ||
        (source.port != nil && source.port.integerValue != 443) ||
        (website.port != nil && website.port.integerValue != 443)) return nil;
    NSArray<NSString *> *parts = website.path.pathComponents;
    NSCharacterSet *slug = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    if (parts.count != 3 || ![parts[1] isEqual:@"buy"] || ![parts[2] length] ||
        [parts[2] rangeOfCharacterFromSet:slug.invertedSet].location != NSNotFound) return nil;
    return website;
}

@implementation CydiaRepositoryPackagePresentation
- (instancetype)initWithInfo:(NSDictionary *)info signedIn:(BOOL)signedIn
                   supported:(BOOL)supported downloadAvailable:(BOOL)downloadAvailable
                 purchaseURL:(NSURL *)purchaseURL {
    if ((self = [super init])) {
        _state = CydiaRepositoryPackageStateUnknown;
        if (!supported) { _state = CydiaRepositoryPackageStateUnavailable; return self; }
        bool available(false), purchased(false);
        if (![info isKindOfClass:NSDictionary.class] || !JSONBoolean(info[@"available"], &available)) return self;
        /* A vendor-reported error cannot become a purchase/download action.
         * Keep vendor text out of this model; the UI uses its own error state. */
        id error = info[@"error"];
        if (error != nil && error != NSNull.null) return self;
        id success = info[@"success"];
        bool successful(false);
        if (success != nil && (!JSONBoolean(success, &successful) || !successful)) return self;
        if (!available) { _state = CydiaRepositoryPackageStateUnavailable; return self; }
        if (!signedIn) { _state = CydiaRepositoryPackageStateSignIn; return self; }
        if (!JSONBoolean(info[@"purchased"], &purchased)) return self;
        if (purchased) {
            _state = downloadAvailable ? CydiaRepositoryPackageStateDownload : CydiaRepositoryPackageStateOwned;
            return self;
        }
        _purchaseURL = PublicPurchaseURL(purchaseURL);
        _state = _purchaseURL != nil ? CydiaRepositoryPackageStateBuy : CydiaRepositoryPackageStateNotPurchased;
    }
    return self;
}
@end
