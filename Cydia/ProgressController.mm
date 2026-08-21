/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished native-model work Copyright (C) 2026 Torrekie
 */

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
 */
/* }}} */

#include "Cydia/ProgressController.h"

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/Appearance.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/PrivateServices.h"
#include "Cydia/RebootCompat.h"
#include "CyteKit/Localize.h"
#include "Menes/yieldToSelector.h"
#include "iPhonePrivate.h"

#include <notify.h>

extern const NSString *UI_;
extern bool RestartSubstrate_;
extern void UpdateExternalStatus(uint64_t newStatus);

#define SpringBoard_ "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
#define NotifyConfig_ "/etc/notify.conf"

static std::string FileFingerprint(const char *path) {
    if (path == NULL)
        return std::string();

    NSData *data([NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]]);
    if (data == nil)
        return std::string();
    return CydiaAPT::Fingerprint([data bytes], [data length]);
}

@protocol ProgressControllerDelegate <NSObject>
- (void) saveState;
- (void) returnToCydia;
- (void) terminateWithSuccess;
- (UIProgressHUD *) addProgressHUD;
- (void) reloadSpringBoard;
@end

@implementation ProgressController

- (void) dealloc {
    [progressModel_ setObserver:nil];
    if ([database_ progressDelegate] == (CydiaProgressViewModel *) progressModel_)
        [database_ setProgressDelegate:nil];
}

- (UIBarButtonItem *) leftButton {
    return [[progressModel_ state] cancellationState] == CydiaProgressCancellationAvailable ? [[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("CANCEL")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(cancel)
    ] : nil;
}

- (void) updateCancel {
    [super applyLeftButton];
}

- (id) initWithDatabase:(Database *)database delegate:(id)delegate {
    if ((self = [super init]) != nil) {
        database_ = database;
        self.delegate = delegate;

        __weak Database *weakDatabase(database);
        progressModel_ = [[CydiaProgressViewModel alloc]
            initWithPackageNameResolver:^NSString *(NSString *identifier) {
                if (![weakDatabase hasPackages])
                    return nil;
                Package *package([weakDatabase packageWithName:identifier]);
                return [package name];
            }];
        [progressModel_ setObserver:self];
        [database_ setProgressDelegate:progressModel_];

        [self setURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/progress/", UI_]]];

        [self setPageColor:[UIColor cydiaColorForRole:CydiaColorRoleBackground
                                      traitCollection:self.traitCollection]];

        [[self navigationItem] setHidesBackButton:YES];

        [self updateCancel];
    } return self;
}

- (void) webView:(WebView *)view didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame {
    [super webView:view didClearWindowObject:window forFrame:frame];
    [window setValue:[progressModel_ legacyData] forKey:@"cydiaProgress"];
}

- (void) updateProgress {
    [self dispatchEvent:@"CydiaProgressUpdate"];
}

- (void) viewWillAppear:(BOOL)animated {
    [[[self navigationController] navigationBar] setBarStyle:UIBarStyleDefault];
    [self setPageColor:[UIColor cydiaColorForRole:CydiaColorRoleBackground
                                  traitCollection:self.traitCollection]];
    [super viewWillAppear:animated];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    BOOL appearanceChanged = CydiaColorAppearanceDidChange(self.traitCollection, previousTraitCollection);
    if (appearanceChanged)
        [self setPageColor:[UIColor cydiaColorForRole:CydiaColorRoleBackground
                                      traitCollection:self.traitCollection]];

    // CyteWebViewController repaints its scroller from pageColor in its trait
    // callback, so update the explicit progress color before calling super.
    [super traitCollectionDidChange:previousTraitCollection];
    if (appearanceChanged)
        [[[self navigationController] navigationBar] setBarStyle:UIBarStyleDefault];
}

- (void) close {
    UpdateExternalStatus(0);

    id<ProgressControllerDelegate> delegate(self.delegate);
    CydiaProgressFinishAction action(CydiaProgressEffectiveFinishAction(
        [[progressModel_ state] finishAction], Finish_));
    if (action > CydiaProgressFinishActionTerminate)
        [delegate saveState];

    switch (action) {
        case CydiaProgressFinishActionNone:
            _assume(false);
        break;

        case CydiaProgressFinishActionReturnToCydia:
            [delegate returnToCydia];
        break;

        case CydiaProgressFinishActionTerminate:
            [delegate terminateWithSuccess];
            /*if ([self.delegate respondsToSelector:@selector(suspendWithAnimation:)])
                [self.delegate suspendWithAnimation:YES];
            else
                [self.delegate suspend];*/
        break;

        case CydiaProgressFinishActionRestartSpringBoard:
            _trace();
            goto reload;

        case CydiaProgressFinishActionReloadSpringBoard:
            _trace();
            goto reload;

        reload: {
            UIProgressHUD *hud([delegate addProgressHUD]);
            [hud setText:UCLocalize("LOADING")];
            [(NSObject *) delegate performSelector:@selector(reloadSpringBoard) withObject:nil afterDelay:0.5];
            return;
        }

        case CydiaProgressFinishActionRebootDevice:
            _trace();
            CydiaReboot(RB_AUTOBOOT);
        break;
    }

    [super close];
}

- (void) setTitle:(NSString *)title {
    [progressModel_ setTitle:title];
}

- (UIBarButtonItem *) rightButton {
    return [[progressModel_ state] isRunning] ? [super rightButton] : [[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("CLOSE")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(close)
    ];
}

- (void) invoke:(NSInvocation *)invocation withTitle:(NSString *)title {
    UpdateExternalStatus(1);

    [progressModel_ beginWithTitle:title];

    std::string notifyconf(FileFingerprint(NotifyConfig_));
    std::string springlist(FileFingerprint(SpringBoard_));

    if (invocation != nil) {
        [invocation yieldToSelector:@selector(invoke)];
        [self setTitle:@"COMPLETE"];
    }

    if (Finish_ < 4) {
        if (notifyconf != FileFingerprint(NotifyConfig_))
            Finish_ = 4;
    }

    if (Finish_ < 3) {
        if (springlist != FileFingerprint(SpringBoard_))
            Finish_ = 3;
    }

    if (Finish_ < 2) {
        if (RestartSubstrate_)
            Finish_ = 2;
    }

    RestartSubstrate_ = false;

    UpdateExternalStatus(Finish_ == 0 ? 0 : 2);

    [progressModel_ completeWithFinishAction:static_cast<CydiaProgressFinishAction>(Finish_)];
}

- (void) addProgressEvent:(CydiaProgressEvent *)event {
    [progressModel_ addProgressEvent:event];
}

- (bool) isProgressCancelled {
    return [progressModel_ isProgressCancelled];
}

- (void) cancel {
    [progressModel_ requestCancellation];
}

- (void) setCancellable:(bool)cancellable {
    [progressModel_ setCancellable:cancellable];
}

- (void) setProgressCancellable:(NSNumber *)cancellable {
    [progressModel_ setProgressCancellable:cancellable];
}

- (void) setProgressPercent:(NSNumber *)percent {
    [progressModel_ setProgressPercent:percent];
}

- (void) setProgressStatus:(NSDictionary *)status {
    [progressModel_ setProgressStatus:status];
}

- (void) progressViewModel:(CydiaProgressViewModel *)model
           didPublishState:(CydiaProgressViewState *)state
                    change:(CydiaProgressViewModelChange)change {
    (void) model;
    (void) state;
    if ((change & CydiaProgressViewModelChangeLegacyData) != 0)
        [self updateProgress];
    if ((change & CydiaProgressViewModelChangeCancellation) != 0)
        [self updateCancel];
    if ((change & CydiaProgressViewModelChangeFinish) != 0)
        [self applyRightButton];
}

@end
