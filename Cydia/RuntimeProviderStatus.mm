/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RuntimeProviderStatus.h"
#include "Cydia/RedactedURL.hpp"

NSString *const CydiaRuntimeProviderStatusDidChangeNotification = @"CydiaRuntimeProviderStatusDidChangeNotification";

NSString *CydiaRuntimeProviderLocalize(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"RuntimeProvider"];
}

static NSString *DisplayText(NSString *value, NSUInteger maximum) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    const char *bytes([value UTF8String]);
    if (bytes == nullptr) return @"";
    const std::string safe(CydiaRuntime::RedactDiagnosticURLs(
        std::string(bytes, [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding])));
    NSString *text([[NSString alloc] initWithBytes:safe.data() length:safe.size() encoding:NSUTF8StringEncoding]);
    if (text == nil) return @"";
    if (text.length > maximum) text = [text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maximum)]];
    return text;
}

@implementation CydiaRuntimeProviderStatus
- (instancetype)initWithPreference:(NSString *)preference state:(CydiaRuntimeProviderState)state
    providerName:(NSString *)providerName providerVersion:(NSString *)providerVersion
    aptVersion:(NSString *)aptVersion diagnostic:(NSString *)diagnostic {
    if ((self = [super init])) {
        _preference = [preference isEqualToString:@"recovery"] ? @"recovery" : @"automatic";
        _state = state;
        _providerName = [DisplayText(providerName, 256) copy];
        _providerVersion = [DisplayText(providerVersion, 256) copy];
        _aptVersion = [DisplayText(aptVersion, 256) copy];
        _diagnostic = [DisplayText(diagnostic, 4096) copy];
    }
    return self;
}
@end
