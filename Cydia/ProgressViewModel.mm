/* Cydia Refurbished native progress state boundary.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ProgressViewModel.h"

#include <cmath>

static NSString * const kCydiaProgressEventTypeError = @"Error";
static NSString * const kCydiaProgressEventTypeInformation = @"Information";
static NSString * const kCydiaProgressEventTypeStatus = @"Status";
static NSString * const kCydiaProgressEventTypeWarning = @"Warning";

@interface CydiaProgressPresentationEvent ()
@property(nonatomic) CydiaProgressEventKind kind;
@property(nonatomic, copy, nullable) NSString *rawType;
@property(nonatomic, copy, nullable) NSString *rawMessage;
@property(nonatomic, copy) NSString *displayMessage;
@property(nonatomic, copy) NSString *accessibilityLabel;
@property(nonatomic, copy, nullable) NSArray<NSString *> *item;
@property(nonatomic, copy, nullable) NSString *packageIdentifier;
@property(nonatomic, copy, nullable) NSString *URLString;
@property(nonatomic, copy, nullable) NSString *version;
@end

@implementation CydiaProgressPresentationEvent

- (id) copyWithZone:(NSZone *)zone {
    (void) zone;
    return self;
}

@end

@interface CydiaProgressViewState ()
@property(nonatomic) NSUInteger revision;
@property(nonatomic, copy, nullable) NSString *rawTitle;
@property(nonatomic, copy, nullable) NSString *localizedTitle;
@property(nonatomic, copy, nullable) NSString *statusText;
@property(nonatomic, getter=isRunning) BOOL running;
@property(nonatomic) float rawPercent;
@property(nonatomic) float displayPercent;
@property(nonatomic, getter=isProgressDeterminate) BOOL progressDeterminate;
@property(nonatomic) float current;
@property(nonatomic) float total;
@property(nonatomic) float speed;
@property(nonatomic, copy) NSArray<CydiaProgressPresentationEvent *> *events;
@property(nonatomic) CydiaProgressCancellationState cancellationState;
@property(nonatomic) CydiaProgressFinishAction finishAction;
@property(nonatomic, copy, nullable) NSString *finishTitle;
@property(nonatomic) BOOL containsError;
@end

@implementation CydiaProgressViewState

- (id) copyWithZone:(NSZone *)zone {
    (void) zone;
    return self;
}

@end

NSString *CydiaProgressFinishLocalizationKey(CydiaProgressFinishAction action) {
    switch (action) {
        case CydiaProgressFinishActionNone: return nil;
        case CydiaProgressFinishActionReturnToCydia: return @"RETURN_TO_CYDIA";
        case CydiaProgressFinishActionTerminate: return @"CLOSE_CYDIA";
        case CydiaProgressFinishActionRestartSpringBoard: return @"RESTART_SPRINGBOARD";
        case CydiaProgressFinishActionReloadSpringBoard: return @"RELOAD_SPRINGBOARD";
        case CydiaProgressFinishActionRebootDevice: return @"REBOOT_DEVICE";
    }
    return nil;
}

CydiaProgressFinishAction CydiaProgressEffectiveFinishAction(
    CydiaProgressFinishAction snapshot,
    NSInteger liveAction) {
    if (liveAction < CydiaProgressFinishActionReturnToCydia ||
        liveAction > CydiaProgressFinishActionRebootDevice)
        return snapshot;

    CydiaProgressFinishAction live(static_cast<CydiaProgressFinishAction>(liveAction));
    return snapshot < live ? live : snapshot;
}

static NSString *CydiaProgressString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSArray<NSString *> *CydiaProgressStringArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static CydiaProgressEventKind CydiaProgressKind(NSString *type) {
    if ([type isEqualToString:kCydiaProgressEventTypeInformation])
        return CydiaProgressEventKindInformation;
    if ([type isEqualToString:kCydiaProgressEventTypeStatus])
        return CydiaProgressEventKindStatus;
    if ([type isEqualToString:kCydiaProgressEventTypeWarning])
        return CydiaProgressEventKindWarning;
    if ([type isEqualToString:kCydiaProgressEventTypeError])
        return CydiaProgressEventKindError;
    return CydiaProgressEventKindUnknown;
}

/* The legacy page first removes one terminal CR and then greedily discards
 * everything through the last remaining CR. This preserves command-line tools
 * that redraw a single line without leaking their overwritten text into UIKit. */
static NSString *CydiaProgressLogMessage(NSString *message) {
    if (message == nil)
        return @"";
    if ([message hasSuffix:@"\r"])
        message = [message substringToIndex:[message length] - 1];
    NSRange carriageReturn([message rangeOfString:@"\r" options:NSBackwardsSearch]);
    if (carriageReturn.location != NSNotFound)
        message = [message substringFromIndex:NSMaxRange(carriageReturn)];
    return message;
}

@interface CydiaProgressViewModel () {
    CydiaProgressCancellationState cancellationState_;
    CydiaProgressFinishAction finishAction_;
    BOOL containsError_;
    NSUInteger revision_;
}
@property(nonatomic, strong) CydiaProgressData *legacyDataStorage;
@property(nonatomic, strong) CydiaProgressViewState *stateStorage;
@property(nonatomic, strong) NSMutableArray<CydiaProgressPresentationEvent *> *presentationEvents;
@property(nonatomic, copy) NSArray<CydiaProgressPresentationEvent *> *publishedEvents;
@property(nonatomic, copy, nullable) CydiaProgressPackageNameResolver packageNameResolver;
@property(nonatomic, copy) CydiaProgressLocalizer localizer;
@property(nonatomic, copy, nullable) NSString *statusTextStorage;
@end

@implementation CydiaProgressViewModel

- (instancetype) init {
    return [self initWithPackageNameResolver:nil];
}

- (instancetype) initWithPackageNameResolver:(CydiaProgressPackageNameResolver)resolver {
    return [self initWithLegacyData:[[CydiaProgressData alloc] init]
                packageNameResolver:resolver
                           localizer:nil];
}

- (instancetype) initWithLegacyData:(CydiaProgressData *)legacyData
                packageNameResolver:(CydiaProgressPackageNameResolver)resolver
                           localizer:(CydiaProgressLocalizer)localizer {
    if ((self = [super init]) != nil) {
        NSParameterAssert(legacyData != nil);
        self.legacyDataStorage = legacyData;
        [self.legacyDataStorage setDelegate:self];
        self.packageNameResolver = resolver;
        self.localizer = localizer ?: ^NSString *(NSString *key) {
            return [[NSBundle mainBundle] localizedStringForKey:key value:nil table:nil];
        };
        self.presentationEvents = [NSMutableArray arrayWithCapacity:32];
        self.publishedEvents = @[];
        cancellationState_ = CydiaProgressCancellationUnavailable;
        finishAction_ = CydiaProgressFinishActionNone;
        [self publishChange:CydiaProgressViewModelChangeNone notify:NO];
    }
    return self;
}

- (CydiaProgressData *) legacyData {
    return self.legacyDataStorage;
}

- (CydiaProgressViewState *) state {
    return self.stateStorage;
}

- (NSString *) localized:(NSString *)key {
    return key == nil ? nil : self.localizer(key);
}

- (CydiaProgressCancellationState) currentCancellationState {
    @synchronized (self) {
        return cancellationState_;
    }
}

- (void) assertMainThread {
    NSAssert([NSThread isMainThread], @"progress mutations must remain ordered on the main thread");
}

- (void) publishChange:(CydiaProgressViewModelChange)change notify:(BOOL)notify {
    CydiaProgressViewState *state([[CydiaProgressViewState alloc] init]);
    state.revision = revision_;
    state.rawTitle = CydiaProgressString([self.legacyDataStorage title]);
    state.localizedTitle = [self localized:state.rawTitle];
    state.statusText = self.statusTextStorage;
    state.running = [[self.legacyDataStorage running] boolValue];
    state.rawPercent = [[self.legacyDataStorage percent] floatValue];
    state.progressDeterminate = std::isfinite(state.rawPercent);
    state.displayPercent = state.progressDeterminate ?
        std::fmax(0.0f, std::fmin(1.0f, state.rawPercent)) : 0.0f;
    state.current = [[self.legacyDataStorage current] floatValue];
    state.total = [[self.legacyDataStorage total] floatValue];
    state.speed = [[self.legacyDataStorage speed] floatValue];
    state.events = self.publishedEvents;
    state.cancellationState = [self currentCancellationState];
    state.finishAction = finishAction_;
    state.finishTitle = CydiaProgressString([self.legacyDataStorage finish]);
    state.containsError = containsError_;
    self.stateStorage = state;

    if (notify) {
        NSObject<CydiaProgressViewModelObserver> *observer = self.observer;
        [observer progressViewModel:self didPublishState:state change:change];
    }
}

- (void) changed:(CydiaProgressViewModelChange)change {
    ++revision_;
    [self publishChange:change notify:YES];
}

- (NSString *) substitutePackageNames:(NSString *)message {
    if (message == nil || self.packageNameResolver == nil)
        return message;

    NSMutableArray<NSString *> *words([[message componentsSeparatedByString:@" "] mutableCopy]);
    for (NSUInteger index(0); index != [words count]; ++index) {
        NSString *replacement(self.packageNameResolver([words objectAtIndex:index]));
        if (replacement != nil)
            [words replaceObjectAtIndex:index withObject:replacement];
    }
    return [words componentsJoinedByString:@" "];
}

- (NSString *) accessibilityLabelForKind:(CydiaProgressEventKind)kind
                                  message:(NSString *)message {
    NSString *mode(nil);
    if (kind == CydiaProgressEventKindError)
        mode = [self localized:@"ERROR"];
    else if (kind == CydiaProgressEventKindWarning)
        mode = [self localized:@"WARNING"];
    if (mode == nil)
        return message;
    return [NSString stringWithFormat:[self localized:@"COLON_DELIMITED"], mode, message];
}

- (void) beginWithTitle:(NSString *)title {
    [self assertMainThread];
    [self.legacyDataStorage setRunning:true];
    [self.legacyDataStorage setTitle:title];
    [self changed:CydiaProgressViewModelChangeTitle |
                  CydiaProgressViewModelChangeRunning |
                  CydiaProgressViewModelChangeLegacyData];
}

- (void) completeWithFinishAction:(CydiaProgressFinishAction)action {
    [self assertMainThread];
    NSString *key(CydiaProgressFinishLocalizationKey(action));
    NSParameterAssert(key != nil);
    finishAction_ = action;
    [self.legacyDataStorage setFinish:[self localized:key]];
    [self.legacyDataStorage setRunning:false];
    [self changed:CydiaProgressViewModelChangeRunning |
                  CydiaProgressViewModelChangeFinish |
                  CydiaProgressViewModelChangeLegacyData];
}

- (void) setTitle:(NSString *)title {
    [self assertMainThread];
    [self.legacyDataStorage setTitle:title];
    [self changed:CydiaProgressViewModelChangeTitle |
                  CydiaProgressViewModelChangeLegacyData];
}

- (void) addProgressEvent:(CydiaProgressEvent *)event {
    [self assertMainThread];
    if (event == nil)
        return;

    NSString *type(CydiaProgressString([event type]));
    NSString *rawMessage(CydiaProgressString([event message]));
    CydiaProgressEventKind kind(CydiaProgressKind(type));
    NSString *substituted(kind == CydiaProgressEventKindStatus ?
        [self substitutePackageNames:rawMessage] : rawMessage);

    CydiaProgressPresentationEvent *presentation([[CydiaProgressPresentationEvent alloc] init]);
    presentation.kind = kind;
    presentation.rawType = type;
    presentation.rawMessage = rawMessage;
    presentation.displayMessage = CydiaProgressLogMessage(substituted);
    presentation.accessibilityLabel = [self accessibilityLabelForKind:kind
                                                               message:presentation.displayMessage];
    presentation.item = CydiaProgressStringArray([event item]);
    presentation.packageIdentifier = CydiaProgressString([event package]);
    presentation.URLString = CydiaProgressString([event url]);
    presentation.version = CydiaProgressString([event version]);

    [self.legacyDataStorage addEvent:event];
    [self.presentationEvents addObject:presentation];
    self.publishedEvents = [self.presentationEvents copy];
    if (kind == CydiaProgressEventKindStatus)
        self.statusTextStorage = substituted ?: @"";
    if (kind == CydiaProgressEventKindError)
        containsError_ = YES;
    [self changed:CydiaProgressViewModelChangeEvents |
                  CydiaProgressViewModelChangeLegacyData];
}

- (void) setProgressPercent:(NSNumber *)percent {
    [self assertMainThread];
    [self.legacyDataStorage setPercent:[percent floatValue]];
    [self changed:CydiaProgressViewModelChangeMetrics |
                  CydiaProgressViewModelChangeLegacyData];
}

- (void) setProgressStatus:(NSDictionary *)status {
    [self assertMainThread];
    if (status == nil) {
        /* Match the legacy page: stopping acquire clears byte metrics while
         * leaving its final percent visible. */
        [self.legacyDataStorage setCurrent:0];
        [self.legacyDataStorage setTotal:0];
        [self.legacyDataStorage setSpeed:0];
    } else {
        [self.legacyDataStorage setPercent:[[status objectForKey:@"Percent"] floatValue]];
        [self.legacyDataStorage setCurrent:[[status objectForKey:@"Current"] floatValue]];
        [self.legacyDataStorage setTotal:[[status objectForKey:@"Total"] floatValue]];
        [self.legacyDataStorage setSpeed:[[status objectForKey:@"Speed"] floatValue]];
    }
    [self changed:CydiaProgressViewModelChangeMetrics |
                  CydiaProgressViewModelChangeLegacyData];
}

- (void) setProgressCancellable:(NSNumber *)cancellable {
    [self setCancellable:[cancellable boolValue]];
}

- (void) setCancellable:(bool)cancellable {
    [self assertMainThread];
    BOOL changed(NO);
    @synchronized (self) {
        CydiaProgressCancellationState previous(cancellationState_);
        if (!cancellable)
            cancellationState_ = CydiaProgressCancellationUnavailable;
        else if (cancellationState_ == CydiaProgressCancellationUnavailable)
            cancellationState_ = CydiaProgressCancellationAvailable;
        changed = previous != cancellationState_;
    }
    if (changed)
        [self changed:CydiaProgressViewModelChangeCancellation];
}

- (void) requestCancellation {
    [self assertMainThread];
    BOOL changed(NO);
    @synchronized (self) {
        changed = cancellationState_ != CydiaProgressCancellationRequested;
        cancellationState_ = CydiaProgressCancellationRequested;
    }
    if (changed)
        [self changed:CydiaProgressViewModelChangeCancellation];
}

- (bool) isProgressCancelled {
    @synchronized (self) {
        return cancellationState_ == CydiaProgressCancellationRequested;
    }
}

@end
