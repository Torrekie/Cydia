#include "CyteKit/WebViewControllerPrivate.h"
#include "Cydia/UIColor+Cydia.h"

//#include <QuartzCore/CALayer.h>
// XXX: fix the minimum requirement
extern NSString * const kCAFilterNearest;

#include "CyteKit/WebCore/WebCoreThread.h"

#include <dlfcn.h>
#include <cmath>
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

- (bool) usesDocumentAppearanceFallback {
    return false;
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

static NSString *CydiaCSSColor(UIColor *color) {
    CGFloat red(0), green(0), blue(0), alpha(0);
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white(0);
        if (![color getWhite:&white alpha:&alpha])
            return @"rgba(0,0,0,0)";
        red = green = blue = white;
    }

    return [NSString stringWithFormat:@"rgba(%d,%d,%d,%.3f)",
        (int) lround(red * 255),
        (int) lround(green * 255),
        (int) lround(blue * 255),
        alpha];
}

- (void) evaluateAppearanceScriptInAllFrames:(NSString *)script {
    if (webview_ == nil)
        return;

    WebThreadLocked lock;
    WebFrame *mainFrame([[[webview_ _documentView] webView] mainFrame]);
    if (mainFrame == nil)
        return;
    NSMutableArray *frames([NSMutableArray arrayWithObject:mainFrame]);
    while ([frames count] != 0) {
        WebFrame *frame([frames lastObject]);
        [frames removeLastObject];
        [[frame windowObject] evaluateWebScript:script];
        [frames addObjectsFromArray:[frame childFrames]];
    }
}

- (void) applyDocumentAppearanceFallback {
    if (webview_ == nil || ![self usesDocumentAppearanceFallback])
        return;

    UIColor *background([UIColor cydiaColorForRole:CydiaColorRoleBackground
                                    traitCollection:self.traitCollection]);
    UIColor *surface([UIColor cydiaColorForRole:CydiaColorRoleBackground
                                 traitCollection:self.traitCollection]);
    UIColor *label([UIColor cydiaColorForRole:CydiaColorRoleLabel
                              traitCollection:self.traitCollection]);
    UIColor *secondary([UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                traitCollection:self.traitCollection]);
    UIColor *separator([UIColor cydiaColorForRole:CydiaColorRoleSeparator
                                  traitCollection:self.traitCollection]);
    UIColor *accent([UIColor cydiaColorForRole:CydiaColorRoleAccent
                                traitCollection:self.traitCollection]);

    NSString *backgroundCSS(CydiaCSSColor(background));
    NSString *surfaceCSS(CydiaCSSColor(surface));
    NSString *labelCSS(CydiaCSSColor(label));
    NSString *secondaryCSS(CydiaCSSColor(secondary));
    NSString *separatorCSS(CydiaCSSColor(separator));
    NSString *accentCSS(CydiaCSSColor(accent));
    BOOL dark(self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    NSString *darkBackgroundImage(dark ? @"background-image:none !important;" : @"");
    NSString *script([NSString stringWithFormat:
        @"(function(){var root=document.documentElement,body=document.body;"
         "if(!root||!body||root.getAttribute('data-cydia-appearance-managed'))return;"
         "root.style.setProperty('background-color','%@','important');"
         "body.style.setProperty('background-color','%@','important');"
         "body.style.setProperty('color','%@','important');"
         "var style=document.getElementById('cydia-appearance-fallback');"
         "if(!style){style=document.createElement('style');"
         "style.id='cydia-appearance-fallback';"
         "(document.head||root).appendChild(style);}"
         "style.textContent='html,body{background-color:%@ !important;"
         "color:%@ !important;border-color:%@ !important;%@}"
         "body.pinstripe{%@}"
         "panel>fieldset:not(.terminal),panel>block{background-color:%@ !important;"
         "border-color:%@ !important;color:%@ !important;}"
         "panel>fieldset:not(.terminal)>a,panel>fieldset:not(.terminal)>div,"
         "panel>fieldset:not(.terminal)>textarea{border-color:%@ !important;}"
         "panel>fieldset:not(.terminal) label,panel>fieldset:not(.terminal) p,"
         "panel>fieldset:not(.terminal) span{color:%@ !important;}"
         "panel>fieldset:not(.terminal) label+label,panel>footer,"
         "panel>label{color:%@ !important;}"
         "panel>fieldset:not(.terminal) a{color:%@ !important;}"
         "#progress,#button{border-color:%@ !important;color:%@ !important;}"
         "#bar{background-color:%@ !important;}.type-Status{color:%@ !important;}';"
         "})()", backgroundCSS, backgroundCSS, labelCSS, backgroundCSS,
         labelCSS, separatorCSS, darkBackgroundImage, darkBackgroundImage,
         surfaceCSS, separatorCSS, labelCSS, separatorCSS, labelCSS,
         secondaryCSS, accentCSS, separatorCSS, labelCSS, accentCSS,
         labelCSS]);
    [self evaluateAppearanceScriptInAllFrames:script];
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
    [self applyColorAppearance];
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

- (void) applyColorAppearance {
    if ([self pageColorIsDefault] && !pageColorFromDocument_)
        [super setPageColor:nil];

    UIColor *pageColor = [self pageColorIsDefault] ?
        [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground traitCollection:self.traitCollection] :
        self.pageColor;
    [scroller_ setBackgroundColor:pageColor];
    [indicator_ setColor:[UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                    traitCollection:self.traitCollection]];

    if (ready_ && webview_ != nil) {
        NSString *style = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? @"dark" : @"light";
        NSString *script = [NSString stringWithFormat:
            @"document.documentElement.setAttribute('data-cydia-appearance','%@');", style];
        [self evaluateAppearanceScriptInAllFrames:script];
        [self dispatchEvent:@"CydiaAppearanceChanged"];
        [self applyDocumentAppearanceFallback];
        if (pageColorFromDocument_)
            [self refreshDocumentPageColorForFrame:nil];
    }
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection))
        [self applyColorAppearance];
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
