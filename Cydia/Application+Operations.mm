/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/Application.h"
#include "Cydia/ApplicationInternal.h"
#include "Cydia/AppState.h"
#include "Cydia/Appearance.h"
#include "Cydia/ConfirmationController.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/ProgressController.h"
#include "Cydia/ProgressEvent.h"
#include "Cydia/ControllerState.h"
#include "Cydia/Source.h"
#include "Cydia/TabBarController.h"
#include "CyteKit/CyteKit.h"
#include "CyteKit/Localize.h"
#include "CyteKit/extern.h"
#include "Menes/Menes.h"
#include "CyteKit/RegEx.hpp"
#include "Sources.h"
#include "Substrate.hpp"
#include "iPhonePrivate.h"

#include <cstdio>

#include "apt.h"
#include <apt-pkg/algorithms.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>

#define ForRelease 1
#define AlwaysReload 0
#define CacheState_ Cache("CacheState.plist")

#undef _trace
#define _trace(args...)
#undef _profile
#define _profile(name) {
#undef _end
#define _end }
#define PrintTimes() do {} while (false)
#define lprintf(args...) fprintf(stderr, args)

@implementation Cydia (Operations)
- (ProgressController *) invokeNewProgress:(NSInvocation *)invocation forController:(UINavigationController *)navigation withTitle:(NSString *)title {
    ProgressController *progress([[ProgressController alloc] initWithDatabase:database_ delegate:self]);

    if (navigation != nil)
        [navigation pushViewController:progress animated:YES];
    else
        [self presentModalViewController:progress force:YES];

    [progress invoke:invocation withTitle:title];
    return progress;
}

- (void) detachNewProgressSelector:(SEL)selector toTarget:(id)target forController:(UINavigationController *)navigation title:(NSString *)title {
    [self invokeNewProgress:[NSInvocation invocationWithSelector:selector forTarget:target] forController:navigation withTitle:title];
}

- (void) repairWithInvocation:(NSInvocation *)invocation {
    _trace();
    [self invokeNewProgress:invocation forController:nil withTitle:@"REPAIRING"];
    _trace();
}

- (void) repairWithSelector:(SEL)selector {
    [self performSelectorOnMainThread:@selector(repairWithInvocation:) withObject:[NSInvocation invocationWithSelector:selector forTarget:database_] waitUntilDone:YES];
}

- (void) resolve {
    pkgProblemResolver *resolver = [database_ resolver];

    resolver->InstallProtect();
    if (!resolver->Resolve(true))
        _error->Discard();
}

- (bool) perform {
    // XXX: this is a really crappy way of doing this.
    // like, seriously: this state machine is still broken, and cancelling this here doesn't really /fix/ that.
    // for one, the user can still /start/ a reloading data event while they have a queue, which is stupid
    // for two, this just means there is a race condition between the refresh completing and the confirmation controller appearing.
    if ([tabbar_ updating])
        [tabbar_ cancelUpdate];

    if (![database_ prepare])
        return false;

    ConfirmationController *page([[ConfirmationController alloc] initWithDatabase:database_]);
    [page setDelegate:self];
    UINavigationController *confirm_([[UINavigationController alloc] initWithRootViewController:page]);

    if (IsWildcat_)
        [confirm_ setModalPresentationStyle:UIModalPresentationFormSheet];
    [tabbar_ presentModalViewController:confirm_ animated:YES];

    return true;
}

- (void) queue {
    @synchronized (self) {
        [self perform];
    }
}

- (void) clearPackage:(Package *)package {
    @synchronized (self) {
        [package clear];
        [self resolve];
        [self perform];
    }
}

- (void) installPackages:(NSArray *)packages {
    @synchronized (self) {
        for (Package *package in packages)
            [package install];
        [self resolve];
        [self perform];
    }
}

- (void) installPackage:(Package *)package {
    @synchronized (self) {
        [package install];
        [self resolve];
        [self perform];
    }
}

- (void) removePackage:(Package *)package {
    @synchronized (self) {
        [package remove];
        [self resolve];
        [self perform];
    }
}

- (void) distUpgrade {
    @synchronized (self) {
        if (![database_ upgrade])
            return;
        [self perform];
    }
}

- (void) _uicache {
    _trace();
    system("/usr/bin/uicache");
    _trace();
}

- (void) uicache {
    UIProgressHUD *hud([self addProgressHUD]);
    [hud setText:UCLocalize("LOADING")];
    [self yieldToSelector:@selector(_uicache)];
    [self removeProgressHUD:hud];
}

- (void) perform_ {
    [database_ perform];
    if (Finish_ == 0 && !RestartSubstrate_) {
        [self performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:YES];
    } else {
        // Reload data when we open up again
        if (NSMutableDictionary *cache = [NSMutableDictionary dictionaryWithContentsOfFile:CacheState_]) {
            [cache removeObjectForKey:@"LastUpdate"];
            [cache writeToFile:CacheState_ atomically:YES];
        }
    }
    if (UICache_) {
        UICache_ = false;
        [self performSelectorOnMainThread:@selector(uicache) withObject:nil waitUntilDone:YES];
    }
}

- (void) confirmWithNavigationController:(UINavigationController *)navigation {
    Queuing_ = false;
    [self lockSuspend];
    [self detachNewProgressSelector:@selector(perform_) toTarget:self forController:navigation title:@"RUNNING"];
    [self unlockSuspend];
}

- (void) cancelAndClear:(bool)clear {
    @synchronized (self) {
        if (clear) {
            [database_ clear];
            Queuing_ = false;
        } else {
            Queuing_ = true;
        }

        [self _updateData];
    }
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"conffile"]) {
        FILE *input = [database_ input];
        if (button == [alert cancelButtonIndex])
            fprintf(input, "N\n");
        else if (button == [alert firstOtherButtonIndex])
            fprintf(input, "Y\n");
        fflush(input);

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"fixhalf"]) {
        if (button == [alert cancelButtonIndex]) {
            @synchronized (self) {
                for (Package *broken in (id) broken_) {
                    [broken remove];
                    NSString *id(ShellEscape([broken id]));
                    system([[NSString stringWithFormat:@"/usr/libexec/cydia/cydo /bin/rm -f"
                        " /var/lib/dpkg/info/%@.prerm"
                        " /var/lib/dpkg/info/%@.postrm"
                        " /var/lib/dpkg/info/%@.preinst"
                        " /var/lib/dpkg/info/%@.postinst"
                        " /var/lib/dpkg/info/%@.extrainst_"
                    "", id, id, id, id, id] UTF8String]);
                }

                [self resolve];
                [self perform];
            }
        } else if (button == [alert firstOtherButtonIndex]) {
            [broken_ removeAllObjects];
            [self _loaded];
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"upgrade"]) {
        if (button == [alert firstOtherButtonIndex]) {
            @synchronized (self) {
                for (Package *essential in (id) essential_)
                    [essential install];

                [self resolve];
                [self perform];
            }
        } else if (button == [alert firstOtherButtonIndex] + 1) {
            [self distUpgrade];
        } else if (button == [alert cancelButtonIndex]) {
            Ignored_ = YES;
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    }
}

- (void) setConfigurationData:(NSString *)data {
    static RegEx conffile_r("'(.*)' '(.*)' ([01]) ([01])");

    if (!conffile_r(data)) {
        lprintf("E:invalid conffile\n");
        return;
    }

    NSString *ofile = conffile_r[1];
    //NSString *nfile = conffile_r[2];

    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:UCLocalize("CONFIGURATION_UPGRADE")
        message:[NSString stringWithFormat:@"%@\n\n%@", UCLocalize("CONFIGURATION_UPGRADE_EX"), ofile]
        delegate:self
        cancelButtonTitle:UCLocalize("KEEP_OLD_COPY")
        otherButtonTitles:
            UCLocalize("ACCEPT_NEW_COPY"),
            // XXX: UCLocalize("SEE_WHAT_CHANGED"),
        nil
    ];

    [alert setContext:@"conffile"];
    [alert setNumberOfRows:2];
    [alert show];
}

- (void) showActionSheet:(UIActionSheet *)sheet fromItem:(UIBarButtonItem *)item {
    if (!IsWildcat_) {
       [sheet addButtonWithTitle:UCLocalize("CANCEL")];
       [sheet setCancelButtonIndex:[sheet numberOfButtons] - 1];
    }

    if (item != nil && IsWildcat_) {
        [sheet showFromBarButtonItem:item animated:YES];
    } else {
        [sheet showInView:window_];
    }
}

- (void) addProgressEvent:(CydiaProgressEvent *)event forTask:(NSString *)task {
    id<ProgressDelegate> progress([database_ progressDelegate] ?: [self invokeNewProgress:nil forController:nil withTitle:task]);
    [progress setTitle:task];
    [progress addProgressEvent:event];
}

- (void) addProgressEventForTask:(NSArray *)data {
    CydiaProgressEvent *event([data objectAtIndex:0]);
    NSString *task([data count] < 2 ? nil : [data objectAtIndex:1]);
    [self addProgressEvent:event forTask:task];
}

- (void) addProgressEventOnMainThread:(CydiaProgressEvent *)event forTask:(NSString *)task {
    [self performSelectorOnMainThread:@selector(addProgressEventForTask:) withObject:[NSArray arrayWithObjects:event, task, nil] waitUntilDone:YES];
}
@end
