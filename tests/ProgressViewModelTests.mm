/* Cydia Refurbished native progress model tests.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/ProgressViewModel.h"
#include "Cydia/PackageArchitecturePresentation.h"
#include "Cydia/FetchDiagnostics.h"

#include <cmath>
#include <cstdlib>
#include <iostream>

void Fail(NSString *message) {
    std::cerr << "[verify-progress-view-model][FAIL] "
              << [message UTF8String] << std::endl;
    std::exit(1);
}

void Expect(BOOL condition, NSString *message) {
    if (!condition)
        Fail(message);
}

void ExpectEqual(id actual, id expected, NSString *message) {
    if (actual == expected || [actual isEqual:expected])
        return;
    Fail([NSString stringWithFormat:@"%@ (actual=%@ expected=%@)",
                                     message, actual, expected]);
}

@interface FixtureProgressEvent : NSObject
@property(nonatomic, copy) NSString *messageValue;
@property(nonatomic, copy) NSString *typeValue;
@property(nonatomic, copy) NSArray<NSString *> *itemValue;
@property(nonatomic, copy) NSString *packageValue;
@property(nonatomic, copy) NSString *URLValue;
@property(nonatomic, copy) NSString *versionValue;
@end

@implementation FixtureProgressEvent
- (NSString *) message { return self.messageValue; }
- (NSString *) type { return self.typeValue; }
- (NSArray *) item { return self.itemValue ?: (id) [NSNull null]; }
- (NSString *) package { return self.packageValue ?: (id) [NSNull null]; }
- (NSString *) url { return self.URLValue ?: (id) [NSNull null]; }
- (NSString *) version { return self.versionValue ?: (id) [NSNull null]; }
@end

@interface ProgressObserver : NSObject <CydiaProgressViewModelObserver>
@property(nonatomic, strong) NSMutableArray<CydiaProgressViewState *> *states;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *changes;
@end

@implementation ProgressObserver
- (instancetype) init {
    if ((self = [super init]) != nil) {
        self.states = [NSMutableArray array];
        self.changes = [NSMutableArray array];
    }
    return self;
}
- (void) progressViewModel:(CydiaProgressViewModel *)model
           didPublishState:(CydiaProgressViewState *)state
                    change:(CydiaProgressViewModelChange)change {
    (void) model;
    [self.states addObject:state];
    [self.changes addObject:@(change)];
}
@end

CydiaProgressLocalizer FixtureLocalizer(void) {
    return ^NSString *(NSString *key) {
        if ([key isEqualToString:@"COLON_DELIMITED"])
            return @"%@: %@";
        return [NSString stringWithFormat:@"L(%@)", key];
    };
}

CydiaProgressViewModel *NewModel(CydiaProgressPackageNameResolver resolver) {
    return [[CydiaProgressViewModel alloc]
        initWithLegacyData:[[CydiaProgressData alloc] init]
        packageNameResolver:resolver
        localizer:FixtureLocalizer()];
}

FixtureProgressEvent *Event(NSString *type, NSString *message) {
    FixtureProgressEvent *event([[FixtureProgressEvent alloc] init]);
    event.typeValue = type;
    event.messageValue = message;
    return event;
}

void TestStateAndLegacyOrdering(void) {
    NSMutableArray<NSString *> *resolved([NSMutableArray array]);
    CydiaProgressViewModel *model(NewModel(^NSString *(NSString *identifier) {
        [resolved addObject:identifier];
        if ([identifier isEqualToString:@"runtime:iphoneos-arm64"])
            return @"Friendly Runtime";
        if ([identifier isEqualToString:@"com.torrekie.cydia-ui-transaction-fixture"])
            return @"Cydia UI Transaction Fixture";
        return nil;
    }));
    ProgressObserver *observer([[ProgressObserver alloc] init]);
    model.observer = observer;

    CydiaProgressViewState *initial(model.state);
    Expect(initial.revision == 0, @"initial revision is zero");
    Expect(!initial.running, @"initial state is not running");
    Expect(initial.finishAction == CydiaProgressFinishActionNone,
           @"initial finish action is absent");
    Expect([initial.events count] == 0, @"initial event log is empty");

    [model beginWithTitle:@"RUNNING"];
    Expect(model.state.running, @"begin marks progress running");
    ExpectEqual(model.state.rawTitle, @"RUNNING", @"raw title key is preserved");
    ExpectEqual(model.state.localizedTitle, @"L(RUNNING)", @"title is localized for UIKit");
    Expect([[[model legacyData] running] boolValue], @"legacy running bridge matches state");
    ExpectEqual([[model legacyData] title], @"RUNNING", @"legacy title remains raw");

    [model setProgressStatus:@{
        @"Percent": @0.25f,
        @"Current": @1024.0f,
        @"Total": @4096.0f,
        @"Speed": @512.0f,
    }];
    Expect(model.state.rawPercent == 0.25f && model.state.displayPercent == 0.25f,
           @"acquire percent is unchanged");
    Expect(model.state.current == 1024.0f && model.state.total == 4096.0f &&
           model.state.speed == 512.0f, @"acquire metrics are published together");

    FixtureProgressEvent *status(Event(@"Status", @"Installing runtime:iphoneos-arm64"));
    status.packageValue = @"runtime:iphoneos-arm64";
    status.itemValue = @[@"Get", @"1", @"runtime:iphoneos-arm64", @"1.0"];
    status.URLValue = @"https://repo.example/runtime.deb";
    status.versionValue = @"1.0";
    [model addProgressEvent:(CydiaProgressEvent *) status];

    CydiaProgressPresentationEvent *presented([model.state.events lastObject]);
    Expect(presented.kind == CydiaProgressEventKindStatus, @"Status maps to typed kind");
    ExpectEqual(presented.displayMessage, @"Installing Friendly Runtime",
                @"Status substitutes package display names");
    ExpectEqual(model.state.statusText, @"Installing Friendly Runtime",
                @"latest Status becomes current status text");
    ExpectEqual(presented.packageIdentifier, @"runtime:iphoneos-arm64",
                @"qualified package identity is not rewritten");
    ExpectEqual(presented.URLString, @"https://repo.example/runtime.deb",
                @"acquire URL is retained in typed presentation data");
    Expect([[[model legacyData] events] count] == 1 &&
           [[[model legacyData] events] objectAtIndex:0] == status,
           @"legacy event is appended before publication");
    Expect([resolved containsObject:@"runtime:iphoneos-arm64"],
           @"resolver receives architecture-qualified token");

    FixtureProgressEvent *output(Event(@"Information", @"phase one\rphase two\r"));
    [model addProgressEvent:(CydiaProgressEvent *) output];
    presented = [model.state.events lastObject];
    ExpectEqual(presented.displayMessage, @"phase two",
                @"terminal CR overwrite matches legacy JavaScript ordering");
    ExpectEqual(model.state.statusText, @"Installing Friendly Runtime",
                @"Information output does not replace current Status");

    FixtureProgressEvent *statusOutput(Event(@"Status", @"old status\rnew status\r"));
    [model addProgressEvent:(CydiaProgressEvent *) statusOutput];
    presented = [model.state.events lastObject];
    ExpectEqual(presented.displayMessage, @"new status",
                @"Status CR overwrite keeps the final visible line");
    ExpectEqual(model.state.statusText, @"old status\rnew status\r",
                @"legacy status text remains raw while only the log row applies CR overwrite");

    FixtureProgressEvent *warning(Event(@"Warning", @"configuration changed"));
    [model addProgressEvent:(CydiaProgressEvent *) warning];
    presented = [model.state.events lastObject];
    Expect(presented.kind == CydiaProgressEventKindWarning, @"Warning maps to typed kind");
    ExpectEqual(presented.displayMessage, @"configuration changed",
                @"visual warning text is not prefixed");
    ExpectEqual(presented.accessibilityLabel, @"L(WARNING): configuration changed",
                @"warning accessibility does not rely on color");

    FixtureProgressEvent *error(Event(@"Error", @"dpkg failed"));
    [model addProgressEvent:(CydiaProgressEvent *) error];
    Expect(model.state.containsError, @"error presence is derived without changing completion");
    ExpectEqual([[model.state.events lastObject] accessibilityLabel],
                @"L(ERROR): dpkg failed", @"error accessibility is explicit");

    FixtureProgressEvent *unknown(Event(@"FutureKind", @"future message"));
    [model addProgressEvent:(CydiaProgressEvent *) unknown];
    Expect([[model.state.events lastObject] kind] == CydiaProgressEventKindUnknown,
           @"unknown event types remain visible");
    ExpectEqual([[model.state.events lastObject] accessibilityLabel],
                @"FutureKind: future message",
                @"unknown event types remain explicit to VoiceOver");

    FixtureProgressEvent *fixtureStatus(Event(
        @"Status",
        @"Removing com.torrekie.cydia-ui-transaction-fixture (iphoneos-arm64)"));
    fixtureStatus.packageValue = @"com.torrekie.cydia-ui-transaction-fixture";
    [model addProgressEvent:(CydiaProgressEvent *) fixtureStatus];
    presented = [model.state.events lastObject];
    ExpectEqual(presented.displayMessage,
                @"Removing Cydia UI Transaction Fixture (iphoneos-arm64)",
                @"transaction fixture display name remains intact after resolver substitution");
    Expect([presented.displayMessage rangeOfString:@"Transaction"].location != NSNotFound,
           @"transaction fixture name is not truncated at the first status word");

    Expect([initial.events count] == 0 && initial.revision == 0,
           @"published state remains immutable after later events");
    Expect([observer.states count] == 9, @"one state is published per ordered mutation");
    NSUInteger priorRevision(0);
    for (CydiaProgressViewState *state in observer.states) {
        Expect(state.revision > priorRevision, @"observer revisions increase monotonically");
        priorRevision = state.revision;
    }
    for (NSNumber *change in observer.changes) {
        CydiaProgressViewModelChange value((CydiaProgressViewModelChange) [change unsignedIntegerValue]);
        Expect((value & CydiaProgressViewModelChangeLegacyData) != 0,
               @"data mutations retain the legacy dispatch marker");
    }
}

void TestSafePercentAndStop(void) {
    CydiaProgressViewModel *model(NewModel(nil));
    [model setProgressPercent:@(NAN)];
    Expect(std::isnan(model.state.rawPercent), @"raw non-finite percent is retained for parity");
    Expect(!model.state.progressDeterminate && model.state.displayPercent == 0,
           @"UIKit percent is safe for non-finite input");

    [model setProgressPercent:@1.5f];
    Expect(model.state.rawPercent == 1.5f && model.state.displayPercent == 1.0f,
           @"UIKit percent clamps without changing legacy data");
    [model setProgressStatus:@{
        @"Percent": @0.75f, @"Current": @3, @"Total": @4, @"Speed": @2,
    }];
    [model setProgressStatus:nil];
    Expect(model.state.rawPercent == 0.75f,
           @"acquire Stop deliberately retains the final percent");
    Expect(model.state.current == 0 && model.state.total == 0 && model.state.speed == 0,
           @"acquire Stop clears byte metrics");
}

void TestTerminalMessageControlCharacters(void) {
    CydiaProgressViewModel *model(NewModel(^NSString *(NSString *identifier) {
        return [identifier isEqualToString:@"com.torrekie.cydia-ui-transaction-fixture"] ?
            @"Cydia UI Transaction Fixture" : nil;
    }));

    unichar nul(0);
    NSString *nulString([[NSString alloc] initWithCharacters:&nul length:1]);
    NSString *message([NSString stringWithFormat:
        @"Removing com.torrekie.cydia-ui-trans%@action-fixture (iphoneos-arm64)",
        nulString]);
    FixtureProgressEvent *event(Event(@"Status", message));
    event.packageValue = @"com.torrekie.cydia-ui-transaction-fixture";
    [model addProgressEvent:(CydiaProgressEvent *) event];

    CydiaProgressPresentationEvent *presented([model.state.events lastObject]);
    ExpectEqual(presented.displayMessage,
                @"Removing Cydia UI Transaction Fixture (iphoneos-arm64)",
                @"embedded NUL is removed without truncating terminal output");
    ExpectEqual(presented.accessibilityLabel, presented.displayMessage,
                @"terminal accessibility text retains the complete fixture name");
    for (NSUInteger index(0); index != [presented.displayMessage length]; ++index)
        Expect([presented.displayMessage characterAtIndex:index] != 0,
               @"visible terminal text contains no embedded NUL");
}

void TestCancellationStateMachine(void) {
    CydiaProgressViewModel *model(NewModel(nil));
    ProgressObserver *observer([[ProgressObserver alloc] init]);
    model.observer = observer;

    [model setCancellable:true];
    Expect(model.state.cancellationState == CydiaProgressCancellationAvailable,
           @"acquire Start exposes Cancel");
    [model requestCancellation];
    Expect(model.state.cancellationState == CydiaProgressCancellationRequested &&
           [model isProgressCancelled], @"Cancel request is visible to acquire Pulse");
    NSUInteger revision(model.state.revision);
    [model setCancellable:true];
    Expect(model.state.cancellationState == CydiaProgressCancellationRequested &&
           model.state.revision == revision,
           @"repeated cancellable callback cannot clear a pending request");
    [model setCancellable:false];
    Expect(model.state.cancellationState == CydiaProgressCancellationUnavailable &&
           ![model isProgressCancelled], @"acquire Stop clears cancellation state");

    for (NSNumber *change in observer.changes) {
        CydiaProgressViewModelChange value((CydiaProgressViewModelChange) [change unsignedIntegerValue]);
        Expect(value == CydiaProgressViewModelChangeCancellation,
               @"cancellation does not dispatch legacy progress data or finish work");
    }
}

void TestHistoricalTerminalPercent(void) {
    for (NSString *scenario in @[@"ordinary", @"error", @"cancelled", @"unknown"]) {
        CydiaProgressViewModel *model(NewModel(nil));
        Expect(!model.state.percentIsHistorical, @"unused model has no historical metric");
        [model beginWithTitle:@"RUNNING"];
        float raw([scenario isEqualToString:@"unknown"] ? NAN : 0.8f);
        [model setProgressPercent:@(raw)];
        if ([scenario isEqualToString:@"error"])
            [model addProgressEvent:(CydiaProgressEvent *)Event(@"Error", @"dpkg failed")];
        if ([scenario isEqualToString:@"cancelled"]) {
            [model setCancellable:true];
            [model requestCancellation];
            [model setCancellable:false];
        }
        CydiaProgressViewState *running(model.state);
        [model completeWithFinishAction:CydiaProgressFinishActionReturnToCydia];
        Expect(model.state.percentIsHistorical && !running.percentIsHistorical,
               @"terminal metric is historical without mutating the running snapshot");
        if (std::isfinite(raw)) {
            Expect(model.state.rawPercent == raw && model.state.displayPercent == raw,
                   @"finish must not manufacture successful 100 percent");
            Expect([[[model legacyData] percent] floatValue] == raw,
                   @"raw legacy percent is not rewritten by presentation");
        } else {
            Expect(!model.state.progressDeterminate && std::isnan(model.state.rawPercent),
                   @"unknown terminal progress remains unknown");
        }
        Expect(model.state.containsError == [scenario isEqualToString:@"error"],
               @"terminal presentation preserves error evidence");
        [model progressFinishActionDidChange:@(CydiaProgressFinishActionReloadSpringBoard)];
        Expect(model.state.percentIsHistorical, @"late finish escalation retains historical metric");
        [model setProgressPercent:@0.9f];
        Expect(model.state.percentIsHistorical && model.state.displayPercent == 0.9f,
               @"late backend update does not become live or fake complete progress");
    }
}

void TestFinishActions(void) {
    NSArray<NSString *> *keys = @[
        @"RETURN_TO_CYDIA", @"CLOSE_CYDIA", @"RESTART_SPRINGBOARD",
        @"RELOAD_SPRINGBOARD", @"REBOOT_DEVICE",
    ];
    for (NSInteger raw(0); raw != 5; ++raw) {
        CydiaProgressViewModel *model(NewModel(nil));
        [model beginWithTitle:@"RUNNING"];
        CydiaProgressViewState *running(model.state);
        CydiaProgressFinishAction action((CydiaProgressFinishAction) raw);
        [model completeWithFinishAction:action];

        Expect(!model.state.running, @"completion stops running state");
        Expect(model.state.finishAction == action, @"typed finish action retains legacy value");
        NSString *expected([NSString stringWithFormat:@"L(%@)", [keys objectAtIndex:raw]]);
        ExpectEqual(model.state.finishTitle, expected, @"finish title mapping is unchanged");
        ExpectEqual([[model legacyData] finish], expected,
                    @"legacy finish button sees the same localized text");
        Expect(running.running && running.finishAction == CydiaProgressFinishActionNone,
               @"pre-completion published state remains immutable");
    }
    Expect(CydiaProgressFinishLocalizationKey(CydiaProgressFinishActionNone) == nil,
           @"unfinished state has no action title");

    Expect(CydiaProgressEffectiveFinishAction(
               CydiaProgressFinishActionReturnToCydia,
               CydiaProgressFinishActionReloadSpringBoard) ==
               CydiaProgressFinishActionReloadSpringBoard,
           @"late dpkg finish output escalates the completion snapshot");
    Expect(CydiaProgressEffectiveFinishAction(
               CydiaProgressFinishActionRestartSpringBoard,
               CydiaProgressFinishActionReturnToCydia) ==
               CydiaProgressFinishActionRestartSpringBoard,
           @"a stale live value cannot weaken a stronger snapshot");
    Expect(CydiaProgressEffectiveFinishAction(
               CydiaProgressFinishActionNone,
               CydiaProgressFinishActionReturnToCydia) ==
               CydiaProgressFinishActionReturnToCydia,
           @"a pre-completion close retains the legacy live fallback");
    Expect(CydiaProgressEffectiveFinishAction(
               CydiaProgressFinishActionTerminate, 99) ==
               CydiaProgressFinishActionTerminate,
           @"an invalid live value cannot select an undefined side effect");

    CydiaProgressViewModel *late(NewModel(nil));
    [late beginWithTitle:@"RUNNING"];
    [late completeWithFinishAction:CydiaProgressFinishActionReturnToCydia];
    [late progressFinishActionDidChange:@(CydiaProgressFinishActionRebootDevice)];
    Expect(late.state.finishAction == CydiaProgressFinishActionRebootDevice,
           @"late finish output republishes the stronger native action");
    ExpectEqual(late.state.finishTitle, @"L(REBOOT_DEVICE)",
                @"late finish output updates the visible action title");

    const CydiaProgressFinishSideEffect effects[] = {
        CydiaProgressFinishSideEffectReturnToCydia,
        CydiaProgressFinishSideEffectTerminate,
        CydiaProgressFinishSideEffectReloadSpringBoard,
        CydiaProgressFinishSideEffectReloadSpringBoard,
        CydiaProgressFinishSideEffectRebootDevice,
    };
    const BOOL saves[] = {NO, NO, YES, YES, YES};
    const BOOL dismisses[] = {YES, YES, NO, NO, YES};
    for (NSInteger raw(0); raw != 5; ++raw) {
        CydiaProgressFinishPlan plan(CydiaProgressFinishPlanForAction(
            static_cast<CydiaProgressFinishAction>(raw)));
        Expect(plan.sideEffect == effects[raw] &&
               plan.savesState == saves[raw] &&
               plan.dismissesController == dismisses[raw],
               @"controller finish side-effect plan changed");
    }
}

void TestArchitectureDisplayNames(void) {
    NSArray *registered(@[@"iphoneos-arm64", @"iphoneos-arm"]);
    CydiaProgressViewModel *model(NewModel(^NSString *(NSString *identity) {
        NSString *architecture([identity isEqualToString:@"runtime:iphoneos-arm"] ?
            @"iphoneos-arm" : @"iphoneos-arm64");
        return CydiaPackageNameWithArchitectureCaption(@"Runtime",
            CydiaPackageArchitectureCaption(architecture, registered));
    }));
    FixtureProgressEvent *native(Event(@"Status", @"runtime:iphoneos-arm64"));
    native.packageValue = @"runtime:iphoneos-arm64";
    [model addProgressEvent:(CydiaProgressEvent *)native];
    FixtureProgressEvent *foreign(Event(@"Status", @"runtime:iphoneos-arm"));
    foreign.packageValue = @"runtime:iphoneos-arm";
    [model addProgressEvent:(CydiaProgressEvent *)foreign];
    ExpectEqual(model.state.events[0].displayMessage, @"Runtime (Native · iphoneos-arm64)",
        @"native status lost architecture distinction");
    ExpectEqual(model.state.events[1].displayMessage, @"Runtime (Additional · iphoneos-arm)",
        @"foreign status lost architecture distinction");
    ExpectEqual(model.state.events[1].accessibilityLabel, model.state.events[1].displayMessage,
        @"VoiceOver lost the visible architecture distinction");
    ExpectEqual(model.state.events[1].packageIdentifier, @"runtime:iphoneos-arm",
        @"presentation changed the underlying progress identifier");
}

void TestAPTDiagnosticPresentation(void) {
    NSString *resources([[[NSFileManager defaultManager] currentDirectoryPath]
        stringByAppendingPathComponent:@"MobileCydia.app/zh-Hans.lproj"]);
    NSBundle *bundle([NSBundle bundleWithPath:resources]);
    Expect(bundle != nil, @"diagnostic fixture loads the shipped Chinese locale");

    NSString *path(@"/var/lib/apt/lists/partial/example.invalid_Release with spaces");
    ExpectEqual(CydiaAPTDiagnosticMessage([@"Invalid 'Date' entry in Release file " stringByAppendingString:path], bundle),
        [@"Release 文件的“Date”字段无效：" stringByAppendingString:path],
        @"Release warning translates without changing its field or filename");
    NSString *URI(@"https://example.invalid/./InRelease?test=100%25");
    NSString *timeout(@"Could not connect to example.invalid:443 (192.0.2.1), connection timed out");
    NSString *other(@"Could not connect to example.invalid:443 (2001:db8::1), connection timed out");
    NSString *fetch([NSString stringWithFormat:@"Failed to fetch %@  %@ %@", URI, timeout, other]);
    NSString *localized(CydiaAPTDiagnosticMessage(fetch, bundle));
    ExpectEqual(localized, [NSString stringWithFormat:@"无法获取 %@\n无法连接到 example.invalid:443（192.0.2.1），连接超时\n无法连接到 example.invalid:443（2001:db8::1），连接超时", URI],
        @"every repeated timeout translates and preserves the URI and attempted addresses");
    ExpectEqual(CydiaAPTDiagnosticMessage([NSString stringWithFormat:@"%@\n%@\n", timeout, other], bundle),
        @"无法连接到 example.invalid:443（192.0.2.1），连接超时\n无法连接到 example.invalid:443（2001:db8::1），连接超时",
        @"acquire methods may join attempts with newlines");
    ExpectEqual(CydiaAPTDiagnosticMessage(@"Connection timed out", bundle), @"连接超时",
        @"standalone method timeouts translate");
    ExpectEqual(CydiaAPTDiagnosticMessage(@"Some index files failed to download. They have been ignored, or old ones used instead.", bundle),
        @"部分索引文件下载失败。已忽略这些文件，或改用旧文件。",
        @"partial refresh summary retains its old-index fallback meaning");

    NSString *unknown(@"TLS peer verification failed: error 123 [IP: 192.0.2.2 443]");
    ExpectEqual(CydiaAPTDiagnosticMessage(unknown, bundle), unknown,
        @"unrecognized method output remains verbatim");
    ExpectEqual(CydiaAPTDiagnosticMessage([NSString stringWithFormat:@"Failed to fetch %@  %@", URI, unknown], bundle),
        [NSString stringWithFormat:@"无法获取 %@\n%@", URI, unknown],
        @"known wrapper preserves unknown technical details");
    NSString *mixed([timeout stringByAppendingFormat:@" %@", unknown]);
    ExpectEqual(CydiaAPTDiagnosticMessage(mixed, bundle), mixed,
        @"partially recognized reason never loses an unexpected trailing failure");
    NSString *embedded([@"Proxy replied: " stringByAppendingString:timeout]);
    ExpectEqual(CydiaAPTDiagnosticMessage(embedded, bundle), embedded,
        @"matching text inside an unrelated diagnostic is not rewritten");
    NSString *malformed(@"Failed to fetch https://example.invalid/Release");
    ExpectEqual(CydiaAPTDiagnosticMessage(malformed, bundle), malformed,
        @"changed APT templates retain their original message");
    NSString *local(@"Failed to fetch file:/srv/repo  old/Release  File not found");
    ExpectEqual(CydiaAPTDiagnosticMessage(local, bundle), local,
        @"unquoted local paths containing the separator remain verbatim");
    ExpectEqual(CydiaAPTDiagnosticMessage(@"", bundle), @"", @"empty diagnostic remains empty");

    CydiaProgressViewModel *model(NewModel(nil));
    [model addProgressEvent:(CydiaProgressEvent *)Event(@"Warning", localized)];
    ExpectEqual(model.state.events[0].displayMessage, localized, @"progress retains localized fetch details");
    Expect(model.state.events[0].kind == CydiaProgressEventKindWarning,
        @"presentation does not promote a warning to an error");
}

int main() {
    @autoreleasepool {
        TestStateAndLegacyOrdering();
        TestSafePercentAndStop();
        TestTerminalMessageControlCharacters();
        TestCancellationStateMachine();
        TestHistoricalTerminalPercent();
        TestFinishActions();
        TestArchitectureDisplayNames();
        TestAPTDiagnosticPresentation();
        std::cout << "[verify-progress-view-model][ ok ] immutable legacy/native progress state"
                  << std::endl;
    }
    return 0;
}
