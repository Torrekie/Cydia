/* Cydia Refurbished native package-detail simulator probe.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageDetailControllerProbe.h"

#if TARGET_OS_SIMULATOR

#include "Cydia/PackageDetailController.h"
#include "Cydia/PackageControllers.h"
#include "Cydia/PackageDepictionView.h"
#include "Cydia/UIRouteContext.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"

#include <algorithm>
#include <cmath>
#include <unistd.h>

@interface PackageDetailController (CydiaPackageDetailProbe)
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView;
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section;
- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath;
@end

@interface CydiaPackageProbeAddress : NSObject
@property(nonatomic, copy) NSString *nameValue;
@property(nonatomic, copy) NSString *addressValue;
@end

@implementation CydiaPackageProbeAddress
- (NSString *)name { return _nameValue; }
- (NSString *)address { return _addressValue; }
@end


@interface CydiaPackageProbeSource : NSObject
@property(nonatomic, copy) NSString *keyValue;
@property(nonatomic, copy) NSString *nameValue;
@property(nonatomic, copy) NSString *descriptionValue;
@property(nonatomic, copy) NSString *hostValue;
@property(nonatomic, strong) NSURL *iconValue;
@property(nonatomic, copy) NSDictionary *recordValue;
@end

@implementation CydiaPackageProbeSource
- (NSString *)key { return _keyValue; }
- (NSString *)name { return _nameValue; }
- (NSString *)shortDescription { return _descriptionValue; }
- (NSString *)host { return _hostValue; }
- (NSURL *)iconURL { return _iconValue; }
- (NSString *)getField:(NSString *)name { return [_recordValue objectForKey:name]; }
- (NSDictionary *)record { return _recordValue; }
- (NSArray *)sections { return @[]; }
- (BOOL)trusted { return YES; }
- (NSString *)rooturi { return nil; }
- (NSString *)distribution { return nil; }
- (NSString *)type { return nil; }
- (NSString *)baseuri { return nil; }
- (NSString *)iconuri { return nil; }
- (NSString *)label { return nil; }
- (NSString *)origin { return nil; }
- (NSString *)version { return nil; }
@end


@interface CydiaPackageProbePackage : NSObject
@property(nonatomic, copy) NSString *identityValue;
@property(nonatomic, copy) NSString *baseIdentityValue;
@property(nonatomic, copy) NSString *aptIdentityValue;
@property(nonatomic, copy) NSString *dpkgIdentityValue;
@property(nonatomic, copy) NSString *nameValue;
@property(nonatomic, copy) NSString *latestValue;
@property(nonatomic, copy) NSString *installedValue;
@property(nonatomic, copy) NSString *architectureValue;
@property(nonatomic, copy) NSString *multiArchValue;
@property(nonatomic, copy) NSString *rawSectionValue;
@property(nonatomic, copy) NSString *sectionValue;
@property(nonatomic, copy) NSString *simpleSectionValue;
@property(nonatomic, copy) NSString *shortSectionValue;
@property(nonatomic, copy) NSString *shortDescriptionValue;
@property(nonatomic, copy) NSString *longDescriptionValue;
@property(nonatomic) size_t sizeValue;
@property(nonatomic, copy) NSString *modeValue;
@property(nonatomic, copy) NSArray *warningsValue;
@property(nonatomic) BOOL uninstalledValue;
@property(nonatomic) BOOL upgradableValue;
@property(nonatomic) BOOL heldValue;
@property(nonatomic) BOOL essentialValue;
@property(nonatomic) bool commercialValue;
@property(nonatomic) BOOL consoleValue;
@property(nonatomic, strong) CydiaPackageProbeAddress *authorValue;
@property(nonatomic, strong) CydiaPackageProbeAddress *maintainerValue;
@property(nonatomic, copy) NSString *supportValue;
@property(nonatomic, copy) NSString *homepageValue;
@property(nonatomic, copy) NSString *depictionValue;
@property(nonatomic, strong) CydiaPackageProbeSource *sourceValue;
@property(nonatomic, copy) NSArray *applicationsValue;
@property(nonatomic, copy) NSArray *downgradesValue;
@property(nonatomic, strong) UIImage *iconValue;
@property(nonatomic, copy) NSDictionary *fieldsValue;
@property(nonatomic, copy) NSString *recordValue;
@property(nonatomic, copy) NSArray *tagsValue;
@end

@implementation CydiaPackageProbePackage
- (void)parse {}
- (NSString *)id { return _identityValue; }
- (NSString *)baseId { return _baseIdentityValue; }
- (NSString *)aptId { return _aptIdentityValue; }
- (NSString *)dpkgId { return _dpkgIdentityValue; }
- (NSString *)name { return _nameValue; }
- (NSString *)latest { return _latestValue; }
- (NSString *)installed { return _installedValue; }
- (NSString *)architecture { return _architectureValue; }
- (NSString *)multiArch { return _multiArchValue; }
- (NSString *)section { return _rawSectionValue; }
- (NSString *)simpleSection { return _simpleSectionValue; }
- (NSString *)longSection { return _sectionValue; }
- (NSString *)shortSection { return _shortSectionValue; }
- (NSString *)shortDescription { return _shortDescriptionValue; }
- (NSString *)longDescription { return _longDescriptionValue; }
- (size_t)size { return _sizeValue; }
- (NSString *)mode { return _modeValue; }
- (NSArray *)warnings { return _warningsValue; }
- (BOOL)uninstalled { return _uninstalledValue; }
- (BOOL)upgradableAndEssential:(BOOL)essential { (void)essential; return _upgradableValue; }
- (BOOL)ignored { return _heldValue; }
- (BOOL)essential { return _essentialValue; }
- (bool)isCommercial { return _commercialValue; }
- (BOOL)hasTag:(NSString *)tag {
    return _consoleValue && [tag isEqualToString:@"purpose::console"];
}
- (CydiaPackageProbeAddress *)author { return _authorValue; }
- (CydiaPackageProbeAddress *)maintainer { return _maintainerValue; }
- (NSString *)support { return _supportValue; }
- (NSString *)homepage { return _homepageValue; }
- (NSString *)depiction { return _depictionValue; }
- (CydiaPackageProbeSource *)source { return _sourceValue; }
- (NSArray *)applications { return _applicationsValue; }
- (NSArray *)downgrades { return _downgradesValue; }
- (NSString *)getField:(NSString *)name { return [_fieldsValue objectForKey:name]; }
- (NSString *)getRecord { return _recordValue; }
- (NSArray *)tags { return _tagsValue; }
- (UIImage *)icon { return _iconValue; }
@end


@interface CydiaPackageDetailProbeDatabase : NSObject
@property(nonatomic, strong) CydiaPackageProbePackage *package;
@end

@implementation CydiaPackageDetailProbeDatabase
- (Package *)packageWithName:(NSString *)identity {
    return [[_package id] isEqualToString:identity] ? (Package *)_package : nil;
}
@end


@interface CydiaPackageDetailProbeDelegate : NSObject <PackageDetailControllerDelegate>
@property(nonatomic, copy) NSString *lastAction;
@property(nonatomic, copy) NSString *lastIdentity;
@property(nonatomic, copy) NSString *lastURLString;
@property(nonatomic, copy) NSString *lastReferrer;
@property(nonatomic, strong) NSNumber *lastRouteCaller;
@property(nonatomic, strong) NSNumber *lastRouteNavigationKind;
@property(nonatomic, strong) NSNumber *lastRouteMainFrame;
@property(nonatomic, strong) NSNumber *lastRouteUserGesture;
@end

@implementation CydiaPackageDetailProbeDelegate
- (void)packageDetailController:(PackageDetailController *)controller
         didSelectModifyAction:(CydiaPackageDetailModifyAction *)action
                  versionChoice:(CydiaPackageDetailVersionChoice *)versionChoice {
    self.lastAction = [action titleLocalizationKey];
    self.lastIdentity = versionChoice == nil ? [[controller viewModel] identity] :
                                               [versionChoice identity];
}
- (void)packageDetailController:(PackageDetailController *)controller
        didSelectNavigationKind:(CydiaPackageDetailNavigationKind)kind
                      URLString:(NSString *)URLString
                     identifier:(NSString *)identifier {
    (void)controller;
    self.lastAction = [NSString stringWithFormat:@"navigation-%lu", (unsigned long)kind];
    self.lastIdentity = identifier ?: URLString;
    self.lastURLString = URLString;
}
- (void)clearPackage:(Package *)package {
    self.lastAction = @"CLEAR";
    self.lastIdentity = [(id)package id];
}
- (void)installPackage:(Package *)package {
    self.lastAction = @"INSTALL";
    self.lastIdentity = [(id)package id];
}
- (void)removePackage:(Package *)package {
    self.lastAction = @"REMOVE";
    self.lastIdentity = [(id)package id];
}
- (CyteViewController *)pageForURL:(NSURL *)URL
                           context:(NSObject<CyteWebNavigationContext> *)context
                      withReferrer:(NSString *)referrer {
    (void)referrer;
    CydiaUIRouteContext *routeContext([context isKindOfClass:[CydiaUIRouteContext class]] ?
        (CydiaUIRouteContext *)context : nil);
    self.lastAction = [routeContext caller] == CydiaUIRouteCallerRepositoryDepiction ?
        @"navigation-6" : @"navigation-route";
    self.lastIdentity = [routeContext depictionPackageIdentity];
    self.lastURLString = [URL absoluteString];
    self.lastReferrer = referrer;
    self.lastRouteCaller = @([routeContext caller]);
    self.lastRouteNavigationKind = @([routeContext navigationKind]);
    self.lastRouteMainFrame = @([routeContext isMainFrame]);
    self.lastRouteUserGesture = @([routeContext hasUserGesture]);
    return nil;
}
- (void)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended {
    (void)suspended;
    self.lastAction = @"navigation-application";
    self.lastIdentity = identifier;
}
@end


static UIImage *CydiaPackageProbeIcon(void) {
    CGSize size(CGSizeMake(64.0, 64.0));
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    [[UIColor colorWithRed:1.0 green:0.55 blue:0.0 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    NSString *mark(@"<> ");
    NSDictionary *attributes(@{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:25.0],
        NSForegroundColorAttributeName: [UIColor whiteColor],
    });
    CGSize markSize([mark sizeWithAttributes:attributes]);
    [mark drawAtPoint:CGPointMake((size.width - markSize.width) / 2.0,
                                  (size.height - markSize.height) / 2.0)
       withAttributes:attributes];
    UIImage *image(UIGraphicsGetImageFromCurrentImageContext());
    UIGraphicsEndImageContext();
    return image;
}

static NSString *CydiaPackageProbeEnvironment(NSString *key);

static CydiaPackageProbePackage *CydiaPackageProbeFullPackage(NSString *phase) {
    CydiaPackageProbePackage *package([[CydiaPackageProbePackage alloc] init]);
    package.identityValue = @"runtime:iphoneos-arm64";
    package.baseIdentityValue = @"runtime";
    package.aptIdentityValue = @"runtime:iphoneos-arm64";
    package.dpkgIdentityValue = @"runtime:iphoneos-arm64";
    package.nameValue = @"Runtime Native Package";
    package.latestValue = @"2:1.1";
    package.installedValue = @"2:1.0";
    package.architectureValue = @"iphoneos-arm64";
    package.multiArchValue = @"same";
    package.rawSectionValue = @"System";
    package.sectionValue = @"System";
    package.simpleSectionValue = @"System";
    package.shortSectionValue = @"System";
    package.shortDescriptionValue = @"Short fallback description";
    package.longDescriptionValue = @"This native package description remains expanded inside the single package table.\nIt is intentionally long enough to prove wrapping and footer scrolling.";
    package.sizeValue = 8 * 1024 * 1024;
    package.modeValue = @"INSTALL";
    package.warningsValue = @[@"Runtime package warning is explicit without relying on color."];
    package.upgradableValue = YES;
    package.heldValue = YES;
    package.essentialValue = YES;
    package.commercialValue = true;
    package.consoleValue = YES;
    package.fieldsValue = @{
        @"Package": package.identityValue,
        @"Version": package.latestValue,
        @"Description": package.longDescriptionValue,
    };
    package.recordValue = @"Package: runtime:iphoneos-arm64\nVersion: 2:1.1\n";
    package.tagsValue = @[ @"purpose::console", @"role::developer" ];
    CydiaPackageProbeAddress *author([[CydiaPackageProbeAddress alloc] init]);
    author.nameValue = @"Runtime Author";
    author.addressValue = @"runtime@example.test";
    package.authorValue = author;
    package.supportValue = @"https://support.example/runtime";
    package.homepageValue = @"https://example.test/runtime";
    NSString *depictionOrigin(CydiaPackageProbeEnvironment(
        @"CYDIA_PROBE_DEPICTION_ORIGIN"));
    if ([phase hasPrefix:@"depiction-"] && [depictionOrigin length] != 0) {
        NSString *path([phase isEqualToString:@"depiction-long"] ? @"long" :
            [phase isEqualToString:@"depiction-hostile"] ? @"hostile" :
            [phase isEqualToString:@"depiction-failed"] ? @"cross-redirect" : @"short");
        package.depictionValue = [depictionOrigin stringByAppendingFormat:@"/%@", path];
    }
    CydiaPackageProbeSource *source([[CydiaPackageProbeSource alloc] init]);
    source.keyValue = @"https://repo.example/ ./";
    source.nameValue = @"Runtime Repository";
    source.descriptionValue = @"A deterministic repository description rendered below the source row.";
    source.hostValue = @"repo.example";
    source.iconValue = [NSURL URLWithString:@"https://repo.example/CydiaIcon.png"];
    source.recordValue = @{ @"Origin": @"Runtime Repository" };
    package.sourceValue = source;
    package.applicationsValue = @[@[
        @"com.example.runtime", @"Open Runtime App",
        [NSURL fileURLWithPath:@"/Applications/Runtime.app/icon.png"]]];
    CydiaPackageProbePackage *downgrade([[CydiaPackageProbePackage alloc] init]);
    downgrade.identityValue = @"runtime:iphoneos-arm64";
    downgrade.latestValue = @"2:0.9";
    package.downgradesValue = @[downgrade];
    package.iconValue = CydiaPackageProbeIcon();
    return package;
}

static CydiaPackageProbePackage *CydiaPackageProbeSparsePackage(void) {
    CydiaPackageProbePackage *package([[CydiaPackageProbePackage alloc] init]);
    package.identityValue = @"tool:iphoneos-arm";
    package.baseIdentityValue = @"tool";
    package.aptIdentityValue = @"tool:iphoneos-arm";
    package.dpkgIdentityValue = @"tool:iphoneos-arm";
    package.nameValue = @"Foreign Tool";
    package.architectureValue = @"iphoneos-arm";
    package.multiArchValue = @"foreign";
    package.uninstalledValue = YES;
    package.warningsValue = @[];
    package.applicationsValue = @[];
    package.downgradesValue = @[];
    CydiaPackageProbeAddress *maintainer([[CydiaPackageProbeAddress alloc] init]);
    maintainer.nameValue = @"Runtime Maintainer";
    maintainer.addressValue = @"maintainer@example.test";
    package.maintainerValue = maintainer;
    package.iconValue = CydiaPackageProbeIcon();
    return package;
}

static NSInteger CydiaPackageProbeLuminance(UIColor *color) {
    CGFloat red(0), green(0), blue(0), alpha(0), white(0);
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha] &&
        [color getWhite:&white alpha:&alpha])
        red = green = blue = white;
    return (NSInteger)lround(((red + green + blue) / 3.0) * 1000.0);
}

static NSUInteger CydiaPackageProbeScrollViewCount(UIView *root) {
    NSUInteger count([root isKindOfClass:[UIScrollView class]] ? 1 : 0);
    for (UIView *child in root.subviews)
        count += CydiaPackageProbeScrollViewCount(child);
    return count;
}

static NSUInteger CydiaPackageProbeScrollOwnerCount(UIView *root) {
    NSUInteger count([root isKindOfClass:[UIScrollView class]] &&
        [(UIScrollView *)root isScrollEnabled] ? 1 : 0);
    for (UIView *child in root.subviews)
        count += CydiaPackageProbeScrollOwnerCount(child);
    return count;
}

static NSUInteger CydiaPackageProbeBrowserCount(UIView *root) {
    NSUInteger count(0);
    NSString *token([@"Web" stringByAppendingString:@"View"]);
    if ([NSStringFromClass([root class]) rangeOfString:token].location != NSNotFound)
        ++count;
    for (UIView *child in root.subviews)
        count += CydiaPackageProbeBrowserCount(child);
    return count;
}

static UIView *CydiaPackageProbeView(UIView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqualToString:identifier])
        return root;
    for (UIView *child in root.subviews) {
        UIView *match(CydiaPackageProbeView(child, identifier));
        if (match != nil)
            return match;
    }
    return nil;
}

static NSString *CydiaPackageProbeEnvironment(NSString *key) {
    NSString *value([[[NSProcessInfo processInfo] environment] objectForKey:key]);
    return value ?: @"";
}

static NSString *CydiaPackageProbeDepictionState(CydiaPackageDepictionViewState state) {
    switch (state) {
        case CydiaPackageDepictionViewStateIdle: return @"idle";
        case CydiaPackageDepictionViewStateLoading: return @"loading";
        case CydiaPackageDepictionViewStateLoaded: return @"loaded";
        case CydiaPackageDepictionViewStateFailed: return @"failed";
        case CydiaPackageDepictionViewStatePathologicalContent: return @"pathological";
    }
}

static NSDictionary *CydiaPackageProbeAccessibilityElement(
    NSString *identifier, NSString *label, NSString *value, UIAccessibilityTraits traits) {
    return @{
        @"identifier": identifier ?: @"",
        @"label": label ?: @"",
        @"value": value ?: @"",
        @"traits": [NSString stringWithFormat:@"%llu", (unsigned long long)traits],
    };
}


@interface CydiaPackageDetailProbeHostController : UIViewController
@end

@implementation CydiaPackageDetailProbeHostController {
    CydiaPackageDetailViewModel *viewModel_;
    PackageDetailController *controller_;
    UINavigationController *navigation_;
    CydiaPackageDetailProbeDelegate *delegate_;
    CydiaPackageDetailProbeDatabase *database_;
    NSString *phase_;
    NSString *controllerToken_;
    NSString *modelToken_;
    BOOL dark_;
    BOOL accessibilityLarge_;
    NSUInteger settleTicks_;
    BOOL depictionResourceProbeStarted_;
    BOOL depictionResourceProbeComplete_;
    NSUInteger depictionResourceProbeAttempts_;
    BOOL depictionResourcePositiveComplete_;
    NSInteger depictionResourcePositiveWidth_;
    NSInteger depictionResourcePositiveHeight_;
    BOOL depictionResourceRejectedComplete_;
    NSInteger depictionResourceRejectedWidth_;
    NSString *depictionResourcePositiveSource_;
    NSString *depictionResourceRejectedSource_;
    NSString *depictionResourceProbeError_;
    NSString *depictionFacadeText_;
}

- (UIStatusBarStyle) preferredStatusBarStyle {
    return dark_ ? UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}

- (NSString *)markerPath:(NSString *)name {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

- (BOOL)consumeMarker:(NSString *)name {
    NSString *path([self markerPath:name]);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return NO;
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return YES;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    dark_ = NO;
    accessibilityLarge_ = NO;
    [self installPhase:@"full"];
    [self performSelector:@selector(probeTick) withObject:nil afterDelay:0.2];
}

- (void)installPhase:(NSString *)phase {
    phase_ = [phase copy];
    depictionResourceProbeStarted_ = NO;
    depictionResourceProbeComplete_ = NO;
    depictionResourceProbeAttempts_ = 0;
    depictionResourcePositiveComplete_ = NO;
    depictionResourcePositiveWidth_ = 0;
    depictionResourcePositiveHeight_ = 0;
    depictionResourceRejectedComplete_ = NO;
    depictionResourceRejectedWidth_ = 0;
    depictionResourcePositiveSource_ = @"";
    depictionResourceRejectedSource_ = @"";
    depictionResourceProbeError_ = @"";
    depictionFacadeText_ = @"";
    id package([phase isEqualToString:@"sparse"] ?
        CydiaPackageProbeSparsePackage() : CydiaPackageProbeFullPackage(phase));
    delegate_ = [[CydiaPackageDetailProbeDelegate alloc] init];
    database_ = [[CydiaPackageDetailProbeDatabase alloc] init];
    database_.package = package;
    controller_ = [[CYPackageController alloc]
        initWithDatabase:(Database *)database_
        forPackage:[package id]
        withReferrer:@"cydia://package/probe-origin"];
    [controller_ setDelegate:delegate_];
    viewModel_ = [controller_ viewModel];
    controllerToken_ = [[NSUUID UUID] UUIDString];
    modelToken_ = [[NSUUID UUID] UUIDString];
    if (navigation_ == nil) {
        navigation_ = [[UINavigationController alloc] initWithRootViewController:controller_];
        [self addChildViewController:navigation_];
        navigation_.view.frame = self.view.bounds;
        navigation_.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                             UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:navigation_.view];
        [navigation_ didMoveToParentViewController:self];
    } else {
        [navigation_ setViewControllers:@[controller_] animated:NO];
    }
    [self applyTraits];
    settleTicks_ = 6;
}

- (void)probeDepictionResourcesIfReady {
    if (depictionResourceProbeStarted_ ||
        ![phase_ isEqualToString:@"depiction-short"])
        return;

    PackageDepictionView *depiction([controller_ valueForKey:@"depictionView"]);
    if (depiction == nil ||
        [depiction state] != CydiaPackageDepictionViewStateLoaded)
        return;

    depictionResourceProbeStarted_ = YES;
    ++depictionResourceProbeAttempts_;
    __weak CydiaPackageDetailProbeHostController *weakSelf(self);
    NSString *expectedPhase([phase_ copy]);
    NSString *expectedController([controllerToken_ copy]);
    [depiction cydiaProbeResourceImageStateWithCompletion:
        ^(id result, NSError *error) {
        CydiaPackageDetailProbeHostController *strongSelf(weakSelf);
        if (strongSelf == nil ||
            ![strongSelf->phase_ isEqualToString:expectedPhase] ||
            ![strongSelf->controllerToken_ isEqualToString:expectedController])
            return;
        if (error != nil || ![result isKindOfClass:[NSString class]]) {
            strongSelf->depictionResourceProbeComplete_ = YES;
            strongSelf->depictionResourceProbeError_ =
                [error localizedDescription] ?: @"invalid JavaScript result";
            return;
        }

        NSData *data([(NSString *)result dataUsingEncoding:NSUTF8StringEncoding]);
        NSError *parseError(nil);
        NSDictionary *values(data == nil ? nil : [NSJSONSerialization
            JSONObjectWithData:data options:0 error:&parseError]);
        if (![values isKindOfClass:[NSDictionary class]] || parseError != nil) {
            strongSelf->depictionResourceProbeComplete_ = YES;
            strongSelf->depictionResourceProbeError_ =
                [parseError localizedDescription] ?: @"invalid resource result";
            return;
        }
        strongSelf->depictionResourcePositiveSource_ =
            [values[@"goodSource"] isKindOfClass:[NSString class]] ?
                values[@"goodSource"] : @"";
        strongSelf->depictionResourcePositiveComplete_ =
            [values[@"goodComplete"] boolValue];
        strongSelf->depictionResourcePositiveWidth_ =
            [values[@"goodWidth"] integerValue];
        strongSelf->depictionResourcePositiveHeight_ =
            [values[@"goodHeight"] integerValue];
        strongSelf->depictionResourceRejectedSource_ =
            [values[@"badSource"] isKindOfClass:[NSString class]] ?
                values[@"badSource"] : @"";
        strongSelf->depictionResourceRejectedComplete_ =
            [values[@"badComplete"] boolValue];
        strongSelf->depictionResourceRejectedWidth_ =
            [values[@"badWidth"] integerValue];
        strongSelf->depictionFacadeText_ =
            [values[@"facadeText"] isKindOfClass:[NSString class]] ?
                values[@"facadeText"] : @"";
        if ((!strongSelf->depictionResourcePositiveComplete_ ||
             !strongSelf->depictionResourceRejectedComplete_) &&
            strongSelf->depictionResourceProbeAttempts_ < 20) {
            strongSelf->depictionResourceProbeStarted_ = NO;
            return;
        }
        strongSelf->depictionResourceProbeComplete_ = YES;
        if (!strongSelf->depictionResourcePositiveComplete_ ||
            !strongSelf->depictionResourceRejectedComplete_)
            strongSelf->depictionResourceProbeError_ =
                @"resource images did not settle";
    }];
}

- (void)applyTraits {
    UITraitCollection *style([UITraitCollection traitCollectionWithUserInterfaceStyle:
        dark_ ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight]);
    UITraitCollection *size([UITraitCollection
        traitCollectionWithPreferredContentSizeCategory:accessibilityLarge_ ?
            UIContentSizeCategoryAccessibilityLarge : UIContentSizeCategoryLarge]);
    [self setOverrideTraitCollection:[UITraitCollection
        traitCollectionWithTraitsFromCollections:@[style, size]]
        forChildViewController:navigation_];
    [navigation_.view setNeedsLayout];
    [navigation_.view layoutIfNeeded];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)probeTick {
    if ([self consumeMarker:@"cydia-package-detail-probe-top"]) {
        UITableView *table([controller_ valueForKey:@"tableView"]);
        [table setContentOffset:CGPointMake(0.0, -table.adjustedContentInset.top)
                      animated:NO];
        settleTicks_ = 3;
    }
    if ([self consumeMarker:@"cydia-package-detail-probe-depiction-top"]) {
        UITableView *table([controller_ valueForKey:@"tableView"]);
        UITableViewCell *cell([controller_ valueForKey:@"depictionCell"]);
        if (table != nil && cell != nil) {
            CGRect frame([cell convertRect:cell.bounds toView:table]);
            CGFloat maximum(std::max<CGFloat>(-table.adjustedContentInset.top,
                table.contentSize.height - CGRectGetHeight(table.bounds) +
                table.adjustedContentInset.bottom));
            CGFloat target(std::min(maximum, std::max<CGFloat>(
                -table.adjustedContentInset.top, CGRectGetMinY(frame))));
            [table setContentOffset:CGPointMake(0.0, target) animated:NO];
            settleTicks_ = 3;
        }
    }
    if ([self consumeMarker:@"cydia-package-detail-probe-dismiss"]) {
        [controller_ dismissViewControllerAnimated:NO completion:nil];
        settleTicks_ = 3;
    }
    if ([self consumeMarker:@"cydia-package-detail-probe-dark"]) {
        dark_ = YES;
        accessibilityLarge_ = NO;
        [self applyTraits];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-package-detail-probe-accessibility"]) {
        dark_ = YES;
        accessibilityLarge_ = YES;
        [self applyTraits];
        settleTicks_ = 5;
    }
    if ([self consumeMarker:@"cydia-package-detail-probe-sparse"]) {
        dark_ = NO;
        accessibilityLarge_ = NO;
        [self installPhase:@"sparse"];
    }
    if ([self consumeMarker:@"cydia-package-detail-probe-depiction-short"]) {
        dark_ = NO;
        accessibilityLarge_ = NO;
        [self installPhase:@"depiction-short"];
    }
    if ([self consumeMarker:@"cydia-package-detail-probe-depiction-long"]) {
        dark_ = NO;
        accessibilityLarge_ = NO;
        [self installPhase:@"depiction-long"];
    }
    if ([self consumeMarker:@"cydia-package-detail-probe-depiction-hostile"]) {
        dark_ = NO;
        accessibilityLarge_ = NO;
        [self installPhase:@"depiction-hostile"];
    }
    if ([self consumeMarker:@"cydia-package-detail-probe-depiction-failed"]) {
        dark_ = NO;
        accessibilityLarge_ = NO;
        [self installPhase:@"depiction-failed"];
    }
    [navigation_.view layoutIfNeeded];
    [self probeDepictionResourcesIfReady];
    if (settleTicks_ != 0)
        --settleTicks_;
    [self writeState];
    [self performSelector:@selector(probeTick) withObject:nil afterDelay:0.2];
}

- (void)writeState {
    UITableView *table([controller_ valueForKey:@"tableView"]);
    if (table == nil)
        return;
    [table layoutIfNeeded];
    PackageDepictionView *depiction([controller_ valueForKey:@"depictionView"]);
    CydiaPackageDepictionViewState depictionState(depiction == nil ?
        CydiaPackageDepictionViewStateIdle : [depiction state]);
    NSMutableArray<NSString *> *rows([NSMutableArray array]);
    NSMutableArray<NSString *> *sectionStarts([NSMutableArray array]);
    NSMutableArray<NSNumber *> *rowHeights([NSMutableArray array]);
    NSMutableArray<NSDictionary *> *legacyRowIcons([NSMutableArray array]);
    UILabel *headerName([controller_ valueForKeyPath:@"packageHeaderView.nameLabel"]);
    UILabel *headerVersion([controller_ valueForKeyPath:@"packageHeaderView.versionLabel"]);
    UILabel *headerSize([controller_ valueForKeyPath:@"packageHeaderView.sizeLabel"]);
    NSMutableArray<NSDictionary *> *accessibilityElements([NSMutableArray arrayWithArray:@[
        CydiaPackageProbeAccessibilityElement(@"cydia.package.header.icon",
            [viewModel_ displayName], nil, UIAccessibilityTraitImage),
        CydiaPackageProbeAccessibilityElement(@"cydia.package.header.name",
            headerName.text, nil, UIAccessibilityTraitHeader),
        CydiaPackageProbeAccessibilityElement(@"cydia.package.header.version",
            headerVersion.text, nil, UIAccessibilityTraitStaticText),
        CydiaPackageProbeAccessibilityElement(@"cydia.package.header.size",
            headerSize.text, nil, UIAccessibilityTraitStaticText),
    ]]);
    NSMutableArray<NSString *> *accessibilityOrder([NSMutableArray arrayWithArray:@[
        @"cydia.package.header.icon",
        @"cydia.package.header.name",
        @"cydia.package.header.version",
        @"cydia.package.header.size",
    ]]);
    BOOL rowsFit(YES);
    BOOL rowsMeetTouchTarget(YES);
    BOOL rowIconsFit(YES);
    CGFloat minimumRowHeight(CGFLOAT_MAX);
    CGFloat maximumRowHeight(0.0);
    NSInteger sections([controller_ numberOfSectionsInTableView:table]);
    for (NSInteger section(0); section != sections; ++section) {
        NSInteger count([controller_ tableView:table numberOfRowsInSection:section]);
        for (NSInteger row(0); row != count; ++row) {
            NSIndexPath *indexPath([NSIndexPath indexPathForRow:row inSection:section]);
            UITableViewCell *cell([controller_ tableView:table
                cellForRowAtIndexPath:indexPath]);
            NSString *identifier(cell.accessibilityIdentifier ?: @"");
            [rows addObject:identifier];
            NSString *legacyIcon(cell.imageView.accessibilityIdentifier);
            if ([legacyIcon length] != 0)
                [legacyRowIcons addObject:@{ @"row": identifier, @"asset": legacyIcon }];
            if ([identifier isEqualToString:@"cydia.package.depiction.cell"]) {
                NSString *depictionIdentifier(depictionState ==
                    CydiaPackageDepictionViewStateLoaded ?
                    @"cydia.package.depiction.document" :
                    depictionState == CydiaPackageDepictionViewStateFailed ||
                    depictionState == CydiaPackageDepictionViewStatePathologicalContent ?
                    @"cydia.package.depiction.error" : @"cydia.package.depiction.loading");
                [accessibilityOrder addObject:depictionIdentifier];
                [accessibilityElements addObject:CydiaPackageProbeAccessibilityElement(
                    depictionIdentifier,
                    depictionState == CydiaPackageDepictionViewStateLoaded ?
                        @"Repository depiction" :
                        depictionState == CydiaPackageDepictionViewStateFailed ||
                        depictionState == CydiaPackageDepictionViewStatePathologicalContent ?
                        UCLocalize("UNABLE_TO_LOAD") : UCLocalize("LOADING"),
                    [depiction.initialURL absoluteString],
                    depictionState == CydiaPackageDepictionViewStateLoaded ?
                        UIAccessibilityTraitNone : UIAccessibilityTraitStaticText)];
            } else {
                [accessibilityOrder addObject:identifier];
                [accessibilityElements addObject:CydiaPackageProbeAccessibilityElement(
                    identifier, cell.accessibilityLabel, cell.accessibilityValue,
                    cell.accessibilityTraits)];
            }
            if (row == 0)
                [sectionStarts addObject:identifier];
            CGFloat available(std::max<CGFloat>(1.0, CGRectGetWidth(table.bounds) - 40.0));
            if ([cell.textLabel sizeThatFits:CGSizeMake(available, CGFLOAT_MAX)].width >
                available + 0.5)
                rowsFit = NO;
            CGFloat height(CGRectGetHeight([table rectForRowAtIndexPath:indexPath]));
            [rowHeights addObject:@(height)];
            minimumRowHeight = std::min(minimumRowHeight, height);
            maximumRowHeight = std::max(maximumRowHeight, height);
            if (height < 43.5)
                rowsMeetTouchTarget = NO;
            if (cell.imageView.image != nil &&
                (cell.imageView.image.size.width > 29.5 ||
                 cell.imageView.image.size.height > 29.5))
                rowIconsFit = NO;
        }
    }
    if ([rowHeights count] == 0)
        minimumRowHeight = 0.0;
    [accessibilityOrder addObject:@"cydia.package.footer"];
    [accessibilityElements addObject:CydiaPackageProbeAccessibilityElement(
        @"cydia.package.footer", [viewModel_ identity],
        [controller_ valueForKeyPath:@"packageFooterLabel.accessibilityValue"],
        UIAccessibilityTraitStaticText)];

    UIView *header(table.tableHeaderView);
    UIView *footer(table.tableFooterView);
    UITableViewCell *depictionCell([controller_ valueForKey:@"depictionCell"]);
    CGRect depictionFrame(depictionCell == nil ? CGRectZero :
        [depictionCell convertRect:depictionCell.bounds toView:navigation_.view]);
    BOOL depictionVisible(depictionCell != nil && CGRectIntersectsRect(
        navigation_.view.bounds, depictionFrame));
    UIImageView *headerIcon([controller_ valueForKeyPath:@"packageHeaderView.iconView"]);
    BOOL headerLabelsFit(YES);
    for (UILabel *label in @[headerName, headerVersion, headerSize]) {
        CGRect labelFrame([label convertRect:label.bounds toView:header]);
        CGSize required([label sizeThatFits:CGSizeMake(
            std::max<CGFloat>(1.0, CGRectGetWidth(label.bounds)), CGFLOAT_MAX)]);
        if (!CGRectContainsRect(CGRectInset(header.bounds, -0.5, -0.5), labelFrame) ||
            CGRectGetHeight(label.bounds) + 0.5 < required.height)
            headerLabelsFit = NO;
    }
    CGRect footerFrame([footer convertRect:footer.bounds toView:table]);
    BOOL footerVisible(CGRectIntersectsRect(table.bounds, footerFrame));
    UIScreen *screen([UIScreen mainScreen]);
    UIAlertController *modifySheet([controller_.presentedViewController
        isKindOfClass:[UIAlertController class]] ?
        (UIAlertController *)controller_.presentedViewController : nil);
    NSMutableArray<NSString *> *modifyActionTitles([NSMutableArray array]);
    for (UIAlertAction *action in modifySheet.actions)
        [modifyActionTitles addObject:action.title ?: @""];
    NSDictionary *buildEvidence(@{
        @"sourceHEAD": CydiaPackageProbeEnvironment(@"CYDIA_PROBE_SOURCE_HEAD"),
        @"binarySHA256": CydiaPackageProbeEnvironment(@"CYDIA_PROBE_BINARY_SHA256"),
        @"bundleShortVersion": CydiaPackageProbeEnvironment(
            @"CYDIA_PROBE_BUNDLE_SHORT_VERSION"),
        @"bundleVersion": CydiaPackageProbeEnvironment(@"CYDIA_PROBE_BUNDLE_VERSION"),
    });
    NSDictionary *state(@{
        @"schema": @5,
        @"fixtureVersion": @"production-package-shell-and-depiction-v4",
        @"buildEvidence": buildEvidence,
        @"ready": @(settleTicks_ == 0 &&
            (![phase_ hasPrefix:@"depiction-"] ||
             depictionState == CydiaPackageDepictionViewStateLoaded ||
             depictionState == CydiaPackageDepictionViewStateFailed ||
             depictionState == CydiaPackageDepictionViewStatePathologicalContent) &&
            (![phase_ isEqualToString:@"depiction-short"] ||
             depictionState != CydiaPackageDepictionViewStateLoaded ||
             depictionResourceProbeComplete_)),
        @"phase": phase_ ?: @"",
        @"style": dark_ ? @"dark" : @"light",
        @"contentSize": accessibilityLarge_ ? @"accessibility-large" : @"large",
        @"processID": @((int)getpid()),
        @"systemVersion": [[UIDevice currentDevice] systemVersion],
        @"controllerClass": NSStringFromClass([controller_ class]),
        @"controllerToken": controllerToken_ ?: @"",
        @"modelToken": modelToken_ ?: @"",
        @"probeOnly": @NO,
        @"productionRoute": @"CYPackageController",
        @"identity": [viewModel_ identity],
        @"navigationURL": [[controller_ navigationURL] absoluteString] ?: @"",
        @"displayName": [viewModel_ displayName],
        @"architecture": [viewModel_ architecture] ?: @"",
        @"multiArch": [viewModel_ multiArch] ?: @"",
        @"primaryModifyKey": [viewModel_ primaryModifyTitleLocalizationKey] ?: @"",
        @"localizedQueueTitle": UCLocalize("PACKAGE_QUEUE"),
        @"localizedModeTitle": [viewModel_ modeLocalizationKey] == nil ? @"" :
            UCLocalizeEx([viewModel_ modeLocalizationKey]),
        @"localizedAuthorTitle": UCLocalize("AUTHOR"),
        @"localizedWarningTitle": UCLocalize("WARNING"),
        @"sectionCount": @(sections),
        @"sectionStarts": sectionStarts,
        @"rowIdentifiers": rows,
        @"rowHeights": rowHeights,
        @"legacyRowIcons": legacyRowIcons,
        @"minimumRowHeight": @(minimumRowHeight),
        @"maximumRowHeight": @(maximumRowHeight),
        @"rowsMeetTouchTarget": @(rowsMeetTouchTarget),
        @"rowIconsFit": @(rowIconsFit),
        @"nativeRegionOrder": depiction == nil ?
            @[@"topper", @"native-body", @"footer"] :
            @[@"topper", @"native-body", @"depiction", @"native-footer"],
        @"accessibilityOrder": accessibilityOrder,
        @"accessibilityElements": accessibilityElements,
        @"headerPresent": @(header != nil),
        @"headerWidth": @(CGRectGetWidth(header.bounds)),
        @"headerHeight": @(CGRectGetHeight(header.bounds)),
        @"headerIconWidth": @(CGRectGetWidth(headerIcon.bounds)),
        @"headerLabelsFit": @(headerLabelsFit),
        @"footerPresent": @(footer != nil),
        @"footerVisible": @(footerVisible),
        @"footerText": [[controller_ valueForKeyPath:@"packageFooterLabel.text"] copy] ?: @"",
        @"tableWidth": @(CGRectGetWidth(table.bounds)),
        @"tableContentHeight": @(table.contentSize.height),
        @"tableOffset": @(table.contentOffset.y),
        @"tableCentered": @(std::fabs(CGRectGetMidX(table.frame) -
                                      CGRectGetMidX(controller_.view.bounds)) < 0.5),
        @"screenWidth": @(CGRectGetWidth([UIScreen mainScreen].bounds)),
        @"screenHeight": @(CGRectGetHeight([UIScreen mainScreen].bounds)),
        @"uikitNativePixelWidth": @(CGRectGetWidth(screen.nativeBounds)),
        @"uikitNativePixelHeight": @(CGRectGetHeight(screen.nativeBounds)),
        @"screenScale": @(screen.scale),
        @"nativeScale": @(screen.nativeScale),
        @"scrollViewCount": @(CydiaPackageProbeScrollViewCount(controller_.view)),
        @"scrollOwnerCount": @(CydiaPackageProbeScrollOwnerCount(controller_.view)),
        @"embeddedBrowserCount": @(CydiaPackageProbeBrowserCount(controller_.view)),
        @"depictionRegionPresent": @(CydiaPackageProbeView(
            controller_.view, @"cydia.package.depiction") != nil),
        @"depictionState": CydiaPackageProbeDepictionState(depictionState),
        @"depictionContentHeight": @(depiction.contentHeight),
        @"depictionHeightRevisionCount":
            [depiction valueForKey:@"heightRevisionCount"] ?: @0,
        @"depictionInitialURL": [depiction.initialURL absoluteString] ?: @"",
        @"depictionStarted": @(depiction.hasStartedLoading),
        @"depictionLoadError": @(depiction.loadError != nil),
        @"depictionUserTouchSequence": [depiction valueForKey:@"userTouchSequence"] ?: @0,
        @"depictionInvalidatedTouchSequence":
            [depiction valueForKey:@"invalidatedTouchSequence"] ?: @0,
        @"depictionLastNavigationType":
            [depiction valueForKey:@"lastNavigationType"] ?: @0,
        @"depictionLastNavigationUserActivated":
            [depiction valueForKey:@"lastNavigationUserActivated"] ?: @NO,
        @"depictionLastNavigationDisposition":
            [depiction valueForKey:@"lastNavigationDisposition"] ?: @0,
        @"depictionLastNavigationURLString":
            [depiction valueForKey:@"lastNavigationURLString"] ?: @"",
        @"depictionResourceProbeStarted": @(depictionResourceProbeStarted_),
        @"depictionResourceProbeComplete": @(depictionResourceProbeComplete_),
        @"depictionResourceProbeAttempts": @(depictionResourceProbeAttempts_),
        @"depictionResourceProbeError": depictionResourceProbeError_ ?: @"",
        @"depictionResourcePositiveSource":
            depictionResourcePositiveSource_ ?: @"",
        @"depictionResourcePositiveComplete":
            @(depictionResourcePositiveComplete_),
        @"depictionResourcePositiveNaturalWidth":
            @(depictionResourcePositiveWidth_),
        @"depictionResourcePositiveNaturalHeight":
            @(depictionResourcePositiveHeight_),
        @"depictionResourceRejectedSource":
            depictionResourceRejectedSource_ ?: @"",
        @"depictionResourceRejectedComplete":
            @(depictionResourceRejectedComplete_),
        @"depictionResourceRejectedNaturalWidth":
            @(depictionResourceRejectedWidth_),
        @"depictionFacadeText": depictionFacadeText_ ?: @"",
        @"depictionDocumentPresent": @(CydiaPackageProbeView(
            controller_.view, @"cydia.package.depiction.document") != nil),
        @"depictionErrorRegionPresent": @(CydiaPackageProbeView(
            controller_.view, @"cydia.package.depiction.error.container") != nil &&
            !CydiaPackageProbeView(controller_.view,
                @"cydia.package.depiction.error.container").hidden),
        @"depictionFrameX": @(CGRectGetMinX(depictionFrame)),
        @"depictionFrameY": @(CGRectGetMinY(depictionFrame)),
        @"depictionFrameWidth": @(CGRectGetWidth(depictionFrame)),
        @"depictionFrameHeight": @(CGRectGetHeight(depictionFrame)),
        @"depictionVisible": @(depictionVisible),
        @"descriptionRegionPresent": @(CydiaPackageProbeView(
            controller_.view, @"cydia.package.description") != nil),
        @"homepageRegionPresent": @(CydiaPackageProbeView(
            controller_.view, @"cydia.package.action.homepage") != nil),
        @"rowsFit": @(rowsFit),
        @"backgroundLuminance": @(CydiaPackageProbeLuminance(table.backgroundColor)),
        @"nameFontSize": @([[(UILabel *)[controller_ valueForKeyPath:
            @"packageHeaderView.nameLabel"] font] pointSize]),
        @"navigationBarHidden": @(navigation_.navigationBar.hidden),
        @"modifySheetVisible": @(modifySheet != nil),
        @"modifyActionTitles": modifyActionTitles,
        @"lastAction": delegate_.lastAction ?: @"",
        @"lastActionIdentity": delegate_.lastIdentity ?: @"",
        @"lastURLString": delegate_.lastURLString ?: @"",
        @"lastReferrer": delegate_.lastReferrer ?: @"",
        @"lastRouteCaller": delegate_.lastRouteCaller ?: @(-1),
        @"lastRouteNavigationKind": delegate_.lastRouteNavigationKind ?: @(-1),
        @"lastRouteMainFrame": delegate_.lastRouteMainFrame ?: @NO,
        @"lastRouteUserGesture": delegate_.lastRouteUserGesture ?: @NO,
    });
    [state writeToFile:[self markerPath:@"cydia-package-detail-probe.plist"] atomically:YES];
}

@end

UIViewController *CydiaPackageDetailControllerProbeRootController(void) {
    return [[CydiaPackageDetailProbeHostController alloc] init];
}

#endif // TARGET_OS_SIMULATOR
