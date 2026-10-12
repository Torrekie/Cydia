/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/FetchDiagnostics.h"

NSString *CydiaFetchDiagnosticMessage(const CydiaAPT::FetchFailureData &diagnostic) {
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
