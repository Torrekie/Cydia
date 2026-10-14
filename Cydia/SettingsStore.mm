/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SettingsStore.h"
#include "Cydia/RepositorySecurityPolicy.hpp"
#include "Cydia/RepositoryIdentity.hpp"

namespace {
#if defined(CYDIA_REPOSITORY_ACCOUNT_TESTING)
NSMutableDictionary *CydiaRepositoryIdentityTestSettings;
#endif
NSObject *SettingsLock() {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSObject alloc] init]; });
    return lock;
}

NSMutableDictionary *ReadSettings() {
#if defined(CYDIA_REPOSITORY_ACCOUNT_TESTING)
    // Foundation fixtures never read or change the user's real preferences.
    return CydiaRepositoryIdentityTestSettings ? [CydiaRepositoryIdentityTestSettings mutableCopy] : [NSMutableDictionary dictionary];
#else
    id value(CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("CydiaSettings"), CFSTR("com.saurik.Cydia"))));
    return [value isKindOfClass:[NSDictionary class]] ? [value mutableCopy] :
        [NSMutableDictionary dictionary];
#endif
}

bool IsSecurityPreference(id value) {
    if (![value isKindOfClass:[NSString class]]) return false;
    const char *bytes([value UTF8String]);
    return bytes != nullptr && CydiaAPT::IsRepositorySecurityModeName(
        std::string(bytes, [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]));
}

BOOL WriteSettings(NSDictionary *settings) {
#if defined(CYDIA_REPOSITORY_ACCOUNT_TESTING)
    CydiaRepositoryIdentityTestSettings = [settings mutableCopy];
    return YES;
#else
    id previous(CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("CydiaSettings"), CFSTR("com.saurik.Cydia"))));
    CFPreferencesSetAppValue(CFSTR("CydiaSettings"), (__bridge CFPropertyListRef)settings,
        CFSTR("com.saurik.Cydia"));
    if (CFPreferencesAppSynchronize(CFSTR("com.saurik.Cydia"))) return YES;
    // Keep the in-process preference aligned with the reported failure.
    CFPreferencesSetAppValue(CFSTR("CydiaSettings"), (__bridge CFPropertyListRef)previous,
        CFSTR("com.saurik.Cydia"));
    return NO;
#endif
}
}

NSString *CydiaExplicitRepositorySecurityPreference() {
    @synchronized (SettingsLock()) {
        id value(ReadSettings()[@"RepositorySecurity"]);
        return IsSecurityPreference(value) ? value : nil;
    }
}

NSString *CydiaEffectiveRepositorySecurityPreference(BOOL selectedExternalProviderReady) {
    NSString *saved(CydiaExplicitRepositorySecurityPreference());
    const auto mode(CydiaAPT::EffectiveRepositorySecurityMode([saved UTF8String] ?: "", selectedExternalProviderReady));
    return [NSString stringWithUTF8String:CydiaAPT::RepositorySecurityModeName(mode)];
}

NSString *CydiaRepositorySecurityPreference() {
    return CydiaEffectiveRepositorySecurityPreference(NO);
}

BOOL CydiaSetRepositorySecurityPreference(NSString *value) {
    if (!IsSecurityPreference(value)) return NO;
    @synchronized (SettingsLock()) {
        NSMutableDictionary *settings(ReadSettings());
        settings[@"RepositorySecurity"] = value;
        return WriteSettings(settings);
    }
}

NSString *CydiaRuntimeProviderPreference() {
    @synchronized (SettingsLock()) {
        id value(ReadSettings()[@"RuntimeProvider"]);
        return [value isKindOfClass:[NSString class]] && [value isEqualToString:@"recovery"] ? @"recovery" : @"automatic";
    }
}

BOOL CydiaSetRuntimeProviderPreference(NSString *value) {
    if (![value isKindOfClass:[NSString class]] ||
        (![value isEqualToString:@"automatic"] && ![value isEqualToString:@"recovery"])) return NO;
    @synchronized (SettingsLock()) {
        NSMutableDictionary *settings(ReadSettings());
        settings[@"RuntimeProvider"] = value;
        return WriteSettings(settings);
    }
}

NSDictionary<NSString *, NSString *> *CydiaRepositoryIdentityPreferences() {
    @synchronized (SettingsLock()) {
        NSDictionary *settings(ReadSettings());
        id identity = settings[@"RepositoryIdentity"], custom = settings[@"RepositoryCustomUserAgent"];
        const char *identityBytes = [identity isKindOfClass:NSString.class] ? [identity UTF8String] : nullptr;
        const char *customBytes = [custom isKindOfClass:NSString.class] ? [custom UTF8String] : nullptr;
        const std::string customText = customBytes ? std::string(customBytes, [custom lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) : std::string();
        if (!CydiaRuntime::ValidRepositoryUserAgent(customText)) custom = @"";
        if (!identityBytes || !CydiaRuntime::ValidRepositoryIdentity(std::string(identityBytes,
            [identity lengthOfBytesUsingEncoding:NSUTF8StringEncoding])) ||
            ([identity isEqual:@"custom"] && [custom length] == 0)) identity = @"cydia";
        return @{@"identity": identity, @"custom": custom};
    }
}
NSString *CydiaRepositoryIdentityPreference() { return CydiaRepositoryIdentityPreferences()[@"identity"]; }
NSString *CydiaCustomRepositoryUserAgentPreference() { return CydiaRepositoryIdentityPreferences()[@"custom"]; }
BOOL CydiaSetRepositoryIdentityPreference(NSString *identity, NSString *custom) {
    if (![identity isKindOfClass:NSString.class] || ![custom isKindOfClass:NSString.class]) return NO;
    identity = [identity copy]; custom = [custom copy];
    if ([identity lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 6 ||
        [custom lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 512) return NO;
    const char *identityBytes = identity.UTF8String, *customBytes = custom.UTF8String;
    if (!identityBytes || !customBytes || !CydiaRuntime::ValidRepositoryIdentity(std::string(identityBytes,
        [identity lengthOfBytesUsingEncoding:NSUTF8StringEncoding]))) return NO;
    const std::string customText(customBytes, [custom lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    if ((!customText.empty() || [identity isEqual:@"custom"]) && !CydiaRuntime::ValidRepositoryUserAgent(customText)) return NO;
    @synchronized (SettingsLock()) {
        NSMutableDictionary *settings(ReadSettings());
        settings[@"RepositoryIdentity"] = identity;
        settings[@"RepositoryCustomUserAgent"] = custom;
        return WriteSettings(settings);
    }
}
