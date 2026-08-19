/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#ifndef CyteKit_WebViewControllerPrivate_H
#define CyteKit_WebViewControllerPrivate_H

#include "CyteKit/UCPlatform.h"

#include "CyteKit/IndirectDelegate.h"
#include "CyteKit/Localize.h"
#include "CyteKit/MFMailComposeViewController-MailToURL.h"
#include "CyteKit/RegEx.hpp"
#include "CyteKit/WebFrame+Cydia.h"
#include "CyteKit/WebThreadLocked.hpp"
#include "CyteKit/WebViewController.h"

#include "iPhonePrivate.h"
#include "Menes/ObjectHandle.h"

#define ForSaurik 0
#define DefaultTimeout_ 120.0

#define ShowInternals 0
#define LogBrowser 0
#define LogMessages 0

#define lprintf(args...) fprintf(stderr, args)

extern float CYScrollViewDecelerationRateNormal;

@interface CyteWebViewController () {
    _H<CyteWebView, 1> webview_;
    __weak UIScrollView *scroller_;

    _H<UIActivityIndicatorView> indicator_;
    _H<IndirectDelegate, 1> indirect_;
    _H<NSURLAuthenticationChallenge> challenge_;

    bool error_;
    _H<NSURLRequest> request_;
    bool ready_;

    NSNumber *sensitive_;
    _H<NSURL> appstore_;

    _H<NSString> title_;
    _H<NSMutableSet> loading_;

    _H<NSMutableSet> registered_;
    _H<NSTimer> timer_;

    // XXX: NSString * or UIImage *
    _H<NSObject> custom_;
    _H<NSString> style_;

    _H<WebScriptObject> function_;

    float width_;
    Class class_;

    _H<UIBarButtonItem> reloaditem_;
    _H<UIBarButtonItem> loadingitem_;

    bool visible_;
    bool hidesNavigationBar_;
    bool allowsNavigationAction_;
}

- (NSURL *) URLWithURL:(NSURL *)url;
- (NSURLRequest *) requestWithURL:(NSURL *)url cachePolicy:(NSURLRequestCachePolicy)policy referrer:(NSString *)referrer;
- (bool) retainsNetworkActivityIndicator;
- (bool) _allowJavaScriptPanel;
- (bool) allowsNavigationAction;
- (void) setAllowsNavigationAction:(bool)value;
- (void) _didFailWithError:(NSError *)error forFrame:(WebFrame *)frame;
- (void) pushRequest:(NSURLRequest *)request forAction:(NSDictionary *)action asPop:(bool)pop;
- (void) _openMailToURL:(NSURL *)url;
- (void) _didStartLoading;
- (void) _didFinishLoading;
- (void) _setViewportWidth;
- (void) setViewportWidth:(float)width;
- (void) applyColorAppearance;
- (void) applyLoadingTitle;
- (void) layoutRightButton;
- (UIBarButtonItemStyle) rightButtonStyle;
- (UIBarButtonItem *) customButton;
- (void) _setHidesNavigationBar:(bool)value animated:(bool)animated;
- (bool) hidesNavigationBar;
- (void) updateHeights:(NSTimer *)timer;
- (void) reloadButtonClicked;
- (void) _customButtonClicked;

@end

#endif//CyteKit_WebViewControllerPrivate_H
