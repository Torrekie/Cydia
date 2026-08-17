#include "CyteKit/WebViewControllerPrivate.h"

//#include <QuartzCore/CALayer.h>
// XXX: fix the minimum requirement
extern NSString * const kCAFilterNearest;

#include "CyteKit/WebCore/WebCoreThread.h"

#include <dlfcn.h>
#include <objc/runtime.h>

#include "Substrate.hpp"

JSValueRef (*$JSObjectCallAsFunction)(JSContextRef, JSObjectRef, JSObjectRef, size_t, const JSValueRef[], JSValueRef *);

// XXX: centralize these special class things to some file or mechanism?
static Class $MFMailComposeViewController;

float CYScrollViewDecelerationRateNormal;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation CyteWebViewController

#if ShowInternals
#include "CyteKit/UCInternal.h"
#endif

+ (void) _initialize {
    [WebPreferences _setInitialDefaultTextEncodingToSystemEncoding];
    if ([WebPreferences respondsToSelector:@selector(setWebKitLinkTimeVersion:)])
        [WebPreferences setWebKitLinkTimeVersion:PACKED_VERSION(3453,0,0)];

    void *js(NULL);
    if (js == NULL)
        js = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_GLOBAL | RTLD_LAZY);
    if (js == NULL)
        js = dlopen("/System/Library/PrivateFrameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_GLOBAL | RTLD_LAZY);
    if (js != NULL)
        $JSObjectCallAsFunction = reinterpret_cast<JSValueRef (*)(JSContextRef, JSObjectRef, JSObjectRef, size_t, const JSValueRef[], JSValueRef *)>(dlsym(js, "JSObjectCallAsFunction"));

    dlopen("/System/Library/Frameworks/MessageUI.framework/MessageUI", RTLD_GLOBAL | RTLD_LAZY);
    $MFMailComposeViewController = objc_getClass("MFMailComposeViewController");

    if (CGFloat *_UIScrollViewDecelerationRateNormal = reinterpret_cast<CGFloat *>(dlsym(RTLD_DEFAULT, "UIScrollViewDecelerationRateNormal")))
        CYScrollViewDecelerationRateNormal = *_UIScrollViewDecelerationRateNormal;
    else // XXX: this actually might be fast on some older systems: we should look into this
        CYScrollViewDecelerationRateNormal = 0.998;

    [Diversion initializeStore];
}

- (bool) retainsNetworkActivityIndicator {
    return true;
}

- (void) releaseNetworkActivityIndicator {
    if ([loading_ count] != 0) {
        [loading_ removeAllObjects];

        if ([self retainsNetworkActivityIndicator])
            [self.delegate releaseNetworkActivityIndicator];
    }
}

- (void) dealloc {
#if LogBrowser
    NSLog(@"[CyteWebViewController dealloc]");
#endif

    [self releaseNetworkActivityIndicator];

}

- (NSString *) description {
    return [NSString stringWithFormat:@"<%s: %p, %@>", class_getName([self class]), self, [[request_ URL] absoluteString]];
}

- (CyteWebView *) webView {
    return (CyteWebView *) [self view];
}

- (CyteWebViewController *) indirect {
    return (CyteWebViewController *) (IndirectDelegate *) indirect_;
}

- (void) mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error {
    [self dismissModalViewControllerAnimated:YES];
}

- (void) _setupMail:(MFMailComposeViewController *)controller {
}

- (void) _openMailToURL:(NSURL *)url {
    if ($MFMailComposeViewController != nil && [$MFMailComposeViewController canSendMail]) {
        MFMailComposeViewController *controller([[$MFMailComposeViewController alloc] init]);
        [controller setMailComposeDelegate:self];

        [controller setMailToURL:url];

        [self _setupMail:controller];

        [self presentModalViewController:controller animated:YES];
        return;
    }

    UIApplication *app([UIApplication sharedApplication]);
    if ([app respondsToSelector:@selector(openURL:asPanel:)])
        [app openURL:url asPanel:YES];
    else
        [app openURL:url];
}

- (id) initWithWidth:(float)width ofClass:(Class)_class {
    if ((self = [super init]) != nil) {
        width_ = width;
        class_ = _class;

        [super setPageColor:nil];

        allowsNavigationAction_ = true;

        loading_ = [NSMutableSet setWithCapacity:5];
        registered_ = [NSMutableSet setWithCapacity:5];
        indirect_ = [[IndirectDelegate alloc] initWithDelegate:self];

        reloaditem_ = [[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("RELOAD")
            style:[self rightButtonStyle]
            target:self
            action:@selector(reloadButtonClicked)
        ];

        loadingitem_ = [[UIBarButtonItem alloc]
            initWithTitle:(kCFCoreFoundationVersionNumber >= 800 ? @"       " : @" ")
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(customButtonClicked)
        ];

        UIActivityIndicatorViewStyle style;
        float left;
        if (kCFCoreFoundationVersionNumber >= 800) {
            style = UIActivityIndicatorViewStyleGray;
            left = 7;
        } else {
            style = UIActivityIndicatorViewStyleWhite;
            left = 15;
        }

        indicator_ = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:style];
        [indicator_ setFrame:CGRectMake(left, 5, [indicator_ frame].size.width, [indicator_ frame].size.height)];
        [indicator_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];

        [self applyLeftButton];
        [self applyRightButton];
    } return self;
}

static _H<NSString> UserAgent_;
+ (void) setApplicationNameForUserAgent:(NSString *)userAgent {
    UserAgent_ = userAgent;
}

- (NSString *) applicationNameForUserAgent {
    return UserAgent_;
}

- (void) loadView {
    CGRect bounds([[UIScreen mainScreen] applicationFrame]);

    webview_ = [[CyteWebView alloc] initWithFrame:bounds];
    [webview_ setDelegate:self];
    [self setView:webview_];

    if ([webview_ respondsToSelector:@selector(setDataDetectorTypes:)])
        [webview_ setDataDetectorTypes:UIDataDetectorTypeAutomatic];
    else
        [webview_ setDetectsPhoneNumbers:NO];

    [webview_ setScalesPageToFit:YES];

    UIWebDocumentView *document([webview_ _documentView]);

    // XXX: I think this improves scrolling; the hardcoded-ness sucks
    [document setTileSize:CGSizeMake(320, 500)];

    WebView *webview([document webView]);
    WebPreferences *preferences([webview preferences]);

    // XXX: I have no clue if I actually /want/ this modification
    if ([webview respondsToSelector:@selector(_setLayoutInterval:)])
        [webview _setLayoutInterval:0];
    else if ([preferences respondsToSelector:@selector(_setLayoutInterval:)])
        [preferences _setLayoutInterval:0];

    [preferences setCacheModel:WebCacheModelDocumentBrowser];
    [preferences setJavaScriptCanOpenWindowsAutomatically:NO];

    if ([preferences respondsToSelector:@selector(setOfflineWebApplicationCacheEnabled:)])
        [preferences setOfflineWebApplicationCacheEnabled:YES];

    if (NSString *agent = [self applicationNameForUserAgent])
        [webview setApplicationNameForUserAgent:agent];

    if ([webview respondsToSelector:@selector(setShouldUpdateWhileOffscreen:)])
        [webview setShouldUpdateWhileOffscreen:NO];

#if LogMessages
    if ([document respondsToSelector:@selector(setAllowsMessaging:)])
        [document setAllowsMessaging:YES];
    if ([webview respondsToSelector:@selector(_setAllowsMessaging:)])
        [webview _setAllowsMessaging:YES];
#endif

    if ([webview_ respondsToSelector:@selector(_scrollView)]) {
        scroller_ = [webview_ _scrollView];

        [scroller_ setDirectionalLockEnabled:YES];
        [scroller_ setDecelerationRate:CYScrollViewDecelerationRateNormal];
        [scroller_ setDelaysContentTouches:NO];

        [scroller_ setCanCancelContentTouches:YES];
    } else if ([webview_ respondsToSelector:@selector(_scroller)]) {
        UIScroller *scroller([webview_ _scroller]);
        scroller_ = (UIScrollView *) scroller;

        [scroller setDirectionalScrolling:YES];
        // XXX: we might be better off /not/ setting this on older systems
        [scroller setScrollDecelerationFactor:CYScrollViewDecelerationRateNormal]; /* 0.989324 */
        [scroller setScrollHysteresis:0]; /* 8 */

        [scroller setThumbDetectionEnabled:NO];

        // use NO with UIApplicationUseLegacyEvents(YES)
        [scroller setEventMode:YES];

        // XXX: this is handled by setBounces, right?
        //[scroller setAllowsRubberBanding:YES];
    }

    [webview_ setOpaque:NO];
    [webview_ setBackgroundColor:nil];

    [scroller_ setFixedBackgroundPattern:YES];
    [scroller_ setBackgroundColor:self.pageColor];
    [scroller_ setClipsSubviews:YES];

    [scroller_ setBounces:YES];
    [scroller_ setScrollingEnabled:YES];
    [scroller_ setShowBackgroundShadow:NO];

    [self setViewportWidth:width_];

    if ([[UIColor groupTableViewBackgroundColor] isEqual:[UIColor clearColor]]) {
        UITableView *table([[UITableView alloc] initWithFrame:[webview_ bounds] style:UITableViewStyleGrouped]);
        [table setScrollsToTop:NO];
        [webview_ insertSubview:table atIndex:0];
        [table setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
    }

    [webview_ setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];

    ready_ = false;
}

- (void) releaseSubviews {
    webview_ = nil;
    scroller_ = nil;

    [self releaseNetworkActivityIndicator];

    [super releaseSubviews];
}

- (id) initWithWidth:(float)width {
    return [self initWithWidth:width ofClass:[self class]];
}

- (id) init {
    return [self initWithWidth:0];
}

- (id) initWithURL:(NSURL *)url {
    if ((self = [self init]) != nil) {
        [self setURL:url];
    } return self;
}

- (id) initWithRequest:(NSURLRequest *)request {
    if ((self = [self init]) != nil) {
        [self setRequest:request];
    } return self;
}

+ (void) _lockJavaScript:(WebPreferences *)preferences {
    WebThreadLocked lock;
    [preferences setJavaScriptCanOpenWindowsAutomatically:NO];
}

- (void) callFunction:(WebScriptObject *)function {
    WebThreadLocked lock;

    WebView *webview([[[self webView] _documentView] webView]);
    WebPreferences *preferences([webview preferences]);

    [preferences setJavaScriptCanOpenWindowsAutomatically:YES];
    if ([webview respondsToSelector:@selector(_preferencesChanged:)])
        [webview _preferencesChanged:preferences];
    else
        [webview _preferencesChangedNotification:[NSNotification notificationWithName:@"" object:preferences]];

    WebFrame *frame([webview mainFrame]);
    JSGlobalContextRef context([frame globalContext]);

    JSObjectRef object([function JSObject]);
    if ($JSObjectCallAsFunction != NULL)
        ($JSObjectCallAsFunction)(context, object, NULL, 0, NULL, NULL);

    // XXX: the JavaScript code submits a form, which seems to happen asynchronously
    Class target([CyteWebViewController class]);
    [NSObject cancelPreviousPerformRequestsWithTarget:target selector:@selector(_lockJavaScript:) object:preferences];
    [target performSelector:@selector(_lockJavaScript:) withObject:preferences afterDelay:1];
}

- (void) reloadButtonClicked {
    [self reloadURLWithCache:NO];
}

- (void) _customButtonClicked {
    [self reloadButtonClicked];
}

- (void) customButtonClicked {
#if !AlwaysReload
    if (function_ != nil)
        [self callFunction:function_];
    else
#endif
    [self _customButtonClicked];
}


@end
#pragma clang diagnostic pop
