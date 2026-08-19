/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "CyteKit/UCPlatform.h"
#include "Cydia/StashController.h"

#include "Cydia/Appearance.h"
#include "CyteKit/Localize.h"
#include "CyteKit/extern.h"
#include "Menes/ObjectHandle.h"
#include "iPhonePrivate.h"

@implementation StashController {
    _H<UIActivityIndicatorView> spinner_;
    _H<UILabel> status_;
    _H<UILabel> caption_;
}

- (void) applyColorAppearance {
    UIView *view = self.view;
    [view setBackgroundColor:[UIColor cydiaColorForRole:CydiaColorRoleBackground
                                        traitCollection:self.traitCollection]];
    [spinner_ setColor:[UIColor cydiaColorForRole:CydiaColorRoleLabel
                                  traitCollection:self.traitCollection]];
    UIColor *labelColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel
                                      traitCollection:self.traitCollection];
    UIColor *shadowColor = [UIColor cydiaColorForRole:CydiaColorRoleBackground
                                       traitCollection:self.traitCollection];
    [caption_ setTextColor:labelColor];
    [caption_ setShadowColor:shadowColor];
    [status_ setTextColor:labelColor];
    [status_ setShadowColor:shadowColor];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection))
        [self applyColorAppearance];
}

- (void) loadView {
    UIView *view([[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]]);
    [view setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
    [self setView:view];

    spinner_ = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    CGRect spinrect = [spinner_ frame];
    spinrect.origin.x = Retina([[self view] frame].size.width / 2 - spinrect.size.width / 2);
    spinrect.origin.y = [[self view] frame].size.height - 80.0f;
    [spinner_ setFrame:spinrect];
    [spinner_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin];
    [view addSubview:spinner_];
    [spinner_ startAnimating];

    CGRect captrect;
    captrect.size.width = [[self view] frame].size.width;
    captrect.size.height = 40.0f;
    captrect.origin.x = 0;
    captrect.origin.y = Retina([[self view] frame].size.height / 2 - captrect.size.height * 2);
    caption_ = [[UILabel alloc] initWithFrame:captrect];
    [caption_ setText:UCLocalize("PREPARING_FILESYSTEM")];
    [caption_ setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin];
    [caption_ setFont:[UIFont boldSystemFontOfSize:28.0f]];
    [caption_ setBackgroundColor:UIColor.clearColor];
    [caption_ setTextAlignment:NSTextAlignmentCenter];
    [view addSubview:caption_];

    CGRect statusrect;
    statusrect.size.width = [[self view] frame].size.width;
    statusrect.size.height = 30.0f;
    statusrect.origin.x = 0;
    statusrect.origin.y = Retina([[self view] frame].size.height / 2 - statusrect.size.height);
    status_ = [[UILabel alloc] initWithFrame:statusrect];
    [status_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin];
    [status_ setText:UCLocalize("EXIT_WHEN_COMPLETE")];
    [status_ setFont:[UIFont systemFontOfSize:16.0f]];
    [status_ setBackgroundColor:UIColor.clearColor];
    [status_ setTextAlignment:NSTextAlignmentCenter];
    [view addSubview:status_];
    [self applyColorAppearance];
}

- (void) releaseSubviews {
    spinner_ = nil;
    status_ = nil;
    caption_ = nil;

    [super releaseSubviews];
}

@end
