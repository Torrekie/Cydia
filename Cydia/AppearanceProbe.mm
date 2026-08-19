/* Cydia - iPhone UIKit Front-End for Debian APT */

#include "Cydia/AppearanceProbe.h"

#include "Cydia/Appearance.h"
#include "Cydia/PackageViews.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/extern.h"

#include <UIKit/UIKit.h>
#include <QuartzCore/QuartzCore.h>

#include <cmath>
#include <cstdio>

#if TARGET_OS_SIMULATOR

@interface CydiaAppearanceProbeViewController : UIViewController
@end

@interface PackageCell (CydiaAppearanceProbe)
- (void) configureAppearanceProbe;
@end

@interface CydiaAppearanceProbeApplication : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

static CGFloat ProbeLuminance(UIColor *color) {
    CGFloat red(0), green(0), blue(0), alpha(0);
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white(0);
        if (![color getWhite:&white alpha:&alpha])
            return -1;
        red = green = blue = white;
    }
    return (red + green + blue) / 3.0;
}

static BOOL ProbePaletteAssertions(void) {
    UITraitCollection *light([UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight]);
    UITraitCollection *dark([UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]);

    UIColor *lightBackground([UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:light]);
    UIColor *darkBackground([UIColor cydiaColorForRole:CydiaColorRoleBackground traitCollection:dark]);
    UIColor *lightLabel([UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:light]);
    UIColor *darkLabel([UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:dark]);

    BOOL distinct = fabs(ProbeLuminance(lightBackground) - ProbeLuminance(darkBackground)) > 0.25 &&
                    fabs(ProbeLuminance(lightLabel) - ProbeLuminance(darkLabel)) > 0.25;
    NSLog(@"CydiaAppearanceProbe palette light/dark resolution: %@", distinct ? @"PASS" : @"FAIL");
    return distinct;
}

static BOOL ProbePalettePassed;

static void EnsureProbeMetrics(void) {
    if (ScreenScale_ <= 0)
        ScreenScale_ = [UIScreen mainScreen].scale;
    if (ScreenScale_ <= 0)
        ScreenScale_ = 1;
}

@implementation CydiaAppearanceProbeApplication

- (BOOL) application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void) application;
    (void) options;

    Font12_ = [UIFont systemFontOfSize:12];
    Font12Bold_ = [UIFont boldSystemFontOfSize:12];
    Font14_ = [UIFont systemFontOfSize:14];
    Font18_ = [UIFont systemFontOfSize:18];
    Font18Bold_ = [UIFont boldSystemFontOfSize:18];
    Font22Bold_ = [UIFont boldSystemFontOfSize:22];
    EnsureProbeMetrics();

    ProbePalettePassed = ProbePaletteAssertions();

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[CydiaAppearanceProbeViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

@implementation CydiaAppearanceProbeViewController {
    UIScrollView *scrollView_;
    UILabel *titleLabel_;
    UILabel *styleLabel_;
    UILabel *resultLabel_;
    UILabel *cellsLabel_;
    PackageCell *packageCell_;
    SectionCell *sectionCell_;
    UIView *sourceCell_;
    NSArray<UIView *> *swatches_;
    NSArray<UILabel *> *swatchLabels_;
    NSUInteger appearanceUpdateCount_;
}

- (void) loadView {
    EnsureProbeMetrics();
    UIView *view([[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds]);
    view.backgroundColor = UIColor.cydiaGroupedBackgroundColor;
    self.view = view;

    scrollView_ = [[UIScrollView alloc] initWithFrame:view.bounds];
    scrollView_.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view addSubview:scrollView_];

    titleLabel_ = [[UILabel alloc] init];
    titleLabel_.text = @"Cydia Color Compatibility Test";
    titleLabel_.font = Font22Bold_;
    titleLabel_.textColor = UIColor.cydiaLabelColor;
    [scrollView_ addSubview:titleLabel_];

    styleLabel_ = [[UILabel alloc] init];
    styleLabel_.font = Font14_;
    styleLabel_.textColor = UIColor.cydiaSecondaryLabelColor;
    [scrollView_ addSubview:styleLabel_];

    resultLabel_ = [[UILabel alloc] init];
    resultLabel_.font = Font12_;
    resultLabel_.textColor = UIColor.cydiaSecondaryLabelColor;
    resultLabel_.text = @"Live trait changes redraw custom Cydia cells";
    [scrollView_ addSubview:resultLabel_];

    NSArray *roles = @[
        @(CydiaColorRoleBackground),
        @(CydiaColorRoleGroupedBackground),
        @(CydiaColorRoleInstallingBackground),
        @(CydiaColorRoleRemovingBackground),
    ];
    NSArray *roleNames = @[@"Background", @"Grouped Background", @"Installing Queue", @"Removing Queue"];
    NSMutableArray *swatches([NSMutableArray arrayWithCapacity:[roles count]]);
    NSMutableArray *swatchLabels([NSMutableArray arrayWithCapacity:[roles count]]);
    for (NSUInteger index(0); index != [roles count]; ++index) {
        NSNumber *role([roles objectAtIndex:index]);
        UIView *swatch([[UIView alloc] init]);
        swatch.layer.cornerRadius = 6;
        swatch.layer.borderWidth = 1;
        swatch.layer.borderColor = UIColor.cydiaSeparatorColor.CGColor;
        swatch.backgroundColor = [UIColor cydiaColorForRole:(CydiaColorRole) [role unsignedIntegerValue]];
        UILabel *label([[UILabel alloc] init]);
        label.text = [roleNames objectAtIndex:index];
        label.font = Font12Bold_;
        [swatch addSubview:label];
        [scrollView_ addSubview:swatch];
        [swatches addObject:swatch];
        [swatchLabels addObject:label];
    }
    swatches_ = [swatches copy];
    swatchLabels_ = [swatchLabels copy];

    cellsLabel_ = [[UILabel alloc] init];
    cellsLabel_.text = @"Real custom-drawn Cydia cells";
    cellsLabel_.font = Font14_;
    cellsLabel_.textColor = UIColor.cydiaSecondaryLabelColor;
    [scrollView_ addSubview:cellsLabel_];

    packageCell_ = [[PackageCell alloc] init];
    [packageCell_ configureAppearanceProbe];
    [scrollView_ addSubview:packageCell_];

    sectionCell_ = [[SectionCell alloc] initWithFrame:CGRectZero reuseIdentifier:@"AppearanceProbeSection"];
    [sectionCell_ setSection:nil editing:NO];
    [scrollView_ addSubview:sectionCell_];

    Class sourceClass = NSClassFromString(@"SourceCell");
    if (sourceClass != Nil) {
        sourceCell_ = [[sourceClass alloc] initWithFrame:CGRectMake(0, 0, 320, 58) reuseIdentifier:@"AppearanceProbeSource"];
        if ([sourceCell_ respondsToSelector:@selector(setAllSource)])
            [sourceCell_ performSelector:@selector(setAllSource)];
        [scrollView_ addSubview:sourceCell_];
    }

    [self updateProbeAppearance];
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    EnsureProbeMetrics();

    UIEdgeInsets safe(self.view.safeAreaInsets);
    CGFloat width(self.view.bounds.size.width);
    CGFloat left(safe.left + 18);
    CGFloat contentWidth(width - safe.left - safe.right - 36);
    CGFloat y(safe.top + 12);
    titleLabel_.frame = CGRectMake(left, y, contentWidth, 28);
    y += 34;
    styleLabel_.frame = CGRectMake(left, y, contentWidth, 22);
    y += 24;
    resultLabel_.frame = CGRectMake(left, y, contentWidth, 20);
    y += 28;

    for (NSUInteger index(0); index != [swatches_ count]; ++index) {
        UIView *swatch([swatches_ objectAtIndex:index]);
        swatch.frame = CGRectMake(left, y, contentWidth, 32);
        UILabel *label([swatchLabels_ objectAtIndex:index]);
        label.frame = CGRectInset(swatch.bounds, 10, 0);
        y += 38;
    }

    y += 4;
    cellsLabel_.frame = CGRectMake(left, y, contentWidth, 20);
    y += 26;
    packageCell_.frame = CGRectMake(0, y, width, 74);
    y += 82;
    sectionCell_.frame = CGRectMake(0, y, width, 50);
    y += 58;
    if (sourceCell_ != nil) {
        sourceCell_.frame = CGRectMake(0, y, width, 58);
        y += 66;
    }
    scrollView_.contentSize = CGSizeMake(width, y + 20);
}

- (void) updateProbeAppearance {
    ++appearanceUpdateCount_;
    UIUserInterfaceStyle style(self.traitCollection.userInterfaceStyle);
    styleLabel_.text = style == UIUserInterfaceStyleDark ? @"Trait: dark" : @"Trait: light (iOS 12 fallback when unavailable)";
    styleLabel_.textColor = UIColor.cydiaSecondaryLabelColor;
    resultLabel_.textColor = UIColor.cydiaSecondaryLabelColor;
    cellsLabel_.textColor = UIColor.cydiaSecondaryLabelColor;
    titleLabel_.textColor = UIColor.cydiaLabelColor;
    self.view.backgroundColor = UIColor.cydiaGroupedBackgroundColor;
    for (NSUInteger index(0); index != [swatches_ count]; ++index) {
        UIView *swatch([swatches_ objectAtIndex:index]);
        CydiaColorRole role = index == 0 ? CydiaColorRoleBackground :
            index == 1 ? CydiaColorRoleGroupedBackground :
            index == 2 ? CydiaColorRoleInstallingBackground : CydiaColorRoleRemovingBackground;
        swatch.backgroundColor = [UIColor cydiaColorForRole:role];
        swatch.layer.borderColor = UIColor.cydiaSeparatorColor.CGColor;
        UILabel *label([swatchLabels_ objectAtIndex:index]);
        label.textColor = UIColor.cydiaLabelColor;
    }
    [packageCell_ applyColorAppearance];
    [sectionCell_ applyColorAppearance];
    if ([sourceCell_ respondsToSelector:@selector(applyColorAppearance)])
        [sourceCell_ performSelector:@selector(applyColorAppearance)];
    [packageCell_.content setNeedsDisplay];
    [sectionCell_.content setNeedsDisplay];
    [[(CyteTableViewCell *) sourceCell_ content] setNeedsDisplay];

    NSDictionary *state = @{
        @"style": style == UIUserInterfaceStyleDark ? @"dark" : @"light",
        @"updates": @(appearanceUpdateCount_),
        @"paletteAssertions": @(ProbePalettePassed),
        @"packageBackgroundLuminance": @(ProbeLuminance(packageCell_.content.backgroundColor)),
        @"sectionBackgroundLuminance": @(ProbeLuminance(sectionCell_.content.backgroundColor)),
        @"sourceBackgroundLuminance": @(ProbeLuminance([(CyteTableViewCell *) sourceCell_ content].backgroundColor)),
    };
    [state writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"cydia-appearance-probe.plist"] atomically:YES];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection))
        [self updateProbeAppearance];
}

@end

int CydiaAppearanceProbeMain(int argc, char *argv[]) {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([CydiaAppearanceProbeApplication class]));
}

#endif
