/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/ApplicationExtensionsProvider.h"
#include "Cydia/PrivateServices.h"
#import <UIKit/UIKit.h>
#include <objc/message.h>

@interface CydiaExtensionsHTTP : NSObject <CydiaExtensionsRequest, NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *bytes;
@property(nonatomic, copy) void (^completion)(NSData *, NSError *);
@property(nonatomic) BOOL finished;
- (instancetype)initWithPath:(NSString *)path method:(NSString *)method
    completion:(void (^)(NSData *, NSError *))completion;
@end
@implementation CydiaExtensionsHTTP
- (instancetype)initWithPath:(NSString *)path method:(NSString *)method
        completion:(void (^)(NSData *, NSError *))completion {
    if ((self = [super init])) {
        _bytes = [NSMutableData data]; _completion = [completion copy];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 20;
        configuration.timeoutIntervalForResource = 30;
        configuration.HTTPMaximumConnectionsPerHost = 4;
        configuration.HTTPShouldSetCookies = NO;
        configuration.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self
            delegateQueue:NSOperationQueue.mainQueue];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:[@"https://cydia.saurik.com" stringByAppendingString:path]]];
        request.HTTPMethod = method;
        // The global count lookup is the original empty POST. Never send local names/IDs.
        request.HTTPBody = nil;
        [request setValue:[path isEqual:@"/api/application"] ? @"application/json" : @"text/html,image/png"
            forHTTPHeaderField:@"Accept"];
        _task = [_session dataTaskWithRequest:request];
        [_task resume];
    }
    return self;
}
- (void)finish:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    void (^completion)(NSData *, NSError *) = _completion;
    _completion = nil;
    NSData *data = error == nil ? [_bytes copy] : nil;
    [_session invalidateAndCancel]; _session = nil; _task = nil; _bytes = nil;
    if (completion) completion(data, error);
}
- (void)cancel {
    _completion = nil;
    [self finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
        completionHandler:(void (^)(NSURLRequest *))completion {
    // Fixed-origin catalog requests never redirect into another service, file or HTTP.
    completion(nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
        didReceiveResponse:(NSURLResponse *)response
        completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    BOOL valid = [response isKindOfClass:NSHTTPURLResponse.class] && status >= 200 && status < 300 &&
        response.expectedContentLength <= 4 * 1024 * 1024;
    completion(valid ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
    if (!valid) [self finish:[NSError errorWithDomain:NSURLErrorDomain
        code:NSURLErrorBadServerResponse userInfo:nil]];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (_finished) return;
    if (_bytes.length + data.length > 4 * 1024 * 1024) {
        [self finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorDataLengthExceedsMaximum userInfo:nil]];
        return;
    }
    [_bytes appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self finish:error];
}
@end

@implementation CydiaApplicationExtensionsProvider
- (NSData *)localIconDataForBundleIdentifier:(NSString *)identifier {
    if (!CydiaExtensionIdentifierIsValid(identifier)) return nil;
    NSData *data = CydiaCopyApplicationIconPNGData(identifier);
    if (data.length) return data;
    // Newer SpringBoardServices can retain the old symbol but return no PNG
    // or icon path. Resolve UIKit's local-app icon source only when available;
    // iOS12 and missing services retain the controller's file/unknown fallback.
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:selector]) return nil;
    UIImage *icon = ((UIImage *(*)(id, SEL, NSString *, int, CGFloat))objc_msgSend)(
        UIImage.class, selector, identifier, 2, UIScreen.mainScreen.scale);
    return [icon isKindOfClass:UIImage.class] ? UIImagePNGRepresentation(icon) : nil;
}
- (NSString *)localizedNameForBundleIdentifier:(NSString *)identifier {
    return CydiaExtensionIdentifierIsValid(identifier) ? CydiaCopyLocalizedApplicationName(identifier) : nil;
}
- (id<CydiaExtensionsRequest>)loadRowsForBundleIdentifier:(NSString *)identifier
        completion:(CydiaExtensionsRowsCompletion)completion {
    NSAssert(NSThread.isMainThread, @"Catalog callbacks and local snapshots are main-thread confined");
    BOOL root = identifier == nil;
    NSString *path = root ? @"/api/application" :
        [NSString stringWithFormat:@"/application/%@/", identifier];
    if (!root && !CydiaExtensionIdentifierIsValid(identifier)) return nil;
    return [[CydiaExtensionsHTTP alloc] initWithPath:path method:root ? @"POST" : @"GET"
        completion:^(NSData *data, NSError *error) {
            if (error != nil) { completion(nil, error); return; }
            NSArray *rows;
            NSError *parseError = nil;
            if (root) {
                NSArray *identifiers = CydiaCopyApplicationDisplayIdentifiers(false, false);
                if (identifiers == nil) {
                    completion(nil, [NSError errorWithDomain:@"CydiaApplicationExtensions" code:2
                        userInfo:@{NSLocalizedDescriptionKey:@"Installed applications are unavailable."}]);
                    return;
                }
                NSMutableDictionary *names = [NSMutableDictionary dictionary];
                NSMutableDictionary *icons = [NSMutableDictionary dictionary];
                for (NSString *bundle in identifiers) {
                    if (!CydiaExtensionIdentifierIsValid(bundle)) continue;
                    NSString *name = CydiaCopyLocalizedApplicationName(bundle);
                    if (name.length) names[bundle] = name;
                    NSString *icon = CydiaCopyIconImagePath(bundle);
                    if (icon) icons[bundle] = icon;
                }
                rows = CydiaExtensionApplicationRows(data, names, icons, &parseError);
            } else {
                rows = CydiaExtensionPackageRows(data, &parseError);
            }
            completion(rows, parseError);
        }];
}
- (id<CydiaExtensionsRequest>)loadIconURL:(NSURL *)URL completion:(void (^)(NSData *))completion {
    NSURL *safe = CydiaExtensionIconURL(URL.absoluteString);
    if (safe == nil) return nil;
    return [[CydiaExtensionsHTTP alloc] initWithPath:safe.path method:@"GET"
        completion:^(NSData *data, NSError *error) { completion(error == nil ? data : nil); }];
}
@end
