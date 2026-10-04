/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/NativeMutationConfirmation.h"
#include "Cydia/NativeMutationEvidence.h"
#include "Cydia/AppState.h"
#include "CyteKit/Localize.h"
#import <UIKit/UIKit.h>
#include <dispatch/dispatch.h>

static BOOL CydiaNativeCompatibilityMutationReplayRequested(void) {
    /* This exact-value switch exists only for the installed P2.1 replay
     * receipt. Normal launches never schedule a second UIKit callback, and
     * the trigger cannot select an operation or supply mutation arguments. */
    return [[[[NSProcessInfo processInfo] environment]
        objectForKey:@"CYDIA_NATIVE_COMPATIBILITY_MUTATION_REPLAY"]
        isEqualToString:@"1"];
}

BOOL PresentNativeConfirmation(id presenter, NSString *message,
    NSString *actionTitle, id session, id target, NSString *operation,
    BOOL (^action)(void), NSString *effectKind) {
    if (![NSThread isMainThread]) {
        __block BOOL result(NO);
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = PresentNativeConfirmation(presenter, message, actionTitle,
                session, target, operation, action, effectKind);
        });
        return result;
    }
    static CydiaNativeMutationEvidence *evidence;
    /* A normal startup confirmation can occur before the opt-in diagnostic
     * environment is attached. Do not permanently cache that failed
     * initialization: retry lazily for the later diagnostic presentation. */
    @synchronized([CydiaNativeMutationEvidence class]) {
        if (evidence == nil || ![evidence isHealthy])
            evidence = [[CydiaNativeMutationEvidence alloc] initWithEnvironment:
                [[NSProcessInfo processInfo] environment] runtimeVersion:Cydia_];
    }
    NSString *request([evidence beginRequestWithSession:session target:target
        presenter:presenter operation:operation effectKind:effectKind]);
    CydiaNativeMutationAction *guard([[CydiaNativeMutationAction alloc]
        initWithEvidence:evidence request:request execute:action]);
    if (![presenter isKindOfClass:[UIViewController class]] || action == nil) {
        [guard presentationRejected];
        return NO;
    }
    UIViewController *controller((UIViewController *)presenter);
    if (controller.presentedViewController != nil || controller.viewIfLoaded.window == nil) {
        [guard presentationRejected];
        return NO;
    }
    BOOL replayAcceptedCallback(CydiaNativeCompatibilityMutationReplayRequested());
    UIAlertController *alert([UIAlertController
        alertControllerWithTitle:UCLocalize("CONFIRM")
        message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL")
        style:UIAlertActionStyleCancel handler:^(UIAlertAction *selected) {
            (void)selected;
            [guard cancel];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:actionTitle
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *selected) {
            (void)selected;
            [guard accept];
            if (replayAcceptedCallback)
                dispatch_async(dispatch_get_main_queue(), ^{
                    [guard accept];
                });
        }]];
    [guard presentationRequested];
    [controller presentViewController:alert animated:YES completion:^{ [guard presented]; }];
    return YES;
}
