/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 * Refurbished compatibility work Copyright (C) 2026 Torrekie
 */

#include "CyteKit/WebViewControllerPrivate.h"

@implementation CyteWebViewController (Navigation)

static BOOL CyteActionHasUserGesture(NSDictionary *action) {
    NSNumber *navigationType([action objectForKey:@"WebActionNavigationTypeKey"]);
    if (navigationType == nil)
        return NO;

    /* Private WebKit reports link clicks, form submissions, and form
     * resubmissions as 0, 1, and 4. This is shadow metadata only; P0.4 must
     * validate it on-device before making user gesture an enforcement input. */
    NSInteger value([navigationType integerValue]);
    return value == 0 || value == 1 || value == 4;
}

+ (void) addDiversion:(Diversion *)diversion {
    [Diversion addDiversion:diversion];
}

- (NSURL *) URLWithURL:(NSURL *)url {
    return [Diversion divertURL:url];
}

- (NSURLRequest *) requestWithURL:(NSURL *)url cachePolicy:(NSURLRequestCachePolicy)policy referrer:(NSString *)referrer {
    NSMutableURLRequest *request([NSMutableURLRequest
        requestWithURL:[self URLWithURL:url]
        cachePolicy:policy
        timeoutInterval:DefaultTimeout_
    ]);

    [request setValue:referrer forHTTPHeaderField:@"Referer"];

    return request;
}

- (void) setRequest:(NSURLRequest *)request {
    _assert(request_ == nil);
    request_ = request;
}

- (NSURLRequest *) request {
    return request_;
}

- (void) setNavigationContext:(NSObject<CyteWebNavigationContext> *)context {
    navigationContext_ = context;
}

- (NSObject<CyteWebNavigationContext> *) navigationContext {
    return navigationContext_;
}

- (void) setURL:(NSURL *)url {
    [self setURL:url withReferrer:nil];
}

- (void) setURL:(NSURL *)url withReferrer:(NSString *)referrer {
    [self setRequest:[self requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy referrer:referrer]];
}

- (void) loadURL:(NSURL *)url cachePolicy:(NSURLRequestCachePolicy)policy {
    [self loadRequest:[self requestWithURL:url cachePolicy:policy referrer:nil]];
}

- (void) loadURL:(NSURL *)url {
    [self loadURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy];
}

- (void) loadRequest:(NSURLRequest *)request {
#if LogBrowser
    NSLog(@"loadRequest:%@", request);
#endif

    error_ = false;
    ready_ = true;

    WebThreadLocked lock;
    [[self webView] loadRequest:request];
}

- (void) reloadURLWithCache:(BOOL)cache {
    if (request_ == nil)
        return;

    NSMutableURLRequest *request([request_ mutableCopy]);
    [request setCachePolicy:(cache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData)];

    request_ = request;

    if (cache || [request_ HTTPBody] == nil && [request_ HTTPBodyStream] == nil)
        [self loadRequest:request_];
    else {
        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:UCLocalize("RESUBMIT_FORM")
            message:nil
            delegate:self
            cancelButtonTitle:UCLocalize("CANCEL")
            otherButtonTitles:
                UCLocalize("SUBMIT"),
            nil
        ];

        [alert setContext:@"submit"];
        [alert show];
    }
}

- (void) reloadData {
    [super reloadData];

    if (ready_)
        [self dispatchEvent:@"CydiaReloadData"];
    else
        [self reloadURLWithCache:YES];
}

- (void) pushRequest:(NSURLRequest *)request forAction:(NSDictionary *)action
               asPop:(bool)pop newWindow:(bool)newWindow {
    WebFrame *frame(nil);
    if (NSDictionary *WebActionElement = [action objectForKey:@"WebActionElementKey"])
        frame = [WebActionElement objectForKey:@"WebElementFrame"];
    if (frame == nil)
        frame = [[[[self webView] _documentView] webView] mainFrame];

    /* Caller authority must come from the committed initiating document. A
     * provisional data source can already describe the destination and must
     * never be preferred when deriving popup provenance. */
    WebDataSource *source([frame dataSource] ?: [frame provisionalDataSource]);
    NSString *referrer([request valueForHTTPHeaderField:@"Referer"] ?: [[[source request] URL] absoluteString]);
    /* Referrer remains a compatibility input for the destination controller,
     * but it is not trusted as caller provenance. Missing frame data therefore
     * produces an explicit untrusted context with an unknown origin. */
    NSURL *origin([[source request] URL]);
    BOOL mainFrame([frame parentFrame] == nil);
    BOOL userGesture(CyteActionHasUserGesture(action));

    NSURL *url([request URL]);

    NSObject<CyteWebNavigationContext> *context(navigationContext_);
    id delegate(self.delegate);
    if (context == nil &&
        [delegate respondsToSelector:@selector(navigationContextForWebOrigin:mainFrame:userGesture:)])
        context = [delegate navigationContextForWebOrigin:origin
                                                 mainFrame:mainFrame
                                               userGesture:userGesture];
    if (context != nil) {
        if (newWindow)
            context = [context contextForPopupWithOrigin:origin
                                               mainFrame:mainFrame
                                             userGesture:userGesture];
        else
            context = [context contextForRedirectWithOrigin:origin
                                                  mainFrame:mainFrame
                                                userGesture:userGesture];
    }

    CyteViewController *page(nil);
    if (context != nil &&
        [delegate respondsToSelector:@selector(pageForURL:context:withReferrer:)])
        page = [delegate pageForURL:url context:context withReferrer:referrer];
    else
        page = [delegate pageForURL:url forExternal:NO withReferrer:referrer];

    if (page == nil) {
        CyteWebViewController *browser([[class_ alloc] init]);
        [browser setRequest:request];
        [browser setNavigationContext:context];
        page = browser;
    }

    if (context != nil && [page respondsToSelector:@selector(setNavigationContext:)])
        [(id) page setNavigationContext:context];

    [page setDelegate:self.delegate];
    [page setPageColor:([self pageColorIsDefault] || pageColorFromDocument_) ? nil : self.pageColor];

    if (!pop) {
        [[self navigationItem] setTitle:title_];

        [[self navigationController] pushViewController:page animated:YES];
    } else {
        UINavigationController *navigation([[UINavigationController alloc] initWithRootViewController:page]);

        [navigation setDelegate:self.delegate];

        [[page navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("CLOSE")
            style:UIBarButtonItemStylePlain
            target:page
            action:@selector(close)
        ]];

        [[self navigationController] presentModalViewController:navigation animated:YES];
    }
}


@end
