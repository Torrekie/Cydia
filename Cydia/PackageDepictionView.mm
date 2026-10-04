/* Cydia Refurbished adaptive package depiction island.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageDepictionView.h"

#include "Cydia/PackageDepictionPolicy.h"
#include "Cydia/PackageDepictionJavaScriptFacade.h"
#include "Cydia/URLResourceResolver.h"
#include "Cydia/URLProtocolPolicy.h"
#include "CyteKit/extern.h"

#include <UIKit/UIGestureRecognizerSubclass.h>

#include <cmath>

namespace {

static void *CydiaPackageDepictionContentSizeContext(
    &CydiaPackageDepictionContentSizeContext);

constexpr CGFloat CydiaPackageDepictionMaximumHeight = 100000.0;
constexpr NSUInteger CydiaPackageDepictionMaximumHeightRevisions = 128;
constexpr CGFloat CydiaPackageDepictionViewportTolerance = 2.0;
constexpr NSTimeInterval CydiaPackageDepictionGestureLifetime = 1.0;
constexpr NSUInteger CydiaPackageDepictionMaximumResourceTasks = 128;
NSString *const CydiaPackageDepictionHeightScript =
    @"Math.max(document.body ? document.body.scrollHeight : 0, "
     @"document.documentElement ? document.documentElement.scrollHeight : 0)";

NSError *DepictionError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"dev.torrekie.cydia.package-depiction"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey:
                                          description ?: @"Unable to load depiction"}];
}

BOOL IsCancellationError(NSError *error) {
    return [[error domain] isEqualToString:NSURLErrorDomain] &&
        [error code] == NSURLErrorCancelled;
}

BOOL NavigationTypeMayFollowTouch(WKNavigationType type) {
    return type == WKNavigationTypeLinkActivated ||
        type == WKNavigationTypeFormSubmitted;
}

void PerformOnMainThreadSynchronously(dispatch_block_t block) {
    if ([NSThread isMainThread])
        block();
    else
        dispatch_sync(dispatch_get_main_queue(), block);
}

} // namespace


@interface CydiaPackageDepictionURLSchemeHandler : NSObject <WKURLSchemeHandler>
- (instancetype)initWithPackageIdentity:(nullable NSString *)packageIdentity
                    userNavigationHandler:(nullable void (^)(NSURL *URL))handler;
@end


@implementation CydiaPackageDepictionURLSchemeHandler {
    NSMutableSet *_activeTasks;
    NSString *_packageIdentity;
    void (^_userNavigationHandler)(NSURL *);
}

- (instancetype)initWithPackageIdentity:(NSString *)packageIdentity
                    userNavigationHandler:(void (^)(NSURL *URL))handler {
    if ((self = [super init]) != nil)
        _activeTasks = [[NSMutableSet alloc] init];
    _packageIdentity = [packageIdentity copy];
    _userNavigationHandler = [handler copy];
    return self;
}

- (instancetype)init {
    return [self initWithPackageIdentity:nil userNavigationHandler:nil];
}

- (void)webView:(WKWebView *)webView
        startURLSchemeTask:(id<WKURLSchemeTask>)task {
    (void)webView;
    __block BOOL admitted(NO);
    PerformOnMainThreadSynchronously(^{
        if ([_activeTasks count] < CydiaPackageDepictionMaximumResourceTasks) {
            [_activeTasks addObject:task];
            admitted = YES;
        } else {
            [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                       code:NSURLErrorDataLengthExceedsMaximum
                                                   userInfo:nil]];
        }
    });
    if (!admitted)
        return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![_activeTasks containsObject:task])
            return;

        NSURL *URL([[task request] URL]);
        NSString *path(CydiaURLResourcePathForURL(URL));

        NSRange slash([path rangeOfString:@"/"]);
        NSString *command(slash.location == NSNotFound ? path :
            [path substringToIndex:slash.location]);
        CydiaURLResourceKind kind(CydiaURLResourceKindForCommand(command));
        if (kind == CydiaURLResourceKindUnknown) {
            /* WKURLSchemeHandler registration is scheme-wide.  On iOS 14 the
             * handler can receive a top-level cydia:// anchor without first
             * delivering WKNavigationDelegate's action callback.  Preserve
             * legacy resource URLs by handling only the unknown-route case;
             * the view callback still requires its short-lived physical-touch
             * token and re-runs the normal URL policy before handoff. */
            if (_userNavigationHandler != nil)
                _userNavigationHandler(URL);
            [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                       code:NSURLErrorUnsupportedURL
                                                   userInfo:nil]];
            [_activeTasks removeObject:task];
            return;
        }
        NSString *rawIdentifier(slash.location == NSNotFound ? nil :
            [path substringFromIndex:slash.location + 1]);
        NSString *identifier(CydiaURLResourceDecodeIdentifier(rawIdentifier, kind));
        if (kind == CydiaURLResourceKindPackageIcon &&
            (_packageIdentity == nil || identifier == nil ||
             ![identifier isEqualToString:_packageIdentity])) {
            [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                       code:NSURLErrorFileDoesNotExist
                                                   userInfo:nil]];
            [_activeTasks removeObject:task];
            return;
        }

        NSData *data(nil);
        CydiaURLResourceResolution resolution(
            CydiaResolveURLResourcePath(path, &data));
        if (![_activeTasks containsObject:task])
            return;

        if (resolution != CydiaURLResourceResolutionSucceeded || data == nil) {
            NSInteger code(resolution == CydiaURLResourceResolutionUnhandled ?
                NSURLErrorUnsupportedURL : NSURLErrorFileDoesNotExist);
            [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                       code:code
                                                   userInfo:nil]];
            [_activeTasks removeObject:task];
            return;
        }

        NSURLResponse *response([[NSURLResponse alloc]
            initWithURL:URL
               MIMEType:@"image/png"
  expectedContentLength:[data length]
       textEncodingName:nil]);
        [task didReceiveResponse:response];
        if (![_activeTasks containsObject:task])
            return;
        [task didReceiveData:data];
        if (![_activeTasks containsObject:task])
            return;
        [task didFinish];
        [_activeTasks removeObject:task];
    });
}

- (void)webView:(WKWebView *)webView
        stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    (void)webView;
    PerformOnMainThreadSynchronously(^{
        [_activeTasks removeObject:task];
    });
}

@end


@interface CydiaPackageDepictionTouchRecognizer : UIGestureRecognizer
- (instancetype)initWithActivationHandler:(void (^)(void))activationHandler
                       invalidationHandler:(void (^)(void))invalidationHandler;
@end


@implementation CydiaPackageDepictionTouchRecognizer {
    void (^_activationHandler)(void);
    void (^_invalidationHandler)(void);
    CGPoint _initialLocation;
    BOOL _trackingTouch;
}

- (instancetype)initWithActivationHandler:(void (^)(void))activationHandler
                       invalidationHandler:(void (^)(void))invalidationHandler {
    if ((self = [super initWithTarget:nil action:nil]) != nil) {
        _activationHandler = [activationHandler copy];
        _invalidationHandler = [invalidationHandler copy];
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([touches count] != 1 || [[event allTouches] count] != 1) {
        if (_invalidationHandler != nil)
            _invalidationHandler();
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    _trackingTouch = YES;
    _initialLocation = [[touches anyObject] locationInView:self.view];
    if (_activationHandler != nil)
        _activationHandler();
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (!_trackingTouch)
        return;
    CGPoint location([[touches anyObject] locationInView:self.view]);
    if (std::hypot(location.x - _initialLocation.x,
                   location.y - _initialLocation.y) > 10.0) {
        _trackingTouch = NO;
        if (_invalidationHandler != nil)
            _invalidationHandler();
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    if (!_trackingTouch) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    _trackingTouch = NO;
    self.state = UIGestureRecognizerStateRecognized;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    _trackingTouch = NO;
    if (_invalidationHandler != nil)
        _invalidationHandler();
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    [super reset];
    _trackingTouch = NO;
}

@end


@interface PackageDepictionView () <WKNavigationDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) WKWebView *depictionWebView;
@property(nonatomic, strong) CydiaPackageDepictionPolicy *policy;
@property(nonatomic, strong) CydiaPackageDepictionJavaScriptFacade *compatibilityFacade;
@property(nonatomic, strong) CydiaPackageDepictionURLSchemeHandler *resourceSchemeHandler;
@property(nonatomic, weak) id<PackageDepictionViewDelegate> delegate;
@property(nonatomic, readwrite) CydiaPackageDepictionViewState state;
@property(nonatomic, readwrite) CGFloat contentHeight;
@property(nonatomic, strong, readwrite) NSError *loadError;
@property(nonatomic, readwrite, getter=hasStartedLoading) BOOL startedLoading;
@property(nonatomic) BOOL initialNavigationPending;
@property(nonatomic) BOOL observingContentSize;
@property(nonatomic) BOOL heightUpdateScheduled;
@property(nonatomic) BOOL heightMeasurementPending;
@property(nonatomic) BOOL heightMeasurementReschedule;
@property(nonatomic) BOOL mainNavigationFinished;
@property(nonatomic) NSUInteger heightRevisionCount;
@property(nonatomic) NSUInteger presentationGeneration;
@property(nonatomic) NSUInteger measurementGeneration;
@property(nonatomic) NSTimeInterval lastUserTouchTime;
@property(nonatomic) NSUInteger userTouchSequence;
@property(nonatomic) NSUInteger invalidatedTouchSequence;
@property(nonatomic) NSInteger lastNavigationType;
@property(nonatomic) BOOL lastNavigationUserActivated;
@property(nonatomic) NSUInteger lastNavigationDisposition;
@property(nonatomic, copy) NSString *lastNavigationURLString;
- (void)handleSchemeNavigationURL:(NSURL *)URL;
@end


@implementation PackageDepictionView

- (instancetype)initWithURLString:(NSString *)URLString
                          delegate:(id<PackageDepictionViewDelegate>)delegate {
    return [self initWithURLString:URLString compatibilitySnapshot:nil delegate:delegate];
}

- (instancetype)initWithURLString:(NSString *)URLString
             compatibilitySnapshot:(NSDictionary *)snapshot
                          delegate:(id<PackageDepictionViewDelegate>)delegate {
    CydiaPackageDepictionPolicy *policy([[CydiaPackageDepictionPolicy alloc]
        initWithURLString:URLString]);
    if (policy == nil)
        return nil;

    if ((self = [super initWithFrame:CGRectZero]) != nil) {
        _policy = policy;
        _delegate = delegate;
        _state = CydiaPackageDepictionViewStateIdle;
        self.clipsToBounds = YES;
        self.accessibilityIdentifier = @"cydia.package.depiction";

        WKWebViewConfiguration *configuration([[WKWebViewConfiguration alloc] init]);
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        configuration.applicationNameForUserAgent =
            CyteApplicationNameForUserAgent();
        configuration.preferences.javaScriptEnabled = YES;
        configuration.allowsInlineMediaPlayback = YES;
        configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
        NSDictionary *packageSnapshot([snapshot objectForKey:@"package"]);
        NSDictionary *packageValues([packageSnapshot objectForKey:@"values"]);
        NSString *packageIdentity([packageValues objectForKey:@"id"]);
        _compatibilityFacade = [[CydiaPackageDepictionJavaScriptFacade alloc]
            initWithSnapshot:snapshot origin:[policy initialURL]
            packageIdentity:packageIdentity];
        [_compatibilityFacade installOnConfiguration:configuration];
        __weak PackageDepictionView *weakSelf(self);
        _resourceSchemeHandler = [[CydiaPackageDepictionURLSchemeHandler alloc]
            initWithPackageIdentity:packageIdentity
                userNavigationHandler:^(NSURL *URL) {
                    [weakSelf handleSchemeNavigationURL:URL];
                }];
        [configuration setURLSchemeHandler:_resourceSchemeHandler
                              forURLScheme:@"cydia"];

        _depictionWebView = [[WKWebView alloc] initWithFrame:CGRectZero
                                              configuration:configuration];
        [_compatibilityFacade bindToWebView:_depictionWebView];
        _depictionWebView.translatesAutoresizingMaskIntoConstraints = NO;
        _depictionWebView.navigationDelegate = self;
        _depictionWebView.allowsBackForwardNavigationGestures = NO;
        _depictionWebView.allowsLinkPreview = NO;
        _depictionWebView.opaque = NO;
        _depictionWebView.backgroundColor = UIColor.clearColor;
        _depictionWebView.accessibilityIdentifier = @"cydia.package.depiction.document";
        self.isAccessibilityElement = NO;
        self.accessibilityElements = @[_depictionWebView];
        _depictionWebView.scrollView.scrollEnabled = NO;
        _depictionWebView.scrollView.bounces = NO;
        _depictionWebView.scrollView.showsHorizontalScrollIndicator = NO;
        _depictionWebView.scrollView.showsVerticalScrollIndicator = NO;
        _depictionWebView.scrollView.backgroundColor = UIColor.clearColor;
        [self addSubview:_depictionWebView];
        [NSLayoutConstraint activateConstraints:@[
            [_depictionWebView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_depictionWebView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_depictionWebView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_depictionWebView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];

        CydiaPackageDepictionTouchRecognizer *touch(
            [[CydiaPackageDepictionTouchRecognizer alloc]
                initWithActivationHandler:^{
                    [weakSelf observedUserTouch];
                }
                invalidationHandler:^{
                    [weakSelf invalidatedUserTouch];
                }]);
        touch.cancelsTouchesInView = NO;
        touch.delaysTouchesBegan = NO;
        touch.delaysTouchesEnded = NO;
        touch.delegate = self;
        [_depictionWebView addGestureRecognizer:touch];

        [_depictionWebView.scrollView addObserver:self
                                       forKeyPath:@"contentSize"
                                          options:NSKeyValueObservingOptionInitial |
                                                  NSKeyValueObservingOptionNew
                                          context:CydiaPackageDepictionContentSizeContext];
        _observingContentSize = YES;
    }
    return self;
}

- (void)dealloc {
    [_compatibilityFacade revokeFromConfiguration:[_depictionWebView configuration]];
    _depictionWebView.navigationDelegate = nil;
    if (_observingContentSize) {
        [_depictionWebView.scrollView removeObserver:self
                                          forKeyPath:@"contentSize"
                                             context:CydiaPackageDepictionContentSizeContext];
    }
}

- (NSURL *)initialURL {
    return [_policy initialURL];
}

- (void)startLoading {
    if (_startedLoading)
        return;
    _startedLoading = YES;
    _initialNavigationPending = YES;
    [self resetPresentationForLoad];
    NSURLRequest *request([NSURLRequest requestWithURL:[_policy initialURL]
                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                       timeoutInterval:30.0]);
    [_depictionWebView loadRequest:request];
}

- (void)retryLoading {
    if (!_startedLoading) {
        [self startLoading];
        return;
    }
    [_compatibilityFacade rotateForReloadOnConfiguration:[_depictionWebView configuration]];
    _initialNavigationPending = YES;
    [self resetPresentationForLoad];
    NSURLRequest *request([NSURLRequest requestWithURL:[_policy initialURL]
                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                       timeoutInterval:30.0]);
    [_depictionWebView loadRequest:request];
}

#if TARGET_OS_SIMULATOR
- (void)cydiaProbeResourceImageStateWithCompletion:
        (void (^)(id result, NSError *error))completion {
    NSString *script(
        @"(function(){"
         "var good=document.getElementById('cydia-resource');"
         "var bad=document.getElementById('cydia-resource-rejected');"
         "var facade=document.getElementById('cydia-facade-marker');"
         "return JSON.stringify({"
         "goodSource:good?good.getAttribute('src'):'',"
         "goodComplete:!!(good&&good.complete),"
         "goodWidth:good?good.naturalWidth:0,"
         "goodHeight:good?good.naturalHeight:0,"
         "badSource:bad?bad.getAttribute('src'):'',"
         "badComplete:!!(bad&&bad.complete),"
         "badWidth:bad?bad.naturalWidth:0,"
         "facadeText:facade?facade.textContent:''});"
         "})()");
    [_depictionWebView evaluateJavaScript:script completionHandler:completion];
}
#endif

- (void)resetPresentationForLoad {
    ++_presentationGeneration;
    _heightRevisionCount = 0;
    _heightMeasurementPending = NO;
    _heightMeasurementReschedule = NO;
    _mainNavigationFinished = NO;
    _contentHeight = 0.0;
    _loadError = nil;
    _depictionWebView.hidden = NO;
    [self setStateAndNotify:CydiaPackageDepictionViewStateLoading];
}

- (void)setStateAndNotify:(CydiaPackageDepictionViewState)state {
    _state = state;
    [[self delegate] packageDepictionViewDidChangePresentation:self];
}

- (void)failWithState:(CydiaPackageDepictionViewState)state
                 error:(NSError *)error {
    [_depictionWebView stopLoading];
    _initialNavigationPending = NO;
    _contentHeight = 0.0;
    _loadError = error;
    _depictionWebView.hidden = YES;
    [self setStateAndNotify:state];
}

- (void)observedUserTouch {
    ++_userTouchSequence;
    _lastUserTouchTime = [NSDate timeIntervalSinceReferenceDate];
}

- (void)invalidatedUserTouch {
    ++_invalidatedTouchSequence;
    _lastUserTouchTime = 0.0;
}

- (void)handleSchemeNavigationURL:(NSURL *)URL {
    if (![URL isKindOfClass:[NSURL class]])
        return;
    BOOL userActivated([self consumeUserTouchForNavigationType:WKNavigationTypeLinkActivated]);
    CydiaPackageDepictionNavigationDisposition disposition([_policy
        decisionForURL:URL mainFrame:YES initialRequest:NO
                intent:userActivated ? CydiaPackageDepictionNavigationIntentUserActivated :
                                       CydiaPackageDepictionNavigationIntentAutomatic]);
    _lastNavigationType = WKNavigationTypeLinkActivated;
    _lastNavigationUserActivated = userActivated;
    _lastNavigationDisposition = disposition;
    _lastNavigationURLString = [URL.absoluteString copy] ?: @"";
    if (userActivated &&
        disposition == CydiaPackageDepictionNavigationDispositionHandOff) {
        [[self delegate] packageDepictionView:self didRequestURLHandoff:URL];
    }
}

- (BOOL)consumeUserTouchForNavigationType:(WKNavigationType)type {
    NSTimeInterval touch(_lastUserTouchTime);
    _lastUserTouchTime = 0.0;
    return NavigationTypeMayFollowTouch(type) && touch != 0.0 &&
        [NSDate timeIntervalSinceReferenceDate] - touch <=
            CydiaPackageDepictionGestureLifetime;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gestureRecognizer;
    (void)other;
    return YES;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context != CydiaPackageDepictionContentSizeContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (_heightMeasurementPending) {
        _heightMeasurementReschedule = YES;
        return;
    }
    if (_heightUpdateScheduled)
        return;
    _heightUpdateScheduled = YES;
    __weak PackageDepictionView *weakSelf(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        PackageDepictionView *strongSelf(weakSelf);
        strongSelf.heightUpdateScheduled = NO;
        [strongSelf requestMeasuredHeight];
    });
}

- (void)requestMeasuredHeight {
    if (_state == CydiaPackageDepictionViewStateFailed ||
        _state == CydiaPackageDepictionViewStatePathologicalContent ||
        _state == CydiaPackageDepictionViewStateIdle || !_mainNavigationFinished)
        return;
    if (_heightMeasurementPending) {
        _heightMeasurementReschedule = YES;
        return;
    }
    _heightMeasurementPending = YES;
    _heightMeasurementReschedule = NO;
    NSUInteger generation(_presentationGeneration);
    _measurementGeneration = generation;
    __weak PackageDepictionView *weakSelf(self);
    [_depictionWebView evaluateJavaScript:CydiaPackageDepictionHeightScript
                         completionHandler:^(id result, NSError *error) {
        PackageDepictionView *strongSelf(weakSelf);
        if (strongSelf == nil || strongSelf.presentationGeneration != generation ||
            strongSelf.measurementGeneration != generation)
            return;
        strongSelf.heightMeasurementPending = NO;
        if (error != nil || ![result isKindOfClass:[NSNumber class]]) {
            [strongSelf failWithState:CydiaPackageDepictionViewStateFailed
                                error:error ?: DepictionError(
                                    6, @"Depiction height was not numeric")];
            return;
        }
        [strongSelf applyMeasuredHeight:[result doubleValue]];
        if (strongSelf.heightMeasurementReschedule) {
            strongSelf.heightMeasurementReschedule = NO;
            [strongSelf requestMeasuredHeight];
        }
    }];
}

- (void)applyMeasuredHeight:(CGFloat)value {
    CGFloat measured(std::ceil(value));
    if (!std::isfinite(measured) || measured <= 0.0) {
        [self failWithState:CydiaPackageDepictionViewStateFailed
                      error:DepictionError(7, @"Depiction height was empty")];
        return;
    }
    CGFloat viewport(CGRectGetHeight(_depictionWebView.bounds));
    if (_contentHeight > 0.0 &&
        std::fabs(viewport - _contentHeight) < CydiaPackageDepictionViewportTolerance &&
        std::fabs(measured - viewport) < CydiaPackageDepictionViewportTolerance) {
        if (_mainNavigationFinished && _state == CydiaPackageDepictionViewStateLoading)
            [self setStateAndNotify:CydiaPackageDepictionViewStateLoaded];
        return;
    }
    if (measured > CydiaPackageDepictionMaximumHeight ||
        _heightRevisionCount >= CydiaPackageDepictionMaximumHeightRevisions) {
        [self failWithState:CydiaPackageDepictionViewStatePathologicalContent
                      error:DepictionError(2, @"Depiction content did not settle")];
        return;
    }
    if (std::fabs(measured - _contentHeight) >= 0.5) {
        ++_heightRevisionCount;
        _contentHeight = measured;
        [[self delegate] packageDepictionViewDidChangePresentation:self];
    }
    if (_mainNavigationFinished && _state == CydiaPackageDepictionViewStateLoading)
        [self setStateAndNotify:CydiaPackageDepictionViewStateLoaded];
}

- (void)webView:(WKWebView *)webView
        decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                        decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    BOOL mainFrame(navigationAction.targetFrame == nil ||
                   navigationAction.targetFrame.isMainFrame);
    BOOL userActivated([self consumeUserTouchForNavigationType:navigationAction.navigationType]);
    BOOL initial(_initialNavigationPending && mainFrame);
    CydiaPackageDepictionNavigationDisposition disposition([_policy
        decisionForURL:navigationAction.request.URL
             mainFrame:mainFrame
        initialRequest:initial
                intent:userActivated ? CydiaPackageDepictionNavigationIntentUserActivated :
                                       CydiaPackageDepictionNavigationIntentAutomatic]);
    _lastNavigationType = navigationAction.navigationType;
    _lastNavigationUserActivated = userActivated;
    _lastNavigationDisposition = disposition;
    _lastNavigationURLString = [navigationAction.request.URL.absoluteString copy] ?: @"";
    if (disposition == CydiaPackageDepictionNavigationDispositionLoadInIsland) {
        if (initial)
            _initialNavigationPending = NO;
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    decisionHandler(WKNavigationActionPolicyCancel);
    if (disposition == CydiaPackageDepictionNavigationDispositionHandOff) {
        [[self delegate] packageDepictionView:self
                         didRequestURLHandoff:navigationAction.request.URL];
    } else if (mainFrame && !userActivated) {
        [self failWithState:CydiaPackageDepictionViewStateFailed
                      error:DepictionError(3, @"Depiction navigation was rejected")];
    }
}

- (void)webView:(WKWebView *)webView
        decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                        decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    (void)webView;
    BOOL mainFrame(navigationResponse.isForMainFrame);
    BOOL successfulHTTPResponse(YES);
    if (mainFrame &&
        [navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger statusCode([(NSHTTPURLResponse *)navigationResponse.response statusCode]);
        successfulHTTPResponse = statusCode >= 200 && statusCode < 300;
    }
    if (navigationResponse.canShowMIMEType && successfulHTTPResponse &&
        [_policy allowsResponseURL:navigationResponse.response.URL mainFrame:mainFrame]) {
        decisionHandler(WKNavigationResponsePolicyAllow);
        return;
    }
    decisionHandler(WKNavigationResponsePolicyCancel);
    if (mainFrame) {
        [self failWithState:CydiaPackageDepictionViewStateFailed
                      error:DepictionError(4, @"Depiction response was rejected")];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)webView;
    (void)navigation;
    _mainNavigationFinished = YES;
    [self requestMeasuredHeight];
}

- (void)webView:(WKWebView *)webView
        didFailProvisionalNavigation:(WKNavigation *)navigation
                           withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    if (!IsCancellationError(error))
        [self failWithState:CydiaPackageDepictionViewStateFailed error:error];
}

- (void)webView:(WKWebView *)webView
        didFailNavigation:(WKNavigation *)navigation
                withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    if (!IsCancellationError(error))
        [self failWithState:CydiaPackageDepictionViewStateFailed error:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    (void)webView;
    [self failWithState:CydiaPackageDepictionViewStateFailed
                  error:DepictionError(5, @"Depiction content process terminated")];
}

@end
