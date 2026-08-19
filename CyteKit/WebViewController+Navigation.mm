/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#include "CyteKit/WebViewControllerPrivate.h"

@implementation CyteWebViewController (Navigation)

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

- (void) pushRequest:(NSURLRequest *)request forAction:(NSDictionary *)action asPop:(bool)pop {
    WebFrame *frame(nil);
    if (NSDictionary *WebActionElement = [action objectForKey:@"WebActionElementKey"])
        frame = [WebActionElement objectForKey:@"WebElementFrame"];
    if (frame == nil)
        frame = [[[[self webView] _documentView] webView] mainFrame];

    WebDataSource *source([frame provisionalDataSource] ?: [frame dataSource]);
    NSString *referrer([request valueForHTTPHeaderField:@"Referer"] ?: [[[source request] URL] absoluteString]);

    NSURL *url([request URL]);

    // XXX: filter to internal usage?
    CyteViewController *page([self.delegate pageForURL:url forExternal:NO withReferrer:referrer]);

    if (page == nil) {
        CyteWebViewController *browser([[class_ alloc] init]);
        [browser setRequest:request];
        page = browser;
    }

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
