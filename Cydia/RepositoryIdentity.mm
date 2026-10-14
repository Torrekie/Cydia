/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RepositoryIdentity.h"
#import "Cydia/SettingsStore.h"
#include "Cydia/RepositoryIdentity.hpp"

static std::string IdentityText(NSString *value) {
    const char *bytes = [value UTF8String];
    return bytes ? std::string(bytes, [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) : std::string();
}
BOOL CydiaValidCustomRepositoryUserAgent(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0 ||
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 512) return NO;
    return CydiaRuntime::ValidRepositoryUserAgent(IdentityText(value));
}
NSString *CydiaRepositoryUserAgentForIdentity(NSString *identity, NSString *custom, BOOL download) {
    const auto agent = CydiaRuntime::RepositoryUserAgent(IdentityText(identity), IdentityText(custom), download);
    return [NSString stringWithUTF8String:agent.c_str()];
}
NSString *CydiaRepositoryUserAgent() {
    NSDictionary *settings = CydiaRepositoryIdentityPreferences();
    return CydiaRepositoryUserAgentForIdentity(settings[@"identity"], settings[@"custom"], NO);
}
NSString *CydiaRepositoryDownloadUserAgent() {
    NSDictionary *settings = CydiaRepositoryIdentityPreferences();
    return CydiaRepositoryUserAgentForIdentity(settings[@"identity"], settings[@"custom"], YES);
}
