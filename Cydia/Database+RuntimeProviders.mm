/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/DatabaseRuntimeInternal.h"
#include "Cydia/DatabaseStatus.h"
#include "Cydia/SettingsStore.h"
#include "Cydia/ProgressEvent.h"
#include "Cydia/PrivilegedClient.h"
#include "CyteKit/Localize.h"

namespace {
NSString *SettingsText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"];
}
NSError *Error(NSString *text) {
    return [NSError errorWithDomain:@"CydiaRuntimeProvider" code:1
        userInfo:@{NSLocalizedDescriptionKey: text ?: SettingsText(@"SETTINGS_SAVE_FAILED")}];
}
}

@implementation Database (RuntimeProviders)
- (CydiaRuntimeProviderStatus *)runtimeProviderStatus {
    @synchronized(runtimeStatusLock_) { return runtimeStatus_; }
}
- (void)checkRuntimeProviderWithCompletion:(CydiaRuntimeProviderCompletion)completion {
    [self changeRuntimePreference:nil security:nil completion:completion];
}
- (void)setRuntimeProviderPreference:(NSString *)preference completion:(CydiaRuntimeProviderCompletion)completion {
    if (![preference isEqual:@"automatic"] && ![preference isEqual:@"recovery"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion([self runtimeProviderStatus], Error(nil)); });
        return;
    }
    [self changeRuntimePreference:preference security:nil completion:completion];
}
- (void)setRepositorySecurityPreference:(NSString *)security completion:(CydiaRuntimeProviderCompletion)completion {
    if (![@[@"distribution", @"allow", @"warning", @"error"] containsObject:security]) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion([self runtimeProviderStatus], Error(nil)); });
        return;
    }
    [self changeRuntimePreference:nil security:security completion:completion];
}
- (void)changeRuntimePreference:(NSString *)preference security:(NSString *)security
    completion:(CydiaRuntimeProviderCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error(nil);
        BOOL reload(NO);
        if (![self beginSettingsChange]) error = Error(SettingsText(@"SETTINGS_WAIT_FOR_OPERATION"));
        else @try {
            @synchronized(self) {
                NSString *oldPreference(CydiaRuntimeProviderPreference());
                NSString *oldSecurity(CydiaExplicitRepositorySecurityPreference());
                NSString *nextPreference(preference ?: oldPreference);
                @synchronized(runtimeStatusLock_) {
                    runtimeStatus_ = [[CydiaRuntimeProviderStatus alloc] initWithPreference:oldPreference
                        state:CydiaRuntimeProviderStateChecking providerName:nil providerVersion:nil aptVersion:nil diagnostic:nil];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:CydiaRuntimeProviderStatusDidChangeNotification object:self];
                });
                bool adopted(false);
                const auto willAdopt = [&] {
                    // Existing Package instances become stale only after a
                    // successful selection, before their backend is destroyed.
                    adopted = true;
                    ++era_; packages_ = nil; sourceMap_.clear(); [sourceList_ removeAllObjects];
                    transactionSnapshot_ = nil; [self invalidateConfirmationReview];
                };
                NSString *diagnostic(nil);
                const bool selected(runtime_->Select(&apt_, *status_, nextPreference, security ?: oldSecurity,
                    security == nil || !runtime_->external(), &diagnostic, true, willAdopt));
                if (!selected) {
                    error = Error(diagnostic);
                    // A check of the unchanged preference must not repeat a
                    // failed cold-start preparation or turn it into recovery.
                    NSString *nextSecurity(security ?: oldSecurity);
                    const bool changed = ![nextPreference isEqual:oldPreference] ||
                        !(nextSecurity == oldSecurity || [nextSecurity isEqual:oldSecurity]);
                    if (!runtime_->ready() && changed)
                        runtime_->Select(&apt_, *status_, oldPreference, oldSecurity, true, nullptr, true, willAdopt);
                }
                else if ((preference && !CydiaSetRuntimeProviderPreference(preference)) ||
                         (security && !CydiaSetRepositorySecurityPreference(security))) {
                    error = Error(nil);
                    runtime_->Select(&apt_, *status_, oldPreference, oldSecurity, true, nullptr, true, willAdopt);
                }
                // A failed candidate leaves the existing queue/cache intact;
                // do not reset it through the ordinary reload path afterward.
                if (adopted) runtimeReloadPending_ = YES;
                reload = adopted;
                [self publishRuntimeProviderStatus];
            }
        } @finally { [self endSettingsChange]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Never hold the operation lock while waiting for UIKit. Its reload
            // yields to the existing background cache reconstruction path.
            if (reload && [delegate_ respondsToSelector:@selector(reloadDataWithInvocation:)])
                [(id)delegate_ reloadDataWithInvocation:nil];
            if (completion) completion([self runtimeProviderStatus], error);
        });
    });
}
@end

@implementation Database (RuntimeProviderInternal)
- (void)initializeRuntimeProvider {
    runtimeStatusLock_ = [[NSObject alloc] init];
    runtime_ = new CydiaAPT::RuntimeProviderCoordinator();
    // The application installs its loading view before its first background
    // reload. Do not hash components or wait for a worker on the launch thread.
    runtimeStatus_ = [[CydiaRuntimeProviderStatus alloc] initWithPreference:CydiaRuntimeProviderPreference()
        state:CydiaRuntimeProviderStateUnchecked providerName:nil providerVersion:nil aptVersion:nil diagnostic:nil];
    runtimeReloadPending_ = NO;
}
- (void)selectRuntimeProviderForReload {
    [self invalidateConfirmationReview];
    if (runtimeReloadPending_) runtimeReloadPending_ = NO;
    else runtime_->Select(&apt_, *status_, CydiaRuntimeProviderPreference(),
        CydiaExplicitRepositorySecurityPreference(), true, nullptr);
    // Initial selection now happens after the app creates its status pipes.
    // Restore the app-owned fd after maintainer configuration has been read.
    if (runtime_->ready() && !runtime_->remote()) CydiaAPT::AptBackend::KeepFileDescriptor(cydiafd_);
    [self publishRuntimeProviderStatus];
}
- (void)publishRuntimeProviderStatus {
    CydiaRuntimeProviderStatus *snapshot(runtime_->Status());
    if (!runtime_->healthy() && snapshot.state != CydiaRuntimeProviderStatePreparationFailed)
        snapshot = [[CydiaRuntimeProviderStatus alloc] initWithPreference:snapshot.preference
        state:CydiaRuntimeProviderStateBroken providerName:snapshot.providerName providerVersion:snapshot.providerVersion
        aptVersion:snapshot.aptVersion diagnostic:CydiaRuntimeProviderLocalize(@"BROKEN_HELP")];
    @synchronized(runtimeStatusLock_) { runtimeStatus_ = snapshot; }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:CydiaRuntimeProviderStatusDidChangeNotification object:self];
    });
}
- (void)invalidateConfirmationReview {
    @synchronized(runtimeStatusLock_) { confirmationReview_ = nil; confirmationApproved_ = NO; }
    if (runtime_) runtime_->InvalidateReview();
}
- (bool)captureConfirmationReview {
    CydiaAPT::TransactionData transaction; std::string error;
    if (!runtime_->CaptureReview(*apt_, &transaction, &error)) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:CydiaRuntimeProviderLocalize(@"REVIEW_UNAVAILABLE")
            ofType:@"Error"] forTask:UCLocalize("PREPARE_ARCHIVES")];
        return false;
    }
    const auto descriptor(CydiaAPT::ActiveRuntimeDescriptor());
    if (runtime_->remote() && !descriptor) return false;
    const auto origin(descriptor ? descriptor->origin : CydiaAPT::RuntimeDescriptorOrigin::Embedded);
    CydiaTransactionReview *review([[CydiaTransactionReview alloc] initWithTransaction:transaction providerReview:runtime_->review()
        runtimeOrigin:origin reviewedEffects:runtime_->reviewedEffects()]);
    @synchronized(runtimeStatusLock_) { confirmationReview_ = review; confirmationApproved_ = NO; }
    return review != nil;
}
- (NSNumber *)prepareForConfirmation { return @([self prepare]); }
- (CydiaTransactionReview *)preparedConfirmationReview {
    @synchronized(runtimeStatusLock_) { return confirmationReview_; }
}
- (BOOL)approveConfirmationReview:(CydiaTransactionReview *)review {
    if (![self beginSettingsChange]) return NO;
    BOOL accepted(NO);
    @try {
        @synchronized(runtimeStatusLock_) {
            const auto descriptor(CydiaAPT::ActiveRuntimeDescriptor());
            const auto origin(descriptor ? descriptor->origin : CydiaAPT::RuntimeDescriptorOrigin::Embedded);
            if (review != nil && review == confirmationReview_ && !confirmationApproved_ &&
                (!runtime_->remote() || descriptor) && review.runtimeOrigin == origin) {
                std::string error;
                accepted = runtime_->ApproveReview(*apt_, [review displayedActions], [review displayedArchiveWarnings], &error,
                    [review displayedEffectsIdentity]);
                confirmationApproved_ = accepted;
            }
        }
    } @finally { [self endSettingsChange]; }
    return accepted;
}
- (bool)confirmedTransactionUnchanged {
    @synchronized(runtimeStatusLock_) {
        const auto descriptor(CydiaAPT::ActiveRuntimeDescriptor());
        const auto origin(descriptor ? descriptor->origin : CydiaAPT::RuntimeDescriptorOrigin::Embedded);
        if (!confirmationApproved_ || confirmationReview_ == nil || !runtime_->ReviewUnchanged(*apt_) ||
            (runtime_->remote() && !descriptor) || [confirmationReview_ runtimeOrigin] != origin) return false;
        // A worker may not renew its review after approval. The
        // embedded engine has no worker binding, so compare its complete value.
        return runtime_->remote() || [confirmationReview_ matchesTransaction:apt_->transactionData()];
    }
}
@end
