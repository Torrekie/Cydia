/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#include "CyteKit/WebViewControllerPrivate.h"

@implementation CyteWebViewController (Appearance)

- (void) setButtonImage:(NSString *)button withStyle:(NSString *)style toFunction:(id)function {
    custom_ = button;
    style_ = style;
    function_ = function;

    [self performSelectorOnMainThread:@selector(applyRightButton) withObject:nil waitUntilDone:NO];
}

- (void) setButtonTitle:(NSString *)button withStyle:(NSString *)style toFunction:(id)function {
    custom_ = button;
    style_ = style;
    function_ = function;

    [self performSelectorOnMainThread:@selector(applyRightButton) withObject:nil waitUntilDone:NO];
}

- (void) removeButton {
    custom_ = [NSNull null];
    [self performSelectorOnMainThread:@selector(applyRightButton) withObject:nil waitUntilDone:NO];
}

- (void) scrollToBottomAnimated:(NSNumber *)animated {
    CGSize size([scroller_ contentSize]);
    CGPoint offset([scroller_ contentOffset]);
    CGRect frame([scroller_ frame]);

    if (size.height - offset.y < frame.size.height + 20.f) {
        CGRect rect = {{0, size.height-1}, {size.width, 1}};
        [scroller_ scrollRectToVisible:rect animated:[animated boolValue]];
    }
}

- (void) _setViewportWidth {
    [[[self webView] _documentView] setViewportSize:CGSizeMake(width_, UIWebViewGrowsAndShrinksToFitHeight) forDocumentTypes:0x10];
}

- (void) setViewportWidth:(float)width {
    width_ = width != 0 ? width : [[self class] defaultWidth];
    [self _setViewportWidth];
}

- (void) _setViewportWidthOnMainThread:(NSNumber *)width {
    [self setViewportWidth:[width floatValue]];
}

- (void) setViewportWidthOnMainThread:(float)width {
    [self performSelectorOnMainThread:@selector(_setViewportWidthOnMainThread:) withObject:[NSNumber numberWithFloat:width] waitUntilDone:NO];
}

- (void) webViewUpdateViewSettings:(UIWebView *)view {
    [self _setViewportWidth];
}

- (UIBarButtonItemStyle) rightButtonStyle {
    if (style_ == nil) normal:
        return UIBarButtonItemStylePlain;
    else if ([style_ isEqualToString:@"Normal"])
        return UIBarButtonItemStylePlain;
    else if ([style_ isEqualToString:@"Highlighted"])
        return UIBarButtonItemStyleDone;
    else goto normal;
}

- (UIBarButtonItem *) customButton {
    if (custom_ == nil)
        return [self rightButton];
    else if ((/*clang:*/id) custom_ == [NSNull null])
        return nil;

    return [[UIBarButtonItem alloc]
        initWithTitle:static_cast<NSString *>(custom_.operator NSObject *())
        style:[self rightButtonStyle]
        target:self
        action:@selector(customButtonClicked)
    ];
}

- (UIBarButtonItem *) leftButton {
    UINavigationItem *item([self navigationItem]);
    if ([item backBarButtonItem] != nil && ![item hidesBackButton])
        return nil;

    if (UINavigationController *navigation = [self navigationController])
        if ([[navigation parentOrPresentingViewController] modalViewController] == navigation)
            return [[UIBarButtonItem alloc]
                initWithTitle:UCLocalize("CLOSE")
                style:UIBarButtonItemStylePlain
                target:self
                action:@selector(close)
            ];

    return nil;
}

- (void) applyLeftButton {
    [[self navigationItem] setLeftBarButtonItem:[self leftButton]];
}

- (UIBarButtonItem *) rightButton {
    return reloaditem_;
}

- (void) applyLoadingTitle {
    [[self navigationItem] setTitle:UCLocalize("LOADING")];
}

- (void) layoutRightButton {
    [[loadingitem_ view] addSubview:indicator_];
    [[loadingitem_ view] bringSubviewToFront:indicator_];
}

- (void) applyRightButton {
    if ([self isLoading]) {
        [[self navigationItem] setRightBarButtonItem:loadingitem_ animated:YES];
        [self performSelector:@selector(layoutRightButton) withObject:nil afterDelay:0];

        [indicator_ startAnimating];
        [self applyLoadingTitle];
    } else {
        [indicator_ stopAnimating];
        [[self navigationItem] setRightBarButtonItem:[self customButton] animated:YES];
    }
}

- (void) didStartLoading {
    // Overridden in subclasses.
}

- (void) _didStartLoading {
    [self applyRightButton];

    if ([loading_ count] != 1)
        return;

    if ([self retainsNetworkActivityIndicator])
        [self.delegate retainNetworkActivityIndicator];

    [self didStartLoading];
}

- (void) didFinishLoading {
    // Overridden in subclasses.
}

- (void) _didFinishLoading {
    if ([loading_ count] != 0)
        return;

    [self applyRightButton];
    [[self navigationItem] setTitle:title_];

    if ([self retainsNetworkActivityIndicator])
        [self.delegate releaseNetworkActivityIndicator];

    [self didFinishLoading];
}

- (bool) isLoading {
    return [loading_ count] != 0;
}

+ (float) defaultWidth {
    return 980;
}

- (void) setNavigationBarStyle:(NSString *)name {
    UIBarStyle style;
    if ([name isEqualToString:@"Black"])
        style = UIBarStyleBlack;
    else
        style = UIBarStyleDefault;

    [[[self navigationController] navigationBar] setBarStyle:style];
}

- (void) setNavigationBarTintColor:(UIColor *)color {
    [[[self navigationController] navigationBar] setTintColor:color];
}

- (void) setBadgeValue:(id)value {
    [[[self navigationController] tabBarItem] setBadgeValue:value];
}

- (void) setHidesBackButton:(bool)value {
    [[self navigationItem] setHidesBackButton:value];
    [self applyLeftButton];
}

- (void) setHidesBackButtonByNumber:(NSNumber *)value {
    [self setHidesBackButton:[value boolValue]];
}

- (void) dispatchEvent:(NSString *)event {
    [[self webView] dispatchEvent:event];
}

- (bool) hidesNavigationBar {
    return hidesNavigationBar_;
}

- (void) _setHidesNavigationBar:(bool)value animated:(bool)animated {
    if (visible_)
        [[self navigationController] setNavigationBarHidden:(value && [self hidesNavigationBar]) animated:animated];
}

- (void) setHidesNavigationBar:(bool)value {
    if (hidesNavigationBar_ != value) {
        hidesNavigationBar_ = value;
        [self _setHidesNavigationBar:YES animated:YES];
    }
}

- (void) setHidesNavigationBarByNumber:(NSNumber *)value {
    [self setHidesNavigationBar:[value boolValue]];
}

- (void) setScrollAlwaysBounceVertical:(bool)value {
    if ([webview_ respondsToSelector:@selector(_scrollView)]) {
        UIScrollView *scroller([webview_ _scrollView]);
        [scroller setAlwaysBounceVertical:value];
    } else if ([webview_ respondsToSelector:@selector(_scroller)]) {
        //UIScroller *scroller([webview_ _scroller]);
        // XXX: I am sad here.
    } else return;
}

- (void) setScrollAlwaysBounceVerticalNumber:(NSNumber *)value {
    [self setScrollAlwaysBounceVertical:[value boolValue]];
}

- (void) setScrollIndicatorStyle:(UIScrollViewIndicatorStyle)style {
    if ([webview_ respondsToSelector:@selector(_scrollView)]) {
        UIScrollView *scroller([webview_ _scrollView]);
        [scroller setIndicatorStyle:style];
    } else if ([webview_ respondsToSelector:@selector(_scroller)]) {
        UIScroller *scroller([webview_ _scroller]);
        [scroller setScrollerIndicatorStyle:style];
    } else return;
}

- (void) setScrollIndicatorStyleWithName:(NSString *)style {
    UIScrollViewIndicatorStyle value;

    if (false);
    else if ([style isEqualToString:@"default"])
        value = UIScrollViewIndicatorStyleDefault;
    else if ([style isEqualToString:@"black"])
        value = UIScrollViewIndicatorStyleBlack;
    else if ([style isEqualToString:@"white"])
        value = UIScrollViewIndicatorStyleWhite;
    else return;

    [self setScrollIndicatorStyle:value];
}

- (void) viewWillAppear:(BOOL)animated {
    visible_ = true;

    if ([self hidesNavigationBar])
        [self _setHidesNavigationBar:YES animated:animated];

    // XXX: why isn't this evern called automatically?
    [[self webView] setNeedsLayout];

    [self dispatchEvent:@"CydiaViewWillAppear"];
    [super viewWillAppear:animated];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self dispatchEvent:@"CydiaViewDidAppear"];
}

- (void) viewWillDisappear:(BOOL)animated {
    [self dispatchEvent:@"CydiaViewWillDisappear"];
    [super viewWillDisappear:animated];

    if ([self hidesNavigationBar])
        [self _setHidesNavigationBar:NO animated:animated];

    visible_ = false;
}

- (void) viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self dispatchEvent:@"CydiaViewDidDisappear"];
}

- (void) updateHeights:(NSTimer *)timer {
    for (WebFrame *frame in (id) registered_)
        [frame cydia$updateHeight];
}

- (void) registerFrame:(WebFrame *)frame {
    [registered_ addObject:frame];

    if (timer_ == nil)
        timer_ = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(updateHeights:) userInfo:nil repeats:YES];
}


@end
