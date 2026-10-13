/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/FetchDiagnostics.h"
#include <initializer_list>

namespace {
bool DiagnosticCodeIs(const std::string &code, std::initializer_list<const char *> candidates) {
    for (const char *candidate : candidates) if (code == candidate) return true;
    return false;
}
NSString *DiagnosticLabel(NSString *key, NSString *table) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:table];
}
}

NSString *CydiaAPTDiagnosticMessage(const CydiaAPT::ErrorData &diagnostic) {
    const std::string &code(diagnostic.cydiaCode);
    if (code.empty()) {
        // Do not infer ownership from English wording or a code-looking
        // message: upstream gettext remains authoritative for upstream text.
        return [[NSString alloc] initWithBytes:diagnostic.message.data() length:diagnostic.message.size()
                                     encoding:NSUTF8StringEncoding] ?: DiagnosticLabel(@"OPERATION_FAILED", @"RuntimeProvider");
    }
    if (code == "provider_frontend_busy" || code == "provider_frontend_lock_unavailable")
        return DiagnosticLabel(@"DPKG_LOCKED", nil);
    if (code == "provider_cancelled") return DiagnosticLabel(@"TRANSACTION_CANCELLED", nil);
    if (code == "provider_extended_state_commit_failed")
        return DiagnosticLabel(@"TRANSACTION_STATE_SAVE_FAILED", @"Settings");
    if (DiagnosticCodeIs(code, {"provider_execution_outcome_unknown", "provider_cancellation_unsettled"}))
        return DiagnosticLabel(@"TRANSACTION_FAILED", @"Settings");
    if (DiagnosticCodeIs(code, {
        "provider_package_state_changed", "provider_environment_changed", "provider_registration_changed",
        "provider_changed_since_probe", "provider_changed_during_launch", "provider_changed_during_probe",
        "provider_execution_state_changed", "provider_architectures_changed", "provider_authority_changed",
        "provider_dpkg_options_changed", "provider_archive_index_changed", "provider_archive_sources_changed",
        "provider_evidence_changed", "provider_review_changed", "provider_reprobe_required",
        "provider_native_launch_environment_changed"}))
        return DiagnosticLabel(@"TRANSACTION_STALE", @"Settings");
    if (DiagnosticCodeIs(code, {
        "provider_review_missing", "provider_review_or_lock_required", "provider_unverified_dpkg_effects",
        "provider_deconfiguration_unknown", "provider_trigger_targets_unknown", "provider_archive_evidence_unavailable",
        "provider_trigger_predepends_batch_boundary", "provider_trigger_primary_not_authorized",
        "provider_native_auto_deconfigure_unsupported", "provider_native_launch_environment_invalid",
        "provider_native_effect_policy_invalid", "provider_native_effect_policy_circular",
        "provider_conffile_policy_unavailable", "provider_conffile_policy_binding_invalid",
        "provider_conffile_policy_changed",
        "provider_archive_review_missing", "provider_parent_operation_unsupported", "provider_security_override_unsupported",
        "provider_execution_not_approved", "provider_archive_manifest_missing", "provider_dpkg_state_unavailable"}))
        return DiagnosticLabel(@"REVIEW_UNAVAILABLE", @"RuntimeProvider");
    if (DiagnosticCodeIs(code, {"provider_session_unavailable", "provider_invalid_session", "provider_spawn_failed"}))
        return DiagnosticLabel(@"BROKEN_HELP", @"RuntimeProvider");
    // Unknown codes are useful to developers, but never user-facing text.
    return DiagnosticLabel(@"OPERATION_FAILED", @"RuntimeProvider");
}

NSString *CydiaFetchDiagnosticMessage(const CydiaAPT::FetchFailureData &diagnostic) {
    if (diagnostic.reason == "invalid_download_grant" ||
        (diagnostic.reason == "repository_authorization_failed" && diagnostic.error.empty()))
        return [[NSBundle mainBundle] localizedStringForKey:@"ACCOUNT_REQUEST_FAILED" value:nil table:@"Accounts"];
    if (diagnostic.reason == "repository_authorization_required" && diagnostic.error.empty())
        return [[NSBundle mainBundle] localizedStringForKey:@"ACCOUNT_UNSUPPORTED" value:nil table:@"Accounts"];
    if (diagnostic.reason == "transaction_changed")
        return [[NSBundle mainBundle] localizedStringForKey:@"TRANSACTION_STALE" value:nil table:@"Settings"];
    NSString *key(nil);
    switch (diagnostic.kind) {
        case CydiaAPT::FetchDiagnosticKind::ArchiveIncomplete: key = @"ARCHIVE_INCOMPLETE"; break;
        case CydiaAPT::FetchDiagnosticKind::ArchiveMissingHashes: key = @"ARCHIVE_MISSING_HASHES"; break;
        case CydiaAPT::FetchDiagnosticKind::ArchiveMismatch: key = @"ARCHIVE_MISMATCH"; break;
        case CydiaAPT::FetchDiagnosticKind::ArchiveUnavailable: key = @"ARCHIVE_UNAVAILABLE"; break;
        case CydiaAPT::FetchDiagnosticKind::ArchiveLayoutMismatch: key = @"ARCHIVE_LAYOUT_MISMATCH"; break;
        case CydiaAPT::FetchDiagnosticKind::ArchiveInvalid: key = @"ARCHIVE_INVALID"; break;
        case CydiaAPT::FetchDiagnosticKind::ArchiveIdentityMismatch: key = @"ARCHIVE_IDENTITY_MISMATCH"; break;
        case CydiaAPT::FetchDiagnosticKind::ArchiveUnverified: key = @"ARCHIVE_UNVERIFIED"; break;
        case CydiaAPT::FetchDiagnosticKind::ArchiveTrustNeedsRefresh: key = @"ARCHIVE_TRUST_REFRESH_REQUIRED"; break;
        case CydiaAPT::FetchDiagnosticKind::UnauthenticatedSource: key = @"ARCHIVE_UNAUTHENTICATED"; break;
        case CydiaAPT::FetchDiagnosticKind::UnsignedRepository: key = @"REPOSITORY_UNSIGNED"; break;
        case CydiaAPT::FetchDiagnosticKind::MissingSigningKey: key = @"REPOSITORY_MISSING_KEY"; break;
        case CydiaAPT::FetchDiagnosticKind::UnusableSigningKey: key = @"REPOSITORY_UNUSABLE_KEY"; break;
        case CydiaAPT::FetchDiagnosticKind::WeakRepository: key = @"REPOSITORY_WEAK"; break;
        case CydiaAPT::FetchDiagnosticKind::MissingReleaseFile: key = @"REPOSITORY_MISSING_RELEASE"; break;
        case CydiaAPT::FetchDiagnosticKind::RepositoryTrustDowngrade: key = @"REPOSITORY_TRUST_DOWNGRADE"; break;
        case CydiaAPT::FetchDiagnosticKind::BadRepositorySignature: key = @"REPOSITORY_BAD_SIGNATURE"; break;
        case CydiaAPT::FetchDiagnosticKind::InvalidRepositorySignature: key = @"REPOSITORY_INVALID_SIGNATURE"; break;
        case CydiaAPT::FetchDiagnosticKind::General: break;
    }
    if (key == nil) return [NSString stringWithUTF8String:diagnostic.error.c_str()];
    NSString *format([[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"]);
    NSString *package([NSString stringWithUTF8String:diagnostic.package.c_str()]);
    NSString *message([NSString stringWithFormat:format, package]);
    if (!diagnostic.path.empty()) message = [message stringByAppendingFormat:@"\n%@",
        [NSString stringWithUTF8String:diagnostic.path.c_str()]];
    if (!diagnostic.uri.empty()) message = [message stringByAppendingFormat:@"\n%@",
        [NSString stringWithUTF8String:diagnostic.uri.c_str()]];
    return message;
}
