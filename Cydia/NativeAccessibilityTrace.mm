/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/NativeAccessibilityTrace.h"
#include "Cydia/NativeAccessibilityJournal.h"
#include "Cydia/NativeAccessibilityColor.h"
#import <QuartzCore/QuartzCore.h>

namespace {
using CydiaAccessibilityColor::RGBA;
const NSUInteger MaximumViews = 512;
const NSUInteger MaximumElements = 256;
const NSUInteger MaximumDepth = 64;
const NSUInteger MaximumTextLength = 1024;

NSString *Text(id value) {
    if (![value isKindOfClass:[NSString class]])
        return @"";
    return [value length] > MaximumTextLength ?
        [value substringToIndex:MaximumTextLength] : value;
}

NSDictionary *FrameRecord(CGRect frame) {
    if (!std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y) ||
        !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height))
        return @{@"invalid": @YES};
    return @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
        @"width": @(frame.size.width), @"height": @(frame.size.height)};
}

NSArray *Components(RGBA color) {
    return @[@(color.red), @(color.green), @(color.blue), @(color.alpha)];
}

BOOL ResolveColor(UIColor *color, UITraitCollection *traits, RGBA *result) {
    if (color == nil)
        return NO;
    if (@available(iOS 13.0, *))
        color = [color resolvedColorWithTraitCollection:traits];
    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a] ||
        !std::isfinite(r) || !std::isfinite(g) || !std::isfinite(b) ||
        !std::isfinite(a) || r < 0 || r > 1 || g < 0 || g > 1 ||
        b < 0 || b > 1 || a < 0 || a > 1)
        return NO;
    *result = {r, g, b, a};
    return YES;
}

NSDictionary *TextColors(UILabel *label) {
    NSMutableDictionary *record([NSMutableDictionary dictionaryWithDictionary:@{
        @"model": @"solid-ancestor-colors-not-pixel-or-WCAG-verification",
        @"pointSize": @(label.font.pointSize),
    }]);
    /* Uniform attributed foregrounds are measurable. Mixed colors and
     * highlighted rendering require a paint-aware, per-span check. */
    __block UIColor *paint(label.textColor);
    __block UIColor *uniform;
    __block BOOL mixed(NO);
    __block NSUInteger runs(0);
    [label.attributedText enumerateAttribute:NSForegroundColorAttributeName
        inRange:NSMakeRange(0, label.attributedText.length) options:0
        usingBlock:^(id value, NSRange range, BOOL *stop) {
            (void)range;
            if (++runs > 16 || (value != nil && ![value isKindOfClass:[UIColor class]])) {
                mixed = YES;
                *stop = YES;
                return;
            }
            UIColor *color(value ?: label.textColor);
            if (runs != 1 && ![uniform isEqual:color]) {
                mixed = YES;
                *stop = YES;
            }
            uniform = color;
            paint = color;
        }];
    if (mixed || label.highlighted) {
        record[@"unresolved"] = @"mixed-attributed-or-highlighted-text";
        return record;
    }
    RGBA foreground;
    if (!ResolveColor(paint, label.traitCollection, &foreground)) {
        record[@"unresolved"] = @"foreground-color";
        return record;
    }
    record[@"foregroundRGBA"] = Components(foreground);
    RGBA background{0, 0, 0, 0};
    UIView *ancestor(label);
    for (NSUInteger depth = 0; ancestor != nil && depth < MaximumDepth;
         ++depth, ancestor = ancestor.superview) {
        if (ancestor.alpha != 1 || [ancestor isKindOfClass:[UIVisualEffectView class]] ||
            [ancestor isKindOfClass:[UIImageView class]] || ancestor.layer.mask != nil) {
            record[@"unresolved"] = @"non-solid-or-translucent-ancestor";
            return record;
        }
        if (background.alpha < 1 && ancestor.backgroundColor != nil) {
            RGBA layer;
            if (!ResolveColor(ancestor.backgroundColor, label.traitCollection, &layer)) {
                record[@"unresolved"] = @"background-color";
                return record;
            }
            background = CydiaAccessibilityColor::Over(background, layer);
        }
    }
    if (ancestor != nil || background.alpha < 1) {
        record[@"unresolved"] = @"no-bounded-opaque-background";
        return record;
    }
    record[@"ancestorBackgroundRGBA"] = Components(background);
    record[@"contrastRatio"] = @(CydiaAccessibilityColor::Contrast(foreground, background));
    record[@"requiresVisualBackgroundValidation"] = @YES;
    return record;
}

UIViewController *FrontController(UIWindow *window) {
    UIViewController *controller(window.rootViewController);
    for (NSUInteger depth = 0; controller != nil && depth < MaximumDepth; ++depth) {
        UIViewController *next(controller.presentedViewController);
        if (next == nil && [controller isKindOfClass:[UINavigationController class]])
            next = [(UINavigationController *)controller visibleViewController];
        if (next == nil && [controller isKindOfClass:[UITabBarController class]])
            next = [(UITabBarController *)controller selectedViewController];
        if (next == nil)
            return controller;
        if (next == controller)
            return nil;
        controller = next;
    }
    return nil;
}

BOOL NativeVisibleView(UIView *view, CGRect *visibleRect) {
    UIWindow *window(view.window);
    if (window == nil)
        return NO;
    CGRect rect([view convertRect:view.bounds toView:window]);
    UIView *ancestor(view);
    for (NSUInteger depth = 0; ancestor != nil && depth < MaximumDepth;
         ++depth, ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01 ||
            [NSStringFromClass([ancestor class]) hasPrefix:@"WK"])
            return NO;
        if (ancestor.clipsToBounds)
            rect = CGRectIntersection(rect, [ancestor convertRect:ancestor.bounds toView:window]);
    }
    rect = CGRectIntersection(rect, window.bounds);
    if (ancestor != nil || CGRectIsNull(rect) || CGRectIsEmpty(rect))
        return NO;
    if (visibleRect != NULL)
        *visibleRect = rect;
    return YES;
}

UIView *ContainingView(id element) {
    for (NSUInteger depth = 0; element != nil && depth < MaximumDepth; ++depth) {
        if ([element isKindOfClass:[UIView class]])
            return element;
        if (![element respondsToSelector:@selector(accessibilityContainer)])
            return nil;
        id next([element accessibilityContainer]);
        if (next == element)
            return nil;
        element = next;
    }
    return nil;
}
} // namespace

@interface CydiaNativeAccessibilityObserver : NSObject
- (instancetype)initWithJournal:(CydiaNativeAccessibilityJournal *)journal;
- (void)captureController:(UIViewController *)controller surface:(NSString *)surface;
@end

@implementation CydiaNativeAccessibilityObserver {
    CydiaNativeAccessibilityJournal *journal_;
    NSMapTable *surfaces_;
    NSMapTable *identities_;
}

- (instancetype)initWithJournal:(CydiaNativeAccessibilityJournal *)journal {
    if ((self = [super init]) == nil)
        return nil;
    journal_ = journal;
    surfaces_ = [NSMapTable weakToStrongObjectsMapTable];
    identities_ = [NSMapTable mapTableWithKeyOptions:
        NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
        valueOptions:NSPointerFunctionsStrongMemory];
    NSNotificationCenter *center([NSNotificationCenter defaultCenter]);
    [center addObserver:self selector:@selector(focusChanged:)
        name:UIAccessibilityElementFocusedNotification object:nil];
    [center addObserver:self selector:@selector(voiceOverChanged:)
        name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)identity:(id)object {
    NSString *token([identities_ objectForKey:object]);
    if (token == nil) {
        token = [[NSUUID UUID] UUIDString];
        [identities_ setObject:token forKey:object];
    }
    return token;
}

- (NSDictionary *)elementRecord:(id)element {
    NSString *label([element accessibilityLabel]);
    NSString *value([element accessibilityValue]);
    NSString *identifier([element respondsToSelector:@selector(accessibilityIdentifier)] ?
        [element accessibilityIdentifier] : nil);
    NSMutableDictionary *record([NSMutableDictionary dictionaryWithDictionary:@{
        @"objectID": [self identity:element],
        @"class": NSStringFromClass([element class]),
        @"identifier": Text(identifier), @"label": Text(label), @"value": Text(value),
        @"textTruncated": @([label length] > MaximumTextLength ||
            [value length] > MaximumTextLength || [identifier length] > MaximumTextLength),
        @"traits": @((unsigned long long)[element accessibilityTraits]),
        @"isAccessibilityElement": @([element isAccessibilityElement]),
        @"accessibilityFrameInScreen": FrameRecord([element accessibilityFrame]),
    }]);
    UIView *view(ContainingView(element));
    if (view != nil) {
        CGRect visible;
        record[@"viewFrameInWindow"] = FrameRecord([view convertRect:view.bounds toView:view.window]);
        record[@"visibleInViewHierarchy"] = @(NativeVisibleView(view, &visible));
        if ([record[@"visibleInViewHierarchy"] boolValue])
            record[@"clippedVisibleFrameInWindow"] = FrameRecord(visible);
    }
    if ([element isKindOfClass:[UILabel class]])
        record[@"textColors"] = TextColors(element);
    return record;
}

- (void)visit:(UIView *)view elements:(NSMutableArray *)elements
       visited:(NSUInteger *)visited depth:(NSUInteger)depth truncated:(BOOL *)truncated {
    if (*visited >= MaximumViews || elements.count >= MaximumElements || depth >= MaximumDepth) {
        *truncated = YES;
        return;
    }
    ++*visited;
    if (!NativeVisibleView(view, NULL))
        return;
    if (view.isAccessibilityElement || view.accessibilityIdentifier.length != 0 ||
        view.accessibilityLabel.length != 0 || view.accessibilityValue.length != 0)
        [elements addObject:[self elementRecord:view]];
    for (UIView *child in view.subviews) {
        [self visit:child elements:elements visited:visited depth:depth + 1 truncated:truncated];
        if (*truncated)
            break;
    }
}

- (UIViewController *)registeredFrontController {
    for (UIViewController *controller in surfaces_.keyEnumerator)
        if (controller.isViewLoaded && controller.view.window != nil &&
            FrontController(controller.view.window) == controller)
            return controller;
    return nil;
}

- (NSDictionary *)context:(UIViewController *)controller {
    return @{@"surface": [surfaces_ objectForKey:controller] ?: @"unknown",
        @"controllerID": [self identity:controller],
        @"contentSizeCategory": controller.traitCollection.preferredContentSizeCategory ?: @"",
        @"userInterfaceStyle": @(controller.traitCollection.userInterfaceStyle),
        @"voiceOverRunning": @(UIAccessibilityIsVoiceOverRunning()),
        @"darkerSystemColors": @(UIAccessibilityDarkerSystemColorsEnabled()),
    };
}

- (void)captureController:(UIViewController *)controller surface:(NSString *)surface {
    if (![journal_ isHealthy])
        return;
    [surfaces_ setObject:surface forKey:controller];
    if (!controller.isViewLoaded || controller.view.window == nil ||
        FrontController(controller.view.window) != controller) {
        [journal_ appendEvent:@"surface_skipped" fields:@{
            @"surface": surface, @"reason": @"not-frontmost"}];
        return;
    }
    NSMutableArray *elements([NSMutableArray array]);
    NSUInteger visited(0);
    BOOL truncated(NO);
    for (UIView *root in @[controller.view,
        controller.navigationController.navigationBar ?: controller.view,
        controller.tabBarController.tabBar ?: controller.view]) {
        /* Avoid duplicate roots without retaining any controller/view globally. */
        if (root == controller.view && visited != 0)
            continue;
        [self visit:root elements:elements visited:&visited depth:0 truncated:&truncated];
    }
    NSMutableDictionary *fields([[self context:controller] mutableCopy]);
    fields[@"elements"] = elements;
    fields[@"viewsVisited"] = @(visited);
    fields[@"truncated"] = @(truncated);
    fields[@"enumeration"] = @"visible-native-subviews-not-effective-AX-order";
    [journal_ appendEvent:@"surface_snapshot" fields:fields];
}

- (void)focusChanged:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self focusChanged:notification]; });
        return;
    }
    if (![journal_ isHealthy])
        return;
    UIViewController *controller([self registeredFrontController]);
    id element(notification.userInfo[UIAccessibilityFocusedElementKey]);
    UIView *view(ContainingView(element));
    if (controller == nil || view == nil || !NativeVisibleView(view, NULL))
        return;
    UINavigationBar *bar(controller.navigationController.navigationBar);
    UITabBar *tabs(controller.tabBarController.tabBar);
    if (![view isDescendantOfView:controller.view] &&
        !(bar != nil && [view isDescendantOfView:bar]) &&
        !(tabs != nil && [view isDescendantOfView:tabs]))
        return;
    NSString *technology(notification.userInfo[UIAccessibilityAssistiveTechnologyKey]);
    NSMutableDictionary *fields([[self context:controller] mutableCopy]);
    fields[@"element"] = [self elementRecord:element];
    fields[@"assistiveTechnology"] = Text(technology);
    fields[@"notification"] = @"UIAccessibilityElementFocusedNotification";
    fields[@"matchesCurrentSystemFocus"] = @(UIAccessibilityFocusedElement(technology) == element);
    [journal_ appendEvent:@"focus_changed" fields:fields];
}

- (void)voiceOverChanged:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self voiceOverChanged:notification]; });
        return;
    }
    UIViewController *controller([self registeredFrontController]);
    if (controller != nil)
        [journal_ appendEvent:@"voiceover_status" fields:[self context:controller]];
}
@end

void CydiaCaptureNativeAccessibility(UIViewController *controller, NSString *surface) {
    if (![NSThread isMainThread] || controller == nil ||
        ![@[@"package", @"confirmation", @"progress", @"upgrading-guide", @"application-extensions", @"more-sources", @"copying-files", @"home-guide"] containsObject:surface])
        return;
    static CydiaNativeAccessibilityObserver *observer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *environment([NSProcessInfo processInfo].environment);
        if (environment[@"CYDIA_NATIVE_AX_TRACE_PATH"] == nil)
            return;
        NSString *version([[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]);
        CydiaNativeAccessibilityJournal *journal([[CydiaNativeAccessibilityJournal alloc]
            initWithEnvironment:environment runtimeVersion:version ?: @"unknown"]);
        if (journal != nil)
            observer = [[CydiaNativeAccessibilityObserver alloc] initWithJournal:journal];
    });
    if (observer == nil)
        return;
    __weak UIViewController *weakController(controller);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *visible(weakController);
        if (visible != nil)
            [observer captureController:visible surface:surface];
    });
}
