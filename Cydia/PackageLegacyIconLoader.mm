/* Native loader for the legacy first-party package alternate icon.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageLegacyIconLoader.h"

#include "Cydia/PackageLegacyMetadataPolicy.h"
typedef NS_ENUM(NSUInteger, CydiaPackageLegacyIconPhase) {
    CydiaPackageLegacyIconPhaseMetadata,
    CydiaPackageLegacyIconPhaseImage,
};

@interface CydiaPackageLegacyIconLoader () <NSURLSessionDataDelegate,
                                             NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSURL *metadataURL;
@property(nonatomic, copy) CydiaPackageLegacyIconCompletion completion;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSURL *requestURL;
@property(nonatomic) CydiaPackageLegacyIconPhase phase;
@property(nonatomic) BOOL failed;
@property(nonatomic) BOOL finished;
@end

@implementation CydiaPackageLegacyIconLoader

- (instancetype)initWithPackageIdentity:(NSString *)packageIdentity
                              completion:(CydiaPackageLegacyIconCompletion)completion {
    NSURL *metadataURL(CydiaPackageLegacyMetadataURL(packageIdentity));
    if (metadataURL == nil || completion == nil)
        return nil;
    if ((self = [super init]) != nil) {
        _metadataURL = metadataURL;
        _completion = [completion copy];
        _phase = CydiaPackageLegacyIconPhaseMetadata;
    }
    return self;
}

- (NSUInteger)maximumBytes {
    return _phase == CydiaPackageLegacyIconPhaseMetadata ?
        CydiaPackageLegacyMetadataMaximumBytes() :
        CydiaPackageLegacyIconMaximumBytes();
}

- (BOOL)URLIsAllowedForCurrentPhase:(NSURL *)URL {
    return [URL isKindOfClass:[NSURL class]] &&
        [[URL absoluteString] isEqualToString:[_requestURL absoluteString]];
}

- (void)startRequestWithURL:(NSURL *)URL accept:(NSString *)accept {
    NSMutableURLRequest *request([NSMutableURLRequest requestWithURL:URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0]);
    [request setValue:accept forHTTPHeaderField:@"Accept"];
    _requestURL = URL;
    _data = [NSMutableData data];
    _failed = NO;
    _task = [_session dataTaskWithRequest:request];
    [_task resume];
}

- (void)start {
    if (_finished || _session != nil)
        return;
    NSURLSessionConfiguration *configuration(
        [NSURLSessionConfiguration ephemeralSessionConfiguration]);
    configuration.URLCache = nil;
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil;
    configuration.HTTPMaximumConnectionsPerHost = 1;
    configuration.timeoutIntervalForRequest = 10.0;
    configuration.timeoutIntervalForResource = 20.0;
    _session = [NSURLSession sessionWithConfiguration:configuration
        delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    [self startRequestWithURL:_metadataURL accept:@"application/json, text/javascript"];
}

- (void)finishWithImage:(UIImage *)image {
    if (_finished)
        return;
    _finished = YES;
    CydiaPackageLegacyIconCompletion completion(_completion);
    _completion = nil;
    [_session finishTasksAndInvalidate];
    _session = nil;
    _task = nil;
    _data = nil;
    _requestURL = nil;
    if (completion != nil)
        completion(image);
}

- (void)cancel {
    if (_finished)
        return;
    _completion = nil;
    [_task cancel];
    [_session invalidateAndCancel];
    _session = nil;
    _task = nil;
    _data = nil;
    _requestURL = nil;
    _finished = YES;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
        didReceiveResponse:(NSURLResponse *)response
         completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;
    NSHTTPURLResponse *HTTPResponse([response isKindOfClass:[NSHTTPURLResponse class]] ?
        (NSHTTPURLResponse *)response : nil);
    int64_t expected([response expectedContentLength]);
    BOOL allowed(dataTask == _task && HTTPResponse != nil &&
        [HTTPResponse statusCode] == 200 &&
        [self URLIsAllowedForCurrentPhase:[response URL]] &&
        (expected < 0 || static_cast<uint64_t>(expected) <= [self maximumBytes]));
    _failed = !allowed;
    completionHandler(allowed ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
        didReceiveData:(NSData *)data {
    (void)session;
    if (_failed || dataTask != _task)
        return;
    NSUInteger maximum([self maximumBytes]);
    if ([data length] > maximum - [_data length]) {
        _failed = YES;
        [dataTask cancel];
        return;
    }
    [_data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                       newRequest:(NSURLRequest *)request
                completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    (void)session;
    (void)response;
    (void)request;
    if (task == _task)
        _failed = YES;
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        didCompleteWithError:(NSError *)error {
    (void)session;
    if (task != _task)
        return;
    if (_failed || error != nil) {
        [self finishWithImage:nil];
        return;
    }

    if (_phase == CydiaPackageLegacyIconPhaseMetadata) {
        NSURL *iconURL(CydiaPackageLegacyAlternateIconURL(_data));
        if (iconURL == nil) {
            [self finishWithImage:nil];
            return;
        }
        _phase = CydiaPackageLegacyIconPhaseImage;
        [self startRequestWithURL:iconURL accept:@"image/png"];
        return;
    }

    if (!CydiaPackageLegacyIconPNGDataIsAllowed(_data)) {
        [self finishWithImage:nil];
        return;
    }
    UIImage *image([UIImage imageWithData:_data]);
    [self finishWithImage:image];
}

@end
