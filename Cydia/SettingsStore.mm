/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SettingsStore.h"
#include "Cydia/RepositorySecurityPolicy.hpp"

namespace {
NSObject *SettingsLock() {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSObject alloc] init]; });
    return lock;
}

NSMutableDictionary *ReadSettings() {
    id value(CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("CydiaSettings"), CFSTR("com.saurik.Cydia"))));
    return [value isKindOfClass:[NSDictionary class]] ? [value mutableCopy] :
        [NSMutableDictionary dictionary];
}

bool IsSecurityPreference(id value) {
    if (![value isKindOfClass:[NSString class]]) return false;
    const char *bytes([value UTF8String]);
    return bytes != nullptr && CydiaAPT::IsRepositorySecurityModeName(
        std::string(bytes, [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]));
}

BOOL WriteSettings(NSDictionary *settings) {
    id previous(CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("CydiaSettings"), CFSTR("com.saurik.Cydia"))));
    CFPreferencesSetAppValue(CFSTR("CydiaSettings"), (__bridge CFPropertyListRef)settings,
        CFSTR("com.saurik.Cydia"));
    if (CFPreferencesAppSynchronize(CFSTR("com.saurik.Cydia"))) return YES;
    // Keep the in-process preference aligned with the reported failure.
    CFPreferencesSetAppValue(CFSTR("CydiaSettings"), (__bridge CFPropertyListRef)previous,
        CFSTR("com.saurik.Cydia"));
    return NO;
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
