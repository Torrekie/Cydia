/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/PackageRecordIconLoader.h"
#import "Cydia/ExternalURLPolicy.h"
#import "Cydia/PackageLegacyMetadataPolicy.h"
#import "Cydia/RepositoryIdentity.h"
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <cmath>

namespace {
BOOL SafeIconURL(NSURL *URL) {
    if (!CydiaExternalURLIsValidWebURL(URL) || URL.absoluteString.length > 4096) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    // Reject even empty explicit userinfo rather than relying on an HTTP
    // implementation to decide whether it should become credentials.
    return components && components.user == nil && components.password == nil;
}
NSURL *NetworkIconURL(NSURL *URL) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    components.fragment = nil;
    return components.URL;
}
NSMutableURLRequest *IconRequest(NSURL *URL) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
    request.HTTPShouldHandleCookies = NO;
    [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
    [request setValue:CydiaRepositoryDownloadUserAgent() forHTTPHeaderField:@"User-Agent"];
    return request;
}
UIImage *DecodeIcon(NSData *data, CGFloat scale) {
    if (!data.length || data.length > CydiaPackageLegacyIconMaximumBytes()) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data,
        (__bridge CFDictionaryRef)@{(__bridge id)kCGImageSourceShouldCache: @NO});
    if (!source) return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0,
        (__bridge CFDictionaryRef)@{(__bridge id)kCGImageSourceShouldCache: @NO}));
    id width = properties[(__bridge id)kCGImagePropertyPixelWidth];
    id height = properties[(__bridge id)kCGImagePropertyPixelHeight];
    const int64_t w = [width isKindOfClass:NSNumber.class] ? [width longLongValue] : 0;
    const int64_t h = [height isKindOfClass:NSNumber.class] ? [height longLongValue] : 0;
    // Check encoded dimensions before decoding. The first frame is reduced
    // directly by ImageIO, without constructing a full-sized UIImage.
    const BOOL dimensions = w > 0 && h > 0 && w <= 4096 && h <= 4096 &&
        static_cast<uint64_t>(w) * static_cast<uint64_t>(h) <= 16ULL * 1024 * 1024;
    if (!dimensions) { CFRelease(source); return nil; }
    const NSUInteger pixels = static_cast<NSUInteger>(std::ceil(192.0 * scale));
    NSDictionary *options = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @(pixels),
        (__bridge id)kCGImageSourceShouldCache: @NO,
        (__bridge id)kCGImageSourceShouldCacheImmediately: @YES
    };
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!thumbnail) return nil;
    UIImage *image = CGImageGetWidth(thumbnail) <= pixels && CGImageGetHeight(thumbnail) <= pixels ?
        [UIImage imageWithCGImage:thumbnail scale:scale orientation:UIImageOrientationUp] : nil;
    CGImageRelease(thumbnail);
    return image;
}
}

@interface CydiaPackageRecordIconLoader () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, copy) CydiaPackageRecordIconCompletion completion;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, copy) NSURL *requestURL;
@property(nonatomic) NSUInteger redirects;
@property(nonatomic) CGFloat imageScale;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL failed;
@property(nonatomic) BOOL responseAccepted;
@property(nonatomic) BOOL finished;
@end

@implementation CydiaPackageRecordIconLoader
- (instancetype)initWithURL:(NSURL *)URL completion:(CydiaPackageRecordIconCompletion)completion {
    if (!SafeIconURL(URL) || !completion) return nil;
    if ((self = [super init])) { _sourceURL = [URL copy]; _completion = [completion copy]; }
    return self;
}
- (void)start {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); return; }
    if (_started || _finished) return;
    _started = YES; _data = [NSMutableData data];
    const CGFloat screenScale = UIScreen.mainScreen.scale;
    _imageScale = std::isfinite(screenScale) ? std::max<CGFloat>(1, std::min<CGFloat>(3, screenScale)) : 1;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil;
    configuration.HTTPMaximumConnectionsPerHost = 1;
    configuration.timeoutIntervalForRequest = 10.0;
    configuration.timeoutIntervalForResource = 20.0;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    _requestURL = NetworkIconURL(_sourceURL);
    _task = [_session dataTaskWithRequest:IconRequest(_requestURL)];
    [_task resume];
}
- (void)finishWithImage:(UIImage *)image {
    if (_finished) return;
    _finished = YES;
    CydiaPackageRecordIconCompletion completion = _completion; _completion = nil;
    [_session invalidateAndCancel];
    _session = nil; _task = nil; _data = nil; _requestURL = nil;
    if (completion) completion(image);
}
- (void)cancel {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self cancel]; }); return; }
    if (_finished) return;
    _completion = nil; [self finishWithImage:nil];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
        didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    (void)session;
    if (_finished || task != _task) { completion(NSURLSessionResponseCancel); return; }
    NSHTTPURLResponse *HTTP = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    const int64_t expected = response.expectedContentLength;
    _responseAccepted = HTTP && HTTP.statusCode == 200 &&
        SafeIconURL(response.URL) && [response.URL isEqual:_requestURL] &&
        (expected < 0 || static_cast<uint64_t>(expected) <= CydiaPackageLegacyIconMaximumBytes());
    _failed = !_responseAccepted;
    completion(_responseAccepted ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    if (_finished || _failed || !_responseAccepted || task != _task) return;
    const NSUInteger maximum = CydiaPackageLegacyIconMaximumBytes();
    if (data.length > maximum - _data.length) { _failed = YES; [task cancel]; return; }
    [_data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
        completionHandler:(void (^)(NSURLRequest * _Nullable))completion {
    (void)session; (void)response;
    const BOOL downgrade = [_requestURL.scheme.lowercaseString isEqual:@"https"] &&
        [request.URL.scheme.lowercaseString isEqual:@"http"];
    if (_finished || task != _task || _redirects >= 3 || !SafeIconURL(request.URL) || downgrade) {
        _failed = YES; completion(nil); return;
    }
    ++_redirects; _requestURL = NetworkIconURL(request.URL);
    // Build a fresh anonymous GET for the approved destination rather than
    // forwarding cookies, authorization, or other redirect-supplied headers.
    completion(IconRequest(_requestURL));
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
        completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completion {
    (void)session;
    completion([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust] ?
        NSURLSessionAuthChallengePerformDefaultHandling : NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
        completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completion {
    (void)task;
    [self URLSession:session didReceiveChallenge:challenge completionHandler:completion];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session;
    if (_finished || task != _task) return;
    if (_failed || !_responseAccepted || error) { [self finishWithImage:nil]; return; }
    NSData *bytes = [_data copy]; _data = nil;
    [_session finishTasksAndInvalidate]; _session = nil; _task = nil;
    const CGFloat scale = _imageScale;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            UIImage *image = DecodeIcon(bytes, scale);
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithImage:image]; });
        }
    });
}
@end
