/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RepositoryArchiveAuthorization.hpp"
#import "Cydia/RepositoryAccountService.h"
#import "CyteKit/Localize.h"
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
namespace CydiaRuntime {
namespace {
using Status = RepositoryArchiveAuthorizationStatus;
struct AuthorizationState {
    std::mutex mutex;
    std::condition_variable wake;
    bool active = true, done = false;
    RepositoryArchiveAuthorizationResult result;
};
bool Active(const std::shared_ptr<AuthorizationState> &state) {
    std::lock_guard<std::mutex> lock(state->mutex); return state->active && !state->done;
}
void Finish(const std::shared_ptr<AuthorizationState> &state, Status status, NSString *message, NSURL *URL = nil) {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->active || state->done) return;
    state->result.status = status;
    state->result.message = message.UTF8String ?: "";
    if (status == Status::Authorized) state->result.transportURL = URL.absoluteString.UTF8String ?: "";
    state->done = true; state->wake.notify_all();
}
void Fail(const std::shared_ptr<AuthorizationState> &state, NSError *error) {
    Status status = Status::Failed;
    if ([error.domain isEqualToString:@"CydiaRepositoryAccount"]) {
        if (error.code == CydiaAccountErrorUnsupported) status = Status::Unsupported;
        else if (error.code == CydiaAccountErrorAuthentication) status = Status::AuthenticationRequired;
        else if (error.code == CydiaAccountErrorUnavailable) status = Status::Unavailable;
    }
    Finish(state, status, error.localizedDescription ?: CydiaAccountLocalize(@"ACCOUNT_REQUEST_FAILED"));
}
bool Boolean(id value) { return [value isKindOfClass:NSNumber.class] && [value boolValue]; }
bool ExplicitlyFree(NSDictionary *info) {
    /* Do not infer a zero price from arbitrary/localized display strings. */
    id price = info[@"price"];
    return Boolean(info[@"free"]) || ([price isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)price) != CFBooleanGetTypeID() && [price doubleValue] == 0.0);
}
void OwnedPackage(const std::shared_ptr<AuthorizationState> &state,
                  CydiaRepositoryAccount *account, NSString *package, NSString *version, NSString *architecture) {
    if (!Active(state)) return;
    if (!account.supportsAccountIntegration) {
        // No accepted account integration means ordinary APT may still retrieve
        // a public archive. The publisher's HTTP authorization remains decisive.
        Finish(state, Status::NotRequired, nil); return;
    }
    if (!account.signedIn) {
        Finish(state, Status::AuthenticationRequired, CydiaAccountLocalize(@"ACCOUNT_SIGN_IN_REQUIRED")); return;
    }
    [[CydiaRepositoryAccountService sharedService] packageInfo:package account:account
        completion:^(NSDictionary *info, NSError *error) {
        if (!Active(state)) return;
        if (error) { Fail(state, error); return; }
        if (!Boolean(info[@"available"])) {
            Finish(state, Status::Unavailable, CydiaAccountLocalize(@"ACCOUNT_UNAVAILABLE")); return;
        }
        if (ExplicitlyFree(info)) { Finish(state, Status::NotRequired, nil); return; }
        if (!Boolean(info[@"purchased"])) {
            Finish(state, Status::Unavailable, CydiaAccountLocalize(@"ACCOUNT_NOT_OWNED")); return;
        }
        [[CydiaRepositoryAccountService sharedService] authorizePackage:package version:version architecture:architecture
            account:account completion:^(CydiaRepositoryDownloadGrant *grant, NSError *failure) {
            if (!Active(state)) return;
            if (failure) { Fail(state, failure); return; }
            if (![grant.package isEqual:package] || ![grant.version isEqual:version] ||
                ![grant.architecture isEqual:architecture] || ![grant.sourceURL isEqual:account.sourceURL] ||
                !grant.transportURL || !grant.obtainedAt || -[grant.obtainedAt timeIntervalSinceNow] > 60) {
                Finish(state, Status::Failed, CydiaAccountLocalize(@"ACCOUNT_REQUEST_FAILED")); return;
            }
            Finish(state, Status::Authorized, nil, grant.transportURL);
        }];
    }];
}
}
static RepositoryArchiveAuthorizationResult AuthorizeRepositoryArchiveWithAccounts(
    const RepositoryArchiveAuthorizationRequest &request, const std::function<bool()> &cancelled) {
    RepositoryArchiveAuthorizationResult failed;
    failed.message = CydiaAccountLocalize(@"ACCOUNT_REQUEST_FAILED").UTF8String;
    if ([NSThread isMainThread] || request.sourceURL.empty() || request.package.empty() ||
        request.version.empty() || request.architecture.empty()) return failed;
    if (cancelled && cancelled()) { failed.status = Status::Cancelled; failed.message = ""; return failed; }
    auto state = std::make_shared<AuthorizationState>();
    NSString *sourceText = [NSString stringWithUTF8String:request.sourceURL.c_str()];
    NSString *package = [NSString stringWithUTF8String:request.package.c_str()];
    NSString *version = [NSString stringWithUTF8String:request.version.c_str()];
    NSString *architecture = [NSString stringWithUTF8String:request.architecture.c_str()];
    NSURL *source = sourceText ? [NSURL URLWithString:sourceText] : nil;
    if (!source || !package || !version || !architecture) return failed;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!Active(state)) return;
        [[CydiaRepositoryAccountService sharedService] discoverSource:source name:source.host ?: sourceText
            completion:^(CydiaRepositoryAccount *account, NSError *error) {
            if (!Active(state)) return;
            if (error) {
                if ([error.domain isEqualToString:@"CydiaRepositoryAccount"] &&
                    error.code == CydiaAccountErrorUnsupported)
                    Finish(state, Status::NotRequired, nil);
                else Fail(state, error);
                return;
            }
            if (!account.supportsAccountIntegration) {
                // Preserve public/legacy archive retrieval. This does not
                // authenticate the user or claim paid vendor compatibility.
                Finish(state, Status::NotRequired, nil); return;
            }
            /* Anonymous package information carries neither an account token
             * nor a permanent device identifier. Some providers require login
             * even for this API; only an already approved account may proceed. */
            [[CydiaRepositoryAccountService sharedService] anonymousPackageInfo:package account:account
                completion:^(NSDictionary *info, NSError *failure) {
                if (!Active(state)) return;
                if (!failure && Boolean(info[@"available"]) && ExplicitlyFree(info)) {
                    Finish(state, Status::NotRequired, nil); return;
                }
                if (!failure && [info[@"available"] isKindOfClass:NSNumber.class] && !Boolean(info[@"available"])) {
                    Finish(state, Status::Unavailable, CydiaAccountLocalize(@"ACCOUNT_UNAVAILABLE")); return;
                }
                if (failure && failure.code != CydiaAccountErrorAuthentication && !account.signedIn) {
                    Fail(state, failure); return;
                }
                OwnedPackage(state, account, package, version, architecture);
            }];
        }];
    });
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
    std::unique_lock<std::mutex> lock(state->mutex);
    while (!state->done) {
        lock.unlock(); const bool stop = cancelled && cancelled(); lock.lock();
        if (stop || std::chrono::steady_clock::now() >= deadline) {
            state->active = false;
            failed.status = stop ? Status::Cancelled : Status::Failed;
            if (stop) failed.message = "";
            return failed;
        }
        state->wake.wait_for(lock, std::chrono::milliseconds(100));
    }
    state->active = false;
    return state->result;
}
void ConfigureRepositoryArchiveAuthorization() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SetRepositoryArchiveAuthorizationHandler(AuthorizeRepositoryArchiveWithAccounts);
    });
}
}
