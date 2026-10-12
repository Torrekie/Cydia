/* Cydia-owned diagnostic presentation; Foundation only.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#include "Cydia/FetchDiagnostics.h"
#include <cstdlib>
#include <iostream>

namespace {
void Require(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "[fetch-diagnostics] " << message << '\n'; std::exit(1);
}
void Text(NSString *actual, NSString *expected, const char *message) {
    Require(actual != nil && [actual isEqualToString:expected], message);
}
NSString *Label(NSString *key, NSString *table) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:table];
}
void Local(const char *code, NSString *key, NSString *table) {
    Text(CydiaAPTDiagnosticMessage({"must not be displayed", false, code}), Label(key, table),
        "typed Cydia failure used raw code/text or the wrong localized label");
}
void UpstreamText() {
    for (const char *message : {"Le téléchargement a échoué.", "无法连接到软件源。", "provider_frontend_busy"})
        Text(CydiaAPTDiagnosticMessage({message, false}), [NSString stringWithUTF8String:message],
            "upstream message was retranslated or inferred to be a Cydia diagnostic");
    const std::string bytes("first\0second", 12);
    Text(CydiaAPTDiagnosticMessage({bytes, true}),
        [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding],
        "upstream text was truncated at an embedded null");
    Text(CydiaAPTDiagnosticMessage({"", true}), @"", "empty upstream diagnostic changed");
    Text(CydiaAPTDiagnosticMessage({std::string(1, '\xff'), false}),
        Label(@"OPERATION_FAILED", @"RuntimeProvider"), "invalid UTF-8 must not produce a nil UI message");
}
void CydiaLabels() {
    Local("provider_frontend_busy", @"DPKG_LOCKED", nil);
    Local("provider_cancelled", @"TRANSACTION_CANCELLED", nil);
    Local("provider_extended_state_commit_failed", @"TRANSACTION_STATE_SAVE_FAILED", @"Settings");
    Local("provider_execution_outcome_unknown", @"TRANSACTION_FAILED", @"Settings");
    Local("provider_cancellation_unsettled", @"TRANSACTION_FAILED", @"Settings");
    Local("provider_environment_changed", @"TRANSACTION_STALE", @"Settings");
    Local("provider_review_or_lock_required", @"REVIEW_UNAVAILABLE", @"RuntimeProvider");
    Local("provider_session_unavailable", @"BROKEN_HELP", @"RuntimeProvider");
    Local("future_provider_diagnostic", @"OPERATION_FAILED", @"RuntimeProvider");
    Local("https://user:password@repo.invalid/secret", @"OPERATION_FAILED", @"RuntimeProvider");
}
}
int main() {
    @autoreleasepool {
        UpstreamText(); CydiaLabels();
        std::puts("[fetch-diagnostics] Cydia localization and upstream text ownership passed");
    }
}
