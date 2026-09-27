/* Cydia Refurbished external URL coordinator.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ExternalURLController.h"

#include "Cydia/Appearance.h"
#include "Cydia/ExternalURLPolicy.h"
#include "Cydia/UIColor+Cydia.h"
#include "CyteKit/Localize.h"

#import <SafariServices/SafariServices.h>

@interface ExternalURLController () <SFSafariViewControllerDelegate>
@property(nonatomic, strong) CydiaExternalURLPolicy *policy;
@property(nonatomic, strong) CydiaUIRouteDescriptor *routeDescriptor;
@property(nonatomic, strong) SFSafariViewController *safariController;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic) BOOL attempted;
@property(nonatomic, readwrite) CydiaExternalURLControllerState state;
@end


@implementation ExternalURLController

- (instancetype)initWithRouteDescriptor:(CydiaUIRouteDescriptor *)descriptor {
    if (![descriptor isKindOfClass:[CydiaUIRouteDescriptor class]] ||
        [descriptor kind] != CydiaUIRouteKindExternalOpen ||
        [descriptor originalURL] == nil || [descriptor externalURL] == nil)
        return nil;
    CydiaExternalURLPolicy *policy([[CydiaExternalURLPolicy alloc]
        initWithURL:[descriptor externalURL]]);
    if (policy == nil)
        return nil;

    if ((self = [super init]) != nil) {
        _routeDescriptor = descriptor;
        _policy = policy;
        _state = CydiaExternalURLControllerStateReady;
        self.title = UCLocalize("MORE_INFORMATION");
    }
    return self;
}

- (NSURL *)destinationURL {
    return [_policy destinationURL];
}

- (NSURL *)navigationURL {
    return [_routeDescriptor originalURL];
}

- (void)loadView {
    UIView *root([[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds]);
    root.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleGroupedBackground
                                      traitCollection:root.traitCollection];
    self.view = root;

    UIStackView *stack([[UIStackView alloc] init]);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12.0;
    [root addSubview:stack];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _statusLabel.adjustsFontForContentSizeCategory = YES;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.accessibilityIdentifier = @"external-url.status";
    [stack addArrangedSubview:_statusLabel];

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _detailLabel.adjustsFontForContentSizeCategory = YES;
    _detailLabel.numberOfLines = 0;
    _detailLabel.textAlignment = NSTextAlignmentCenter;
    _detailLabel.text = [_policy displayName];
    _detailLabel.accessibilityIdentifier = @"external-url.destination";
    [stack addArrangedSubview:_detailLabel];

    _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _retryButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _retryButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    [_retryButton setTitle:UCLocalize("RELOAD") forState:UIControlStateNormal];
    [_retryButton addTarget:self action:@selector(retryButtonClicked)
        forControlEvents:UIControlEventTouchUpInside];
    _retryButton.accessibilityIdentifier = @"external-url.retry";
    [stack addArrangedSubview:_retryButton];

    UILayoutGuide *safe(root.safeAreaLayoutGuide);
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24.0],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:414.0],
        [_retryButton.heightAnchor constraintGreaterThanOrEqualToConstant:44.0],
    ]];

    [self applyColorAppearance];
    [self applyState];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_attempted && self.presentedViewController == nil)
        [self beginOpening];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previous))
        [self applyColorAppearance];
}

- (void)applyColorAppearance {
    UITraitCollection *traits(self.traitCollection);
    UIColor *label([UIColor cydiaColorForRole:CydiaColorRoleLabel
                              traitCollection:traits]);
    UIColor *accent([UIColor cydiaColorForRole:CydiaColorRoleAccent
                               traitCollection:traits]);
    self.view.backgroundColor = [UIColor
        cydiaColorForRole:CydiaColorRoleGroupedBackground
        traitCollection:traits];
    _statusLabel.textColor = label;
    _detailLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel
        traitCollection:traits];
    _retryButton.tintColor = accent;
    if (self.navigationController != nil) {
        UINavigationBar *navigationBar(self.navigationController.navigationBar);
        navigationBar.barStyle = traits.userInterfaceStyle == UIUserInterfaceStyleDark ?
            UIBarStyleBlack : UIBarStyleDefault;
        navigationBar.tintColor = accent;
        navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: label};
    }
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)setState:(CydiaExternalURLControllerState)state {
    _state = state;
    if ([self isViewLoaded])
        [self applyState];
}

- (void)applyState {
    switch (_state) {
        case CydiaExternalURLControllerStateReady:
            _statusLabel.text = UCLocalize("LOADING");
            _retryButton.hidden = NO;
            break;
        case CydiaExternalURLControllerStateOpening:
        case CydiaExternalURLControllerStatePresented:
            _statusLabel.text = UCLocalize("LOADING");
            _retryButton.hidden = YES;
            break;
        case CydiaExternalURLControllerStateComplete:
            _statusLabel.text = UCLocalize("COMPLETE");
            _retryButton.hidden = NO;
            break;
        case CydiaExternalURLControllerStateFailed:
            _statusLabel.text = UCLocalize("UNABLE_TO_LOAD");
            _retryButton.hidden = NO;
            break;
    }
    _statusLabel.accessibilityTraits = UIAccessibilityTraitHeader;
}

- (void)retryButtonClicked {
    if (_state == CydiaExternalURLControllerStateOpening ||
        _state == CydiaExternalURLControllerStatePresented)
        return;
    _attempted = NO;
    [self beginOpening];
}

- (BOOL)hasPendingOpenRequest {
    return (_state == CydiaExternalURLControllerStateReady && !_attempted) ||
        _state == CydiaExternalURLControllerStateOpening ||
        _state == CydiaExternalURLControllerStatePresented;
}

- (BOOL)coalescePendingDestinationURL:(NSURL *)URL {
    if (![self hasPendingOpenRequest])
        return NO;
    return [URL isKindOfClass:[NSURL class]] &&
        [[_policy destinationURL] isEqual:URL];
}

- (void)beginOpening {
    if (_attempted)
        return;
    _attempted = YES;
    self.state = CydiaExternalURLControllerStateOpening;

    if ([_policy requiresConfirmation]) {
        __weak ExternalURLController *weakSelf(self);
        UIAlertController *alert([UIAlertController
            alertControllerWithTitle:UCLocalize("MORE_INFORMATION")
            message:[_policy displayName]
            preferredStyle:UIAlertControllerStyleAlert]);
        [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL")
            style:UIAlertActionStyleCancel handler:^(UIAlertAction *) {
                weakSelf.state = CydiaExternalURLControllerStateReady;
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("MORE_INFORMATION")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
                [weakSelf openWithSystemHandler];
            }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    if ([_policy presentationKind] == CydiaExternalURLPresentationKindSafari)
        [self presentSafari];
    else
        [self openWithSystemHandler];
}

- (void)presentSafari {
    SFSafariViewController *controller([[SFSafariViewController alloc]
        initWithURL:[_policy destinationURL] entersReaderIfAvailable:NO]);
    if (controller == nil) {
        self.state = CydiaExternalURLControllerStateFailed;
        return;
    }
    controller.delegate = self;
    if ([controller respondsToSelector:@selector(setPreferredControlTintColor:)])
        controller.preferredControlTintColor = [UIColor
            cydiaColorForRole:CydiaColorRoleAccent traitCollection:self.traitCollection];
    _safariController = controller;
    [self presentViewController:controller animated:YES completion:^{
        self.state = CydiaExternalURLControllerStatePresented;
    }];
}

- (void)openWithSystemHandler {
    UIApplication *application([UIApplication sharedApplication]);
    NSURL *URL([_policy destinationURL]);
    __weak ExternalURLController *weakSelf(self);
    void (^completion)(BOOL) = ^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.state = success ? CydiaExternalURLControllerStateComplete :
                                       CydiaExternalURLControllerStateFailed;
            if (success)
                [weakSelf returnToPreviousController];
        });
    };
    if ([application respondsToSelector:@selector(openURL:options:completionHandler:)])
        [application openURL:URL options:@{} completionHandler:completion];
    else
        completion([application openURL:URL]);
}

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    if (controller != _safariController)
        return;
    _safariController = nil;
    self.state = CydiaExternalURLControllerStateComplete;
    [self dismissViewControllerAnimated:YES completion:^{
        [self returnToPreviousController];
    }];
}

- (void)returnToPreviousController {
    UINavigationController *navigation(self.navigationController);
    if (navigation.topViewController == self && [navigation.viewControllers count] > 1)
        [navigation popViewControllerAnimated:YES];
    else if (navigation.presentingViewController != nil)
        [navigation.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)close {
    UINavigationController *navigation(self.navigationController);
    if (navigation.presentingViewController != nil)
        [navigation.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    else
        [self returnToPreviousController];
}

@end
