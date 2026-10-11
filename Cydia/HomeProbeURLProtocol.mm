/* Cydia Refurbished native Home simulator URL recorder.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/HomeProbeURLProtocol.h"

#if TARGET_OS_SIMULATOR && defined(CYDIA_HOME_SIMULATOR_PROBE)

/* Probe-only URL loading recorder. The canary makes registration observable;
 * any legacy Application Cache request is counted without network access. */
static NSUInteger HomeProbeProtocolCanaryCount;
static NSUInteger HomeProbeAppCacheRequestCount;
static NSUInteger HomeProbeRemoteHomeCanaryCount;
static NSUInteger HomeProbeUnexpectedRemoteHomeRequestCount;
static NSMutableArray<NSString *> *HomeProbeProtocolURLs;

void HomeProbeProtocolReset(void) {
    @synchronized([CydiaHomeProbeURLProtocol class]) {
        HomeProbeProtocolCanaryCount = 0;
        HomeProbeAppCacheRequestCount = 0;
        HomeProbeRemoteHomeCanaryCount = 0;
        HomeProbeUnexpectedRemoteHomeRequestCount = 0;
        HomeProbeProtocolURLs = [NSMutableArray array];
    }
}

NSDictionary *HomeProbeProtocolSnapshot(void) {
    @synchronized([CydiaHomeProbeURLProtocol class]) {
        return @{
            @"canaryCount": @(HomeProbeProtocolCanaryCount),
            @"appCacheRequestCount": @(HomeProbeAppCacheRequestCount),
            @"remoteHomeCanaryCount": @(HomeProbeRemoteHomeCanaryCount),
            @"unexpectedRemoteHomeRequestCount":
                @(HomeProbeUnexpectedRemoteHomeRequestCount),
            @"URLs": [HomeProbeProtocolURLs copy] ?: @[],
        };
    }
}

@implementation CydiaHomeProbeURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSURL *URL(request.URL);
    NSString *scheme(URL.scheme.lowercaseString);
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
        return NO;
    NSString *path(URL.path ?: @"");
    BOOL canary([URL.host.lowercaseString isEqualToString:@"cydia.saurik.com"] &&
                [path isEqualToString:@"/__cydia_home_probe_canary__"]);
    BOOL appCache([path rangeOfString:@"/appcache/"
                         options:NSCaseInsensitiveSearch].location != NSNotFound ||
                 [path hasSuffix:@"/appcache"]);
    BOOL remoteHome([path hasPrefix:@"/ui/ios~"] &&
        ([path hasSuffix:@"/1.1"] || [path hasSuffix:@"/1.1/"] ||
         [path hasSuffix:@"/1.1/home"] || [path hasSuffix:@"/1.1/home/"]));
    return canary || appCache || remoteHome;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSURL *URL(self.request.URL);
    NSString *path(URL.path ?: @"");
    BOOL canary([URL.host.lowercaseString isEqualToString:@"cydia.saurik.com"] &&
                [path isEqualToString:@"/__cydia_home_probe_canary__"]);
    BOOL appCache([path rangeOfString:@"/appcache/"
                         options:NSCaseInsensitiveSearch].location != NSNotFound ||
                 [path hasSuffix:@"/appcache"]);
    BOOL remoteHome([path hasPrefix:@"/ui/ios~"] &&
        ([path hasSuffix:@"/1.1"] || [path hasSuffix:@"/1.1/"] ||
         [path hasSuffix:@"/1.1/home"] || [path hasSuffix:@"/1.1/home/"]));
    BOOL remoteHomeCanary(remoteHome &&
        [URL.query isEqualToString:@"cydia-home-probe=1"]);
    @synchronized([CydiaHomeProbeURLProtocol class]) {
        if (HomeProbeProtocolURLs == nil)
            HomeProbeProtocolURLs = [NSMutableArray array];
        [HomeProbeProtocolURLs addObject:URL.absoluteString ?: @""];
        if (canary)
            ++HomeProbeProtocolCanaryCount;
        if (appCache)
            ++HomeProbeAppCacheRequestCount;
        if (remoteHomeCanary)
            ++HomeProbeRemoteHomeCanaryCount;
        else if (remoteHome)
            ++HomeProbeUnexpectedRemoteHomeRequestCount;
    }

    NSData *body(canary ? [@"home-probe-canary" dataUsingEncoding:NSUTF8StringEncoding] :
                 [NSData data]);
    NSHTTPURLResponse *response([[NSHTTPURLResponse alloc]
        initWithURL:URL statusCode:canary ? 200 : 204 HTTPVersion:@"HTTP/1.1"
        headerFields:@{ @"Content-Length": [NSString stringWithFormat:@"%lu",
                                               (unsigned long)body.length] }]);
    [self.client URLProtocol:self didReceiveResponse:response
        cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (body.length != 0)
        [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

#endif
