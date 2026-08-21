/* Cydia Refurbished native progress state boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_ProgressViewModel_H
#define Cydia_ProgressViewModel_H

#include "Cydia/ProgressData.h"
#include "Cydia/ProgressEvent.h"

#include <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CydiaProgressFinishAction) {
    CydiaProgressFinishActionNone = -1,
    CydiaProgressFinishActionReturnToCydia = 0,
    CydiaProgressFinishActionTerminate = 1,
    CydiaProgressFinishActionRestartSpringBoard = 2,
    CydiaProgressFinishActionReloadSpringBoard = 3,
    CydiaProgressFinishActionRebootDevice = 4,
};

typedef NS_ENUM(NSUInteger, CydiaProgressCancellationState) {
    CydiaProgressCancellationUnavailable = 0,
    CydiaProgressCancellationAvailable = 1,
    CydiaProgressCancellationRequested = 2,
};

typedef NS_ENUM(NSUInteger, CydiaProgressEventKind) {
    CydiaProgressEventKindInformation,
    CydiaProgressEventKindStatus,
    CydiaProgressEventKindWarning,
    CydiaProgressEventKindError,
    CydiaProgressEventKindUnknown,
};

typedef NS_ENUM(NSUInteger, CydiaProgressFinishSideEffect) {
    CydiaProgressFinishSideEffectNone,
    CydiaProgressFinishSideEffectReturnToCydia,
    CydiaProgressFinishSideEffectTerminate,
    CydiaProgressFinishSideEffectReloadSpringBoard,
    CydiaProgressFinishSideEffectRebootDevice,
};

typedef struct {
    CydiaProgressFinishSideEffect sideEffect;
    BOOL savesState;
    BOOL dismissesController;
} CydiaProgressFinishPlan;

typedef NS_OPTIONS(NSUInteger, CydiaProgressViewModelChange) {
    CydiaProgressViewModelChangeNone = 0,
    CydiaProgressViewModelChangeTitle = 1 << 0,
    CydiaProgressViewModelChangeMetrics = 1 << 1,
    CydiaProgressViewModelChangeEvents = 1 << 2,
    CydiaProgressViewModelChangeCancellation = 1 << 3,
    CydiaProgressViewModelChangeRunning = 1 << 4,
    CydiaProgressViewModelChangeFinish = 1 << 5,
    /* The temporary WebScript adapter must dispatch CydiaProgressUpdate when
     * this bit is present. Cancellation is intentionally not WebScript data. */
    CydiaProgressViewModelChangeLegacyData = 1 << 6,
};

typedef NSString * _Nullable (^CydiaProgressPackageNameResolver)(NSString *identifier);
typedef NSString * _Nonnull (^CydiaProgressLocalizer)(NSString *key);

@interface CydiaProgressPresentationEvent : NSObject <NSCopying>

@property(nonatomic, readonly) CydiaProgressEventKind kind;
@property(nonatomic, copy, readonly, nullable) NSString *rawType;
@property(nonatomic, copy, readonly, nullable) NSString *rawMessage;
@property(nonatomic, copy, readonly) NSString *displayMessage;
@property(nonatomic, copy, readonly) NSString *accessibilityLabel;
@property(nonatomic, copy, readonly, nullable) NSArray<NSString *> *item;
@property(nonatomic, copy, readonly, nullable) NSString *packageIdentifier;
@property(nonatomic, copy, readonly, nullable) NSString *URLString;
@property(nonatomic, copy, readonly, nullable) NSString *version;

@end

/* A published state is immutable. Controllers may retain it across a later
 * model change to calculate table updates or restore an unloaded view. */
@interface CydiaProgressViewState : NSObject <NSCopying>

@property(nonatomic, readonly) NSUInteger revision;
@property(nonatomic, copy, readonly, nullable) NSString *rawTitle;
@property(nonatomic, copy, readonly, nullable) NSString *localizedTitle;
@property(nonatomic, copy, readonly, nullable) NSString *statusText;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly) float rawPercent;
@property(nonatomic, readonly) float displayPercent;
@property(nonatomic, readonly, getter=isProgressDeterminate) BOOL progressDeterminate;
@property(nonatomic, readonly) float current;
@property(nonatomic, readonly) float total;
@property(nonatomic, readonly) float speed;
@property(nonatomic, copy, readonly) NSArray<CydiaProgressPresentationEvent *> *events;
@property(nonatomic, readonly) CydiaProgressCancellationState cancellationState;
@property(nonatomic, readonly) CydiaProgressFinishAction finishAction;
@property(nonatomic, copy, readonly, nullable) NSString *finishTitle;
@property(nonatomic, readonly) BOOL containsError;

@end

@class CydiaProgressViewModel;

@protocol CydiaProgressViewModelObserver <NSObject>

- (void) progressViewModel:(CydiaProgressViewModel *)model
           didPublishState:(CydiaProgressViewState *)state
                    change:(CydiaProgressViewModelChange)change;

@end

/* This object is deliberately downstream of ProgressDelegate. Database keeps
 * parsing APT acquire and dpkg status-fd streams; this model only normalizes
 * their already-ordered callbacks for legacy WebScript and native UIKit. */
@interface CydiaProgressViewModel : NSObject <ProgressDelegate>

@property(nonatomic, weak, nullable) NSObject<CydiaProgressViewModelObserver> *observer;
@property(nonatomic, strong, readonly) CydiaProgressData *legacyData;
@property(nonatomic, strong, readonly) CydiaProgressViewState *state;

- (instancetype) initWithLegacyData:(CydiaProgressData *)legacyData
                packageNameResolver:(nullable CydiaProgressPackageNameResolver)resolver
                           localizer:(nullable CydiaProgressLocalizer)localizer NS_DESIGNATED_INITIALIZER;
- (instancetype) initWithPackageNameResolver:(nullable CydiaProgressPackageNameResolver)resolver;
- (instancetype) init;

- (void) beginWithTitle:(nullable NSString *)title;
- (void) completeWithFinishAction:(CydiaProgressFinishAction)action;
- (void) requestCancellation;
- (void) setCancellable:(bool)cancellable;

@end

FOUNDATION_EXPORT NSString * _Nullable CydiaProgressFinishLocalizationKey(
    CydiaProgressFinishAction action);

/* Dpkg may publish a stronger finish requirement after the transaction body
 * returns but before the user taps Close. Never let the immutable completion
 * snapshot weaken that live, monotonic requirement. */
FOUNDATION_EXPORT CydiaProgressFinishAction CydiaProgressEffectiveFinishAction(
    CydiaProgressFinishAction snapshot,
    NSInteger liveAction);

/* Pure policy fixture for controller side effects. The controller still owns
 * their ordering and invokes the existing application delegate methods. */
FOUNDATION_EXPORT CydiaProgressFinishPlan CydiaProgressFinishPlanForAction(
    CydiaProgressFinishAction action);

NS_ASSUME_NONNULL_END

#endif // Cydia_ProgressViewModel_H
