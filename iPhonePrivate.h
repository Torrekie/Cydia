#ifndef CYDIA_UIKITPRIVATE_H
#define CYDIA_UIKITPRIVATE_H

// #include <*> {{{
#include <UIKit/UIKit.h>
// }}}
// typedef GS* {{{
typedef struct __GSEvent *GSEventRef;
// }}}

// enum UI* {{{
typedef enum {
    UIGestureAttributeMinDegrees,                 /*float*/
    UIGestureAttributeMaxDegrees,                 /*float*/
    UIGestureAttributeMinScale,                   /*float*/
    UIGestureAttributeMaxScale,                   /*float*/
    UIGestureAttributeIsZoomRubberBandEnabled,    /*BOOL*/
    UIGestureAttributeZoomsFromCurrentToMinOrMax, /*BOOL*/
    UIGestureAttributeVisibleSize,                /*CGSize*/
    UIGestureAttributeUpdatesScroller,            /*BOOL*/
} UIGestureAttribute;

typedef enum {
    UINavigationButtonStyleNormal,
    UINavigationButtonStyleBack,
    UINavigationButtonStyleHighlighted,
    UINavigationButtonStyleDestructive
} UINavigationButtonStyle;

static const UIActivityIndicatorViewStyle UIActivityIndicatorViewStyleWhiteSmall(static_cast<UIActivityIndicatorViewStyle>(3));
static const UIActivityIndicatorViewStyle UIActivityIndicatorViewStyleGraySmall(static_cast<UIActivityIndicatorViewStyle>(4));
static const UIActivityIndicatorViewStyle UIActivityIndicatorViewStyleWhiteTiny(static_cast<UIActivityIndicatorViewStyle>(5));
// }}}
// @interface * : UIView {{{
@interface UIFormAssistant : UIView
+ (UIFormAssistant *) sharedFormAssistant;
- (CGRect) peripheralFrame;
@end

@interface UIKeyboard : UIView
+ (void) initImplementationNow;
@end

@interface UIProgressBar : UIView
+ (CGSize) defaultSize;
- (void) setProgress:(float)progress;
- (void) setStyle:(NSInteger)style;
@end

@interface UIProgressHUD : UIView
- (void) hide;
- (void) setText:(NSString *)text;
- (void) showInView:(UIView *)view;
@end

@interface UITextLabel : UIView
- (void) setCentersHorizontally:(BOOL)centers;
- (void) setColor:(UIColor *)color;
- (void) setFont:(UIFont *)font;
- (void) setText:(NSString *)text;
@end

@interface UITransitionView : UIView
@end

// }}}
// @interface *Button : * {{{
@interface UINavigationButton : UIButton
- (id) initWithTitle:(NSString *)title style:(UINavigationButtonStyle)style;
- (void) setBarStyle:(UIBarStyle)style;
@end

@interface UIPushButton : UIControl
- (id) backgroundForState:(NSUInteger)state;
- (void) setAutosizesToFit:(BOOL)autosizes;
- (void) setBackground:(id)background forState:(NSUInteger)state;
- (void) setDrawsShadow:(BOOL)draws;
- (void) setStretchBackground:(BOOL)stretch;
- (void) setTitle:(NSString *)title;
- (void) setTitleFont:(UIFont *)font;
@end

@interface UIThreePartButton : UIPushButton
@end
// }}}
// @interface NS* (*) {{{
@interface NSMutableURLRequest (Apple)
- (void) setHTTPShouldUsePipelining:(BOOL)pipelining;
@end

@interface NSString (Apple)
- (NSString *) stringByAddingPercentEscapes;
- (NSString *) stringByReplacingCharacter:(UniChar)from withCharacter:(UniChar)to;
@end

@interface NSURL (Apple)
- (BOOL) isGoogleMapsURL;
- (BOOL) isSpringboardHandledURL;
// XXX: make this an enum
- (NSURL *) itmsURL:(NSInteger *)store;
- (NSURL *) mapsURL;
- (NSURL *) phobosURL;
- (NSURL *) youTubeURL;
@end

@interface NSURLRequest (Apple)
+ (BOOL) allowsAnyHTTPSCertificateForHost:(NSString *)host;
+ (void) setAllowsAnyHTTPSCertificate:(BOOL)allow forHost:(NSString *)host;
@end

@interface NSValue (Apple)
+ (NSValue *) valueWithSize:(CGSize)size;
@end
// }}}
// @interface UI* (*) {{{
@interface UIActionSheet (Apple)
- (void) setContext:(NSString *)context;
- (NSString *) context;
@end

@interface UIAlertView (Apple)
- (void) addTextFieldWithValue:(NSString *)value label:(NSString *)label;
- (id) buttons;
- (NSString *) context;
- (void) setContext:(NSString *)context;
- (void) setNumberOfRows:(int)rows;
- (void) setRunsModal:(BOOL)modal;
- (UITextField *) textField;
- (UITextField *) textFieldAtIndex:(NSUInteger)index;
- (void) _updateFrameForDisplay;
@end

@interface UIApplication (Apple)
- (void) suspendReturningToLastApp:(BOOL)returning;
- (void) suspend;
- (void) applicationSuspend;
- (void) applicationSuspend:(GSEventRef)event;
- (void) _animateSuspension:(BOOL)suspend duration:(double)duration startTime:(double)start scale:(float)scale;
- (void) applicationOpenURL:(NSURL *)url;
- (void) applicationWillResignActive:(UIApplication *)application;
- (void) applicationWillSuspend;
- (void) launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (void) openURL:(NSURL *)url asPanel:(BOOL)panel;
- (void) setStatusBarShowsProgress:(BOOL)shows;
- (void) _setSuspended:(BOOL)suspended;
- (void) terminateWithSuccess;
@end

@interface UIBarButtonItem (Apple)
- (UIView *) view;
@end

@interface UIColor (Apple)
+ (UIColor *) pinStripeColor;
@end

@interface UIControl (Apple)
- (void) addTarget:(id)target action:(SEL)action forEvents:(NSInteger)events;
@end

@interface UIDevice (Apple)
- (NSString *) uniqueIdentifier;
@end

@interface UIImage (Apple)
+ (UIImage *) imageAtPath:(NSString *)path;
@end

@interface UILocalizedIndexedCollation (Apple)
- (id) initWithDictionary:(NSDictionary *)dictionary;
- (NSString *) transformedCollationStringForString:(NSString *)string;
@end

@interface UINavigationBar (Apple)
+ (CGSize) defaultSize;
- (UIBarStyle) _barStyle:(BOOL)style;
@end

@interface UIScrollView (Apple)
- (void) setScrollingEnabled:(BOOL)enabled;
- (void) setShowBackgroundShadow:(BOOL)show;
@end

@interface UISearchBar (Apple)
- (UITextField *) searchField;
@end

@interface UITabBarController (Apple)
- (UITransitionView *) _transitionView;
- (void) concealTabBarSelection;
- (void) revealTabBarSelection;
@end

@interface UITabBarItem (Apple)
- (void) setAnimatedBadge:(BOOL)animated;
- (UIView *) view;
@end

@interface UITableViewCell (Apple)
- (float) selectionPercent;
- (void) _updateHighlightColorsForView:(id)view highlighted:(BOOL)highlighted;
@end

@interface UITextField (Apple)
- (NSObject<UITextInputTraits> *) textInputTraits;
@end

@interface UITextView (Apple)
- (UIFont *) font;
- (void) setAllowsRubberBanding:(BOOL)rubberbanding;
- (void) setFont:(UIFont *)font;
- (void) setMarginTop:(int)margin;
- (void) setTextColor:(UIColor *)color;
@end

@interface UIView (Apple)
- (void) setClipsSubviews:(BOOL)clips;
- (void) setEnabledGestures:(NSInteger)gestures;
- (void) setFixedBackgroundPattern:(BOOL)fixed;
- (void) setGestureDelegate:(id)delegate;
- (void) setNeedsDisplayOnBoundsChange:(BOOL)needs;
- (void) setValue:(NSValue *)value forGestureAttribute:(NSInteger)attribute;
- (void) setZoomScale:(float)scale duration:(double)duration;
- (void) _setZoomScale:(float)scale duration:(double)duration;
- (void) setOrigin:(CGPoint)origin;
@end

@interface UIViewController (Apple)
- (void) _updateLayoutForStatusBarAndInterfaceOrientation;
- (void) unloadView;
@end

@interface UIWindow (Apple)
- (UIResponder *) firstResponder;
- (void) makeKey:(UIApplication *)application;
- (void) orderFront:(UIApplication *)application;
@end

// }}}

// #ifndef AVAILABLE_MAC_OS_X_VERSION_10_6_AND_LATER {{{
#ifndef AVAILABLE_MAC_OS_X_VERSION_10_6_AND_LATER
#define AVAILABLE_MAC_OS_X_VERSION_10_6_AND_LATER
// XXX: this is a random jumble of garbage

typedef enum {
    UIModalPresentationFullScreen,
    UIModalPresentationPageSheet,
    UIModalPresentationFormSheet,
    UIModalPresentationCurrentContext,
} UIModalPresentationStyle;

#define kSCNetworkReachabilityFlagsConnectionOnTraffic kSCNetworkReachabilityFlagsConnectionAutomatic

#define UIBarStyleBlack UIBarStyleBlackOpaque

@class NSUndoManager;
@class UIPasteboard;

@interface UIActionSheet (iPad)
- (void) showFromBarButtonItem:(UIBarButtonItem *)item animated:(BOOL)animated;
@end

@interface UIViewController (iPad)
- (void) setModalPresentationStyle:(UIModalPresentationStyle)style;
@end

@interface UIApplication (iOS_3_0)
@property(nonatomic) BOOL applicationSupportsShakeToEdit;
@end

@interface UIScrollView (iOS_3_0)
@property(assign,nonatomic) CGFloat decelerationRate;
@end

extern CGFloat const UIScrollViewDecelerationRateNormal;

#endif//AVAILABLE_MAC_OS_X_VERSION_10_6_AND_LATER
// }}}
// #if __IPHONE_OS_VERSION_MIN_REQUIRED < 30000 {{{
#if __IPHONE_OS_VERSION_MIN_REQUIRED < 30000

#define kSCNetworkReachabilityFlagsConnectionOnDemand (1 << 5)
#define kCFCoreFoundationVersionNumber_iPhoneOS_3_0 478.47

#endif
// }}}

#ifndef kCFCoreFoundationVersionNumber_iPhoneOS_4_0
#define kCFCoreFoundationVersionNumber_iPhoneOS_4_0 550.32
#endif

@interface UITabBarItem (iOS_7_0)
- (id) initWithTitle:(NSString *)title image:(UIImage *)image selectedImage:(UIImage *)selectedImage;
@end

@interface UIScreen (iOS_4_0)
@property(nonatomic,readonly) CGFloat scale;
@end

// extern *; {{{
extern CFStringRef const kGSDisplayIdentifiersCapability;
// }}}
// extern "C" *(); {{{
extern "C" void *reboot2(uint64_t flags);
extern "C" mach_port_t SBSSpringBoardServerPort();
extern "C" int SBBundlePathForDisplayIdentifier(mach_port_t port, const char *identifier, char *path);
extern "C" NSArray *SBSCopyApplicationDisplayIdentifiers(bool active, bool debuggable);
extern "C" NSString *SBSCopyLocalizedApplicationNameForDisplayIdentifier(NSString *);
extern "C" NSString *SBSCopyIconImagePathForDisplayIdentifier(NSString *);
extern "C" UIImage *_UIImageWithName(NSString *name);
extern "C" void UISetColor(CGColorRef color);
// }}}

#endif//CYDIA_UIKITPRIVATE_H
