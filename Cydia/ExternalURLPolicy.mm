/* Cydia Refurbished external URL boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ExternalURLPolicy.h"

namespace {

BOOL HasControlCharacters(NSString *value) {
    return [value rangeOfCharacterFromSet:
        [NSCharacterSet controlCharacterSet]].location != NSNotFound;
}

BOOL IsStandaloneURL(NSURL *URL) {
    return [URL isKindOfClass:[NSURL class]] && [URL baseURL] == nil &&
        [[URL absoluteString] length] != 0 && [[URL scheme] length] != 0 &&
        !HasControlCharacters([URL absoluteString]);
}

BOOL HasCredentials(NSURL *URL) {
    return [[URL user] length] != 0 || [[URL password] length] != 0;
}

BOOL HasEmptyExplicitPort(NSURL *URL) {
    NSString *absolute([URL absoluteString]);
    NSRange separator([absolute rangeOfString:@"://"]);
    if (separator.location == NSNotFound)
        return NO;
    NSUInteger start(NSMaxRange(separator));
    NSRange tail(NSMakeRange(start, [absolute length] - start));
    NSRange end([absolute rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/?#"]
        options:0 range:tail]);
    NSUInteger finish(end.location == NSNotFound ? [absolute length] : end.location);
    NSString *authority([absolute substringWithRange:NSMakeRange(start, finish - start)]);
    return [authority hasSuffix:@":"];
}

} // namespace

BOOL CydiaExternalURLIsValidWebURL(NSURL *URL) {
    if (!IsStandaloneURL(URL) || HasCredentials(URL) || HasEmptyExplicitPort(URL))
        return NO;
    NSString *scheme([[URL scheme] lowercaseString]);
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
        return NO;

    NSURLComponents *components([NSURLComponents
        componentsWithURL:URL resolvingAgainstBaseURL:NO]);
    if (components == nil || [components URL] == nil ||
        [[components host] length] == 0 ||
        HasControlCharacters([components host]) ||
        [[components host] rangeOfCharacterFromSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
        return NO;
    NSNumber *port([components port]);
    if (port != nil && ([port integerValue] < 1 || [port integerValue] > 65535))
        return NO;
    return YES;
}

namespace {

BOOL IsMailURL(NSURL *URL) {
    if (!IsStandaloneURL(URL) ||
        ![[[URL scheme] lowercaseString] isEqualToString:@"mailto"])
        return NO;
    NSString *specifier([URL resourceSpecifier]);
    NSRange query([specifier rangeOfString:@"?"]);
    NSString *recipient(query.location == NSNotFound ? specifier :
        [specifier substringToIndex:query.location]);
    recipient = [recipient stringByRemovingPercentEncoding] ?: recipient;
    recipient = [recipient stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [recipient length] != 0 && !HasControlCharacters(recipient);
}

BOOL IsAppStoreScheme(NSString *scheme) {
    return [scheme isEqualToString:@"itms"] ||
        [scheme isEqualToString:@"itmss"] ||
        [scheme isEqualToString:@"itms-apps"] ||
        [scheme isEqualToString:@"itms-appss"];
}

BOOL IsAppStoreURL(NSURL *URL) {
    if (!IsStandaloneURL(URL) || HasCredentials(URL))
        return NO;
    NSString *scheme([[URL scheme] lowercaseString]);
    if (!IsAppStoreScheme(scheme))
        return NO;
    NSString *specifier([[URL resourceSpecifier]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    return [specifier length] != 0 && [specifier rangeOfCharacterFromSet:
        [NSCharacterSet alphanumericCharacterSet]].location != NSNotFound;
}

BOOL IsLegacyITunesWebURL(NSURL *URL) {
    if (!CydiaExternalURLIsValidWebURL(URL) ||
        ![[[URL host] lowercaseString] isEqualToString:@"itunes.apple.com"])
        return NO;
    NSNumber *port([URL port]);
    if (port == nil)
        return YES;
    NSInteger value([port integerValue]);
    return ([[[URL scheme] lowercaseString] isEqualToString:@"https"] && value == 443) ||
        ([[[URL scheme] lowercaseString] isEqualToString:@"http"] && value == 80);
}

NSString *DisplayName(NSURL *URL, CydiaExternalURLPresentationKind kind) {
    if (kind == CydiaExternalURLPresentationKindSafari ||
        IsLegacyITunesWebURL(URL))
        return [URL host] ?: [[URL scheme] lowercaseString];
    return [[URL scheme] lowercaseString];
}

} // namespace


@implementation CydiaExternalURLPolicy

- (instancetype)initWithURL:(NSURL *)URL {
    CydiaExternalURLPresentationKind kind;
    if (IsLegacyITunesWebURL(URL) || IsAppStoreURL(URL))
        kind = CydiaExternalURLPresentationKindAppStore;
    else if (CydiaExternalURLIsValidWebURL(URL))
        kind = CydiaExternalURLPresentationKindSafari;
    else if (IsMailURL(URL))
        kind = CydiaExternalURLPresentationKindSystem;
    else
        return nil;

    if ((self = [super init]) != nil) {
        _destinationURL = [URL copy];
        _presentationKind = kind;
        _requiresConfirmation = kind == CydiaExternalURLPresentationKindAppStore;
        _displayName = [DisplayName(URL, kind) copy];
    }
    return self;
}

@end


NSURL *CydiaExternalURLRouteURL(NSURL *URL) {
    CydiaExternalURLPolicy *policy([[CydiaExternalURLPolicy alloc] initWithURL:URL]);
    if (policy == nil)
        return nil;

    NSMutableCharacterSet *allowed([[NSCharacterSet alphanumericCharacterSet] mutableCopy]);
    [allowed addCharactersInString:@"-._~"];
    NSString *encoded([[[policy destinationURL] absoluteString]
        stringByAddingPercentEncodingWithAllowedCharacters:allowed]);
    if ([encoded length] == 0)
        return nil;
    return [NSURL URLWithString:[@"cydia://url/" stringByAppendingString:encoded]];
}
