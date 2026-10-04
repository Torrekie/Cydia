/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/HomePlaceholderController.h"
#import "Cydia/UIColor+Cydia.h"
#import "Cydia/NativeAccessibilityTrace.h"
#import "CyteKit/Localize.h"

@interface HomePlaceholderController ()
@property(nonatomic, copy) NSString *pageIdentifier;
@property(nonatomic, strong) UILabel *emptyLabel;
@end

@implementation HomePlaceholderController
- (instancetype)initWithPageIdentifier:(NSString *)identifier {
    NSArray *supported = @[@"featured", @"themes", @"account"];
    if (![supported containsObject:identifier])
        return nil;
    if ((self = [super init])) {
        _pageIdentifier = [identifier copy];
        NSDictionary *titles = @{
            @"featured": UCLocalizeEx(@"HOME_FEATURED", @"Featured"),
            @"themes": UCLocalizeEx(@"HOME_THEMES", @"Themes"),
            @"account": UCLocalizeEx(@"HOME_MANAGE_ACCOUNT", @"Manage Account"),
        };
        self.title = titles[identifier];
    }
    return self;
}

- (NSURL *)navigationURL {
    return [NSURL URLWithString:[@"cydia://home/" stringByAppendingString:_pageIdentifier]];
}

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.accessibilityIdentifier = [@"cydia.home." stringByAppendingString:_pageIdentifier];
    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.text = UCLocalizeEx(@"HOME_EMPTY_DESTINATION", @"No content is available here.");
    _emptyLabel.accessibilityIdentifier = [view.accessibilityIdentifier stringByAppendingString:@".empty"];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.adjustsFontForContentSizeCategory = YES;
    [view addSubview:_emptyLabel];
    self.view = view;
    [self applyAppearance];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _emptyLabel.frame = CGRectInset(self.view.bounds, 24, 24);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyAppearance];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous) ||
        ![self.traitCollection.preferredContentSizeCategory isEqual:previous.preferredContentSizeCategory])
        [self applyAppearance];
}

- (void)applyAppearance {
    UITraitCollection *traits = self.traitCollection;
    self.view.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                           traitCollection:traits];
    _emptyLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
                                       traitCollection:traits];
    _emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
                                  compatibleWithTraitCollection:traits];
    self.navigationController.navigationBar.barStyle =
        traits.userInterfaceStyle == UIUserInterfaceStyleDark ? UIBarStyleBlack : UIBarStyleDefault;
    self.navigationController.navigationBar.tintColor =
        [UIColor cydiaColorForRole:CydiaColorRoleAccent traitCollection:traits];
    self.navigationController.navigationBar.titleTextAttributes = @{
        NSForegroundColorAttributeName:
            [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits],
    };
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    CydiaCaptureNativeAccessibility(self, @"home-placeholder");
}
@end
