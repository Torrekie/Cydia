/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#include "CyteKit/WebViewControllerPrivate.h"

@implementation CyteWebViewController (WebDelegate)

- (bool) _allowJavaScriptPanel {
    return true;
}

- (bool) allowsNavigationAction {
    return allowsNavigationAction_;
}

- (void) setAllowsNavigationAction:(bool)value {
    allowsNavigationAction_ = value;
}

- (void) setAllowsNavigationActionByNumber:(NSNumber *)value {
    [self setAllowsNavigationAction:[value boolValue]];
}

- (void) popViewControllerWithNumber:(NSNumber *)value {
    UINavigationController *navigation([self navigationController]);
    if ([navigation topViewController] == self)
        [navigation popViewControllerAnimated:[value boolValue]];
}

- (void) _didFailWithError:(NSError *)error forFrame:(WebFrame *)frame {
    NSValue *object([NSValue valueWithNonretainedObject:frame]);
    if (![loading_ containsObject:object])
        return;
    [loading_ removeObject:object];

    [self _didFinishLoading];

    if ([[error domain] isEqualToString:NSURLErrorDomain] && [error code] == NSURLErrorCancelled)
        return;

    if ([[error domain] isEqualToString:WebKitErrorDomain] && [error code] == WebKitErrorFrameLoadInterruptedByPolicyChange) {
        request_ = nil;
        return;
    }

    if ([frame parentFrame] == nil) {
        [self loadURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@?%@",
            [[NSURL fileURLWithPath:[[NSBundle mainBundle] pathForResource:@"error" ofType:@"html"]] absoluteString],
            [[error localizedDescription] stringByAddingPercentEscapes]
        ]]];

        error_ = true;
    }
}

// CyteWebViewDelegate {{{
- (void) webView:(WebView *)view addMessageToConsole:(NSDictionary *)message {
#if LogMessages
    static RegEx irritating("(?"
        ":" "The page at .* displayed insecure content from .*\\."
        "|" "Unsafe JavaScript attempt to access frame with URL .* from frame with URL .*\\. Domains, protocols and ports must match\\."
    ")\\n");

    if (NSString *data = [message objectForKey:@"message"])
        if (irritating(data))
            return;

    NSLog(@"addMessageToConsole:%@", message);
#endif
}

- (void) webView:(WebView *)view decidePolicyForNavigationAction:(NSDictionary *)action request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id<WebPolicyDecisionListener>)listener {
#if LogBrowser
    NSLog(@"decidePolicyForNavigationAction:%@ request:%@ %@ frame:%@", action, request, [request allHTTPHeaderFields], frame);
#endif

    NSURL *url(request == nil ? nil : [request URL]);
    NSString *scheme([[url scheme] lowercaseString]);
    NSString *absolute([[url absoluteString] lowercaseString]);

    if (
        [scheme isEqualToString:@"itms"] ||
        [scheme isEqualToString:@"itmss"] ||
        [scheme isEqualToString:@"itms-apps"] ||
        [scheme isEqualToString:@"itms-appss"] ||
        [absolute hasPrefix:@"http://itunes.apple.com/"] ||
        [absolute hasPrefix:@"https://itunes.apple.com/"] ||
    false) {
        appstore_ = url;

        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:UCLocalize("APP_STORE_REDIRECT")
            message:nil
            delegate:self
            cancelButtonTitle:UCLocalize("CANCEL")
            otherButtonTitles:
                UCLocalize("ALLOW"),
            nil
        ];

        [alert setContext:@"itmsappss"];
        [alert show];

        [listener ignore];
        return;
    }

    if ([frame parentFrame] == nil) {
        if (!error_) {
            if (request_ != nil && ![[request_ URL] isEqual:url] && ![self allowsNavigationAction]) {
                if (url != nil)
                    [self pushRequest:request forAction:action asPop:NO];
                [listener ignore];
            }
        }
    }
}

- (void) webView:(WebView *)view didDecidePolicy:(CYWebPolicyDecision)decision forNavigationAction:(NSDictionary *)action request:(NSURLRequest *)request frame:(WebFrame *)frame {
#if LogBrowser
    NSLog(@"didDecidePolicy:%u forNavigationAction:%@ request:%@ %@ frame:%@", decision, action, request, [request allHTTPHeaderFields], frame);
#endif

    if ([frame parentFrame] == nil) {
        switch (decision) {
            case CYWebPolicyDecisionIgnore:
                if ([[request_ URL] isEqual:[request URL]])
                    request_ = nil;
            break;

            case CYWebPolicyDecisionUse:
                if (!error_)
                    request_ = request;
            break;

            default:
            break;
        }
    }
}

- (void) webView:(WebView *)view decidePolicyForNewWindowAction:(NSDictionary *)action request:(NSURLRequest *)request newFrameName:(NSString *)name decisionListener:(id<WebPolicyDecisionListener>)listener {
#if LogBrowser
    NSLog(@"decidePolicyForNewWindowAction:%@ request:%@ %@ newFrameName:%@", action, request, [request allHTTPHeaderFields], name);
#endif

    NSURL *url([request URL]);
    if (url == nil)
        return;

    if ([name isEqualToString:@"_open"])
        [self.delegate openURL:url];
    else {
        NSString *scheme([[url scheme] lowercaseString]);
        if ([scheme isEqualToString:@"mailto"])
            [self _openMailToURL:url];
        else
            [self pushRequest:request forAction:action asPop:[name isEqualToString:@"_popup"]];
    }

    [listener ignore];
}

- (void) webView:(WebView *)view didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame {
#if LogBrowser
    NSLog(@"didClearWindowObject:%@ forFrame:%@", window, frame);
#endif
}

- (void) webView:(WebView *)view didCommitLoadForFrame:(WebFrame *)frame {
#if LogBrowser
    NSLog(@"didCommitLoadForFrame:%@", frame);
#endif

    if ([frame parentFrame] == nil) {
    }
}

- (void) webView:(WebView *)view didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
#if LogBrowser
    NSLog(@"didFailLoadWithError:%@ forFrame:%@", error, frame);
#endif

    [self _didFailWithError:error forFrame:frame];
}

- (void) webView:(WebView *)view didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
#if LogBrowser
    NSLog(@"didFailProvisionalLoadWithError:%@ forFrame:%@", error, frame);
#endif

    [self _didFailWithError:error forFrame:frame];
}

- (void) webView:(WebView *)view didFinishLoadForFrame:(WebFrame *)frame {
    NSValue *object([NSValue valueWithNonretainedObject:frame]);
    if (![loading_ containsObject:object])
        return;
    [loading_ removeObject:object];

    if ([frame parentFrame] == nil) {
        if (DOMDocument *document = [frame DOMDocument])
            if (DOMNodeList *bodies = [document getElementsByTagName:@"body"])
                for (DOMHTMLBodyElement *body in (id) bodies) {
                    DOMCSSStyleDeclaration *style([document getComputedStyle:body pseudoElement:nil]);

                    UIColor *uic(nil);

                    if (DOMCSSPrimitiveValue *color = static_cast<DOMCSSPrimitiveValue *>([style getPropertyCSSValue:@"background-color"])) {
                        if ([color primitiveType] == DOM_CSS_RGBCOLOR) {
                            DOMRGBColor *rgb([color getRGBColorValue]);

                            float red([[rgb red] getFloatValue:DOM_CSS_NUMBER]);
                            float green([[rgb green] getFloatValue:DOM_CSS_NUMBER]);
                            float blue([[rgb blue] getFloatValue:DOM_CSS_NUMBER]);
                            float alpha([[rgb alpha] getFloatValue:DOM_CSS_NUMBER]);

                            if (alpha == 1)
                                uic = [UIColor
                                    colorWithRed:(red / 255)
                                    green:(green / 255)
                                    blue:(blue / 255)
                                    alpha:alpha
                                ];
                        }
                    }

                    [super setPageColor:uic];
                    [scroller_ setBackgroundColor:self.pageColor];
                    break;
                }
    }

    [self _didFinishLoading];
}

- (void) webView:(WebView *)view didReceiveTitle:(NSString *)title forFrame:(WebFrame *)frame {
    if ([frame parentFrame] != nil)
        return;

    title_ = title;

    [[self navigationItem] setTitle:title_];
}

- (void) webView:(WebView *)view didStartProvisionalLoadForFrame:(WebFrame *)frame {
#if LogBrowser
    NSLog(@"didStartProvisionalLoadForFrame:%@", frame);
#endif

    [loading_ addObject:[NSValue valueWithNonretainedObject:frame]];

    if ([frame parentFrame] == nil) {
        title_ = nil;
        custom_ = nil;
        style_ = nil;
        function_ = nil;

        [registered_ removeAllObjects];
        timer_ = nil;

        allowsNavigationAction_ = true;

        [self setHidesNavigationBar:NO];
        [self setScrollAlwaysBounceVertical:true];
        [self setScrollIndicatorStyle:UIScrollViewIndicatorStyleDefault];

        // XXX: do we still need to do this?
        [[self navigationItem] setTitle:nil];
    }

    [self _didStartLoading];
}

- (void) webView:(WebView *)view resource:(id)identifier didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge fromDataSource:(WebDataSource *)source {
    challenge_ = challenge;

    NSURLProtectionSpace *space([challenge protectionSpace]);
    NSString *realm([space realm]);
    if (realm == nil)
        realm = @"";

    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:realm
        message:nil
        delegate:self
        cancelButtonTitle:UCLocalize("CANCEL")
        otherButtonTitles:UCLocalize("LOGIN"), nil
    ];

    [alert setContext:@"challenge"];
    [alert setNumberOfRows:1];

    [alert addTextFieldWithValue:@"" label:UCLocalize("USERNAME")];
    [alert addTextFieldWithValue:@"" label:UCLocalize("PASSWORD")];

    UITextField *username([alert textFieldAtIndex:0]); {
        NSObject<UITextInputTraits> *traits([username textInputTraits]);
        [traits setAutocapitalizationType:UITextAutocapitalizationTypeNone];
        [traits setAutocorrectionType:UITextAutocorrectionTypeNo];
        [traits setKeyboardType:UIKeyboardTypeASCIICapable];
        [traits setReturnKeyType:UIReturnKeyNext];
    }

    UITextField *password([alert textFieldAtIndex:1]); {
        NSObject<UITextInputTraits> *traits([password textInputTraits]);
        [traits setAutocapitalizationType:UITextAutocapitalizationTypeNone];
        [traits setAutocorrectionType:UITextAutocorrectionTypeNo];
        [traits setKeyboardType:UIKeyboardTypeASCIICapable];
        // XXX: UIReturnKeyDone
        [traits setReturnKeyType:UIReturnKeyNext];
        [traits setSecureTextEntry:YES];
    }

    [alert show];
}

- (NSURLRequest *) webView:(WebView *)view resource:(id)identifier willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response fromDataSource:(WebDataSource *)source {
    if ([request.URL.absoluteString isEqualToString:@"https://cydia.saurik.com/fastclick/lib/fastclick.js"]) {
        ((NSMutableURLRequest*)request).URL = [NSURL URLWithString:@"file:///var/null"];
    }
#if LogBrowser
    NSLog(@"resource:%@ willSendRequest:%@ redirectResponse:%@ fromDataSource:%@", identifier, request, response, source);
#endif

    return request;
}

- (NSURLRequest *) webThreadWebView:(WebView *)view resource:(id)identifier willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response fromDataSource:(WebDataSource *)source {
    if ([request.URL.absoluteString isEqualToString:@"https://cydia.saurik.com/fastclick/lib/fastclick.js"]) {
        ((NSMutableURLRequest*)request).URL = [NSURL URLWithString:@"file:///var/null"];
    }
#if LogBrowser
    NSLog(@"resource:%@ willSendRequest:%@ redirectResponse:%@ fromDataSource:%@", identifier, request, response, source);
#endif

    return request;
}

- (bool) webView:(WebView *)view shouldRunJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame {
    return [self _allowJavaScriptPanel];
}

- (bool) webView:(WebView *)view shouldRunJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WebFrame *)frame {
    return [self _allowJavaScriptPanel];
}

- (bool) webView:(WebView *)view shouldRunJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)text initiatedByFrame:(WebFrame *)frame {
    return [self _allowJavaScriptPanel];
}

- (void) webViewClose:(WebView *)view {
    [self close];
}
// }}}

- (void) close {
    [[[self navigationController] parentOrPresentingViewController] dismissModalViewControllerAnimated:YES];
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"sensitive"]) {
        switch (button) {
            case 1:
                sensitive_ = [NSNumber numberWithBool:YES];
            break;

            case 2:
                sensitive_ = [NSNumber numberWithBool:NO];
            break;
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"challenge"]) {
        id<NSURLAuthenticationChallengeSender> sender([challenge_ sender]);

        if (button == [alert cancelButtonIndex])
            [sender cancelAuthenticationChallenge:challenge_];
        else if (button == [alert firstOtherButtonIndex]) {
            NSString *username([[alert textFieldAtIndex:0] text]);
            NSString *password([[alert textFieldAtIndex:1] text]);

            NSURLCredential *credential([NSURLCredential credentialWithUser:username password:password persistence:NSURLCredentialPersistenceForSession]);

            [sender useCredential:credential forAuthenticationChallenge:challenge_];
        }

        challenge_ = nil;

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"itmsappss"]) {
        if (button == [alert cancelButtonIndex]) {
        } else if (button == [alert firstOtherButtonIndex]) {
            [self.delegate openURL:appstore_];
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"submit"]) {
        if (button == [alert cancelButtonIndex]) {
        } else if (button == [alert firstOtherButtonIndex]) {
            if (request_ != nil) {
                WebThreadLocked lock;
                [[self webView] loadRequest:request_];
            }
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    }
}


@end
