/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/SettingsStore.h"

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

NSString *CydiaRepositorySecurityPreference() {
    @synchronized (SettingsLock()) {
        id value(ReadSettings()[@"RepositorySecurity"]);
        return [@[@"allow", @"warning", @"error"] containsObject:value] ? value : @"warning";
    }
}

BOOL CydiaSetRepositorySecurityPreference(NSString *value) {
    if (![@[@"allow", @"warning", @"error"] containsObject:value]) return NO;
    @synchronized (SettingsLock()) {
        NSMutableDictionary *settings(ReadSettings());
        settings[@"RepositorySecurity"] = value;
        return WriteSettings(settings);
    }
}
