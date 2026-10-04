/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_NativeMutationConfirmation_H
#define Cydia_NativeMutationConfirmation_H

#import <Foundation/Foundation.h>

/* Internal native-provider seam, not a compatibility or external-route API. */
BOOL PresentNativeConfirmation(id presenter, NSString *message,
    NSString *actionTitle, id session, id target, NSString *operation,
    BOOL (^action)(void), NSString *effectKind = @"typed-provider-call");

#endif // Cydia_NativeMutationConfirmation_H
