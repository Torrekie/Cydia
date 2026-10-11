/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/Application.h"
#include "Cydia/ApplicationInternal.h"
#include "Cydia/AptCompatibility.hpp"
#include "Cydia/AppState.h"
#include "Cydia/Appearance.h"
#include "Cydia/ConfirmationController.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/DpkgRunner.h"
#include "Cydia/Package.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/ProgressController.h"
#include "Cydia/ProgressEvent.h"
#include "Cydia/ControllerState.h"
#include "Cydia/RecoveryController.h"
#include "Cydia/Source.h"
#include "Cydia/TabBarController.h"
#include "Cydia/TransactionOutcomePolicy.hpp"
#include "CyteKit/CyteKit.h"
#include "CyteKit/Localize.h"
#include "CyteKit/extern.h"
#include "Menes/Menes.h"
#include "CyteKit/RegEx.hpp"
#include "Sources.h"
#include "Substrate.hpp"
#include "iPhonePrivate.h"

#include <cstdio>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

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

/* A run-scoped, opt-in trace for the ordinary package Confirmation delegate.
 * The native compatibility journal cannot observe this legacy package path,
 * while installed acceptance needs direct evidence that Cancel/Continue and
 * Confirm crossed the delegate exactly once.  No file is opened and no log is
 * emitted during normal launches.  The caller must provide a unique absolute
 * O_EXCL path through the launch environment; failed or incomplete traces are
 * never interpreted as zero callbacks. */
static void CydiaTransactionDelegateTrace(NSString *event, BOOL hasClear, BOOL clear) {
    NSDictionary *environment([[NSProcessInfo processInfo] environment]);
    NSString *path([environment objectForKey:@"CYDIA_NATIVE_TRANSACTION_TRACE_PATH"]);
    if (![path isKindOfClass:[NSString class]] || [path length] == 0 ||
        [path length] > 1024 || ![path hasPrefix:@"/"] ||
        [path rangeOfString:@".."].location != NSNotFound ||
        [event isEqualToString:@"confirmWithNavigationController"] == NO &&
        [event isEqualToString:@"cancelAndClear"] == NO)
        return;

    static int descriptor(-2);
    static NSString *processInstance;
    if (descriptor == -2) {
        descriptor = open([path fileSystemRepresentation],
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (descriptor >= 0)
            processInstance = [[NSUUID UUID] UUIDString];
    }
    if (descriptor < 0)
        return;

    NSMutableDictionary *record([@{
        @"schema": @1,
        @"event": event,
        @"processID": @((unsigned int)getpid()),
        @"processInstance": processInstance ?: @""
    } mutableCopy]);
    if (hasClear)
        [record setObject:@(clear) forKey:@"clear"];
    NSData *json([NSJSONSerialization dataWithJSONObject:record options:0 error:NULL]);
    if (json == nil) {
        close(descriptor);
        descriptor = -1;
        return;
    }
    NSMutableData *line([json mutableCopy]);
    [line appendBytes:"\n" length:1];
    const char *bytes((const char *)[line bytes]);
    NSUInteger remaining([line length]);
    while (remaining != 0) {
        ssize_t written(write(descriptor, bytes, remaining));
        if (written < 0 && errno == EINTR)
            continue;
        if (written <= 0) {
            close(descriptor);
            descriptor = -1;
            return;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    if (fsync(descriptor) != 0) {
        close(descriptor);
        descriptor = -1;
    }
}

@implementation Cydia (Operations)
- (void)showPackageRecovery:(NSArray *)packages {
    if (packages.count == 0) return;
    UIViewController *presented([tabbar_ presentedViewController]);
    if ([presented isKindOfClass:[UINavigationController class]] &&
        [[(UINavigationController *)presented viewControllers].firstObject isKindOfClass:[CydiaRecoveryController class]]) return;
    if (presented != nil) return;
    CydiaRecoveryController *controller([[CydiaRecoveryController alloc] initWithDatabase:database_ packages:packages]);
    [controller setDelegate:self];
    UINavigationController *navigation([[UINavigationController alloc] initWithRootViewController:controller]);
    if (IsWildcat_) navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [tabbar_ presentViewController:navigation animated:YES completion:nil];
}
- (ProgressController *) invokeNewProgress:(NSInvocation *)invocation forController:(UINavigationController *)navigation withTitle:(NSString *)title {
    ProgressController *progress([[ProgressController alloc] initWithDatabase:database_ delegate:self]);

    if (navigation != nil)
        [navigation pushViewController:progress animated:YES];
    else
        [self presentModalViewController:progress force:YES];

    /* A slow acquisition must not begin until UIKit has committed the native
     * Progress screen. Otherwise the nested invocation run loop leaves the
     * Confirmation hierarchy visible and makes its acquisition Cancel action
     * unreachable until the fetch has already ended. */
    [progress invokeWhenVisible:invocation withTitle:title];
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
    (void) [database_ resolveDependencies];
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
            if (![package install]) return;
        [self resolve];
        [self perform];
    }
}

- (void) installPackage:(Package *)package {
    @synchronized (self) {
        if (![package install]) return;
        [self resolve];
        [self perform];
    }
}

- (void) removePackage:(Package *)package {
    @synchronized (self) {
        if (![package remove]) return;
        [self resolve];
        [self perform];
    }
}

- (void) reinstallPackage:(Package *)package {
    @synchronized (self) {
        if (![package reinstall]) return;
        [self resolve];
        [self perform];
    }
}

- (void) purgePackage:(Package *)package {
    @synchronized (self) {
        if (![package purge]) return;
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
    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    CydiaRuntime::Dpkg::Runner runner(paths.CydoPath());
    (void) runner.Run({paths.BootstrapBinaryPath("uicache")});
    _trace();
}

- (void) uicache {
    UIProgressHUD *hud([self addProgressHUD]);
    [hud setText:UCLocalize("LOADING")];
    [self yieldToSelector:@selector(_uicache)];
    [self removeProgressHUD:hud];
}

- (bool) perform_ {
    const bool succeeded([database_ perform]);
    const CydiaRuntime::TransactionCompletionPlan completion(CydiaRuntime::PlanTransactionCompletion(
        [database_ lastTransactionResult], succeeded, false, Finish_ != 0 || RestartSubstrate_));
    if (completion.reloadNow) {
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
    return completion.succeeded;
}

- (void) confirmWithNavigationController:(UINavigationController *)navigation {
    CydiaTransactionDelegateTrace(@"confirmWithNavigationController", NO, NO);
    Queuing_ = false;
    [self lockSuspend];
    [self detachNewProgressSelector:@selector(perform_) toTarget:self forController:navigation title:@"RUNNING"];
    [self unlockSuspend];
}

- (void) cancelAndClear:(bool)clear {
    CydiaTransactionDelegateTrace(@"cancelAndClear", YES, clear);
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
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
        [self showPackageRecovery:broken_];
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
