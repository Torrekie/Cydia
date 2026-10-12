/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RuntimeProviderStatus_H
#define Cydia_RuntimeProviderStatus_H
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CydiaRuntimeProviderState) {
    CydiaRuntimeProviderStateUnchecked,
    CydiaRuntimeProviderStateChecking,
    CydiaRuntimeProviderStateExternalActive,
    CydiaRuntimeProviderStateRecoveryActive,
    CydiaRuntimeProviderStateMissing,
    CydiaRuntimeProviderStateUnsupported,
    CydiaRuntimeProviderStateBroken,
};

/* An immutable, cached presentation snapshot. Provider/version fields describe
 * the selected runtime, never an unvalidated candidate. A missing, unsupported
 * or broken candidate is separately represented by state and diagnostic. */
@interface CydiaRuntimeProviderStatus : NSObject
@property(nonatomic, copy, readonly) NSString *preference;
@property(nonatomic, readonly) CydiaRuntimeProviderState state;
@property(nonatomic, copy, readonly) NSString *providerName;
@property(nonatomic, copy, readonly) NSString *providerVersion;
@property(nonatomic, copy, readonly) NSString *aptVersion;
@property(nonatomic, copy, readonly) NSString *diagnostic;
- (instancetype)initWithPreference:(NSString *)preference
    state:(CydiaRuntimeProviderState)state
    providerName:(nullable NSString *)providerName
    providerVersion:(nullable NSString *)providerVersion
    aptVersion:(nullable NSString *)aptVersion
    diagnostic:(nullable NSString *)diagnostic NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef void (^CydiaRuntimeProviderCompletion)(CydiaRuntimeProviderStatus *status, NSError * _Nullable error);
NSString *CydiaRuntimeProviderLocalize(NSString *key);
/* Posted on the main queue with the publishing Database as its object. */
FOUNDATION_EXPORT NSString *const CydiaRuntimeProviderStatusDidChangeNotification;

NS_ASSUME_NONNULL_END
#endif
