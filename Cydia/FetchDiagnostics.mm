/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/FetchDiagnostics.h"
#include <dispatch/dispatch.h>

namespace {

NSString *DiagnosticFormat(NSBundle *bundle, NSString *key, NSString *fallback) {
    return [(bundle ?: [NSBundle mainBundle]) localizedStringForKey:key value:fallback table:@"Settings"];
}

NSString *ConnectionDiagnostic(NSString *message, NSBundle *bundle) {
    if ([message isEqualToString:@"Connection timed out"])
        return DiagnosticFormat(bundle, @"APT_CONNECTION_TIMEOUT", @"Connection timed out");

    /* connect.cc can join one timeout per attempted address with spaces or
     * newlines. Only translate if the entire reason matches that grammar;
     * unfamiliar method output must remain available for troubleshooting. */
    static NSRegularExpression *timeout;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timeout = [[NSRegularExpression alloc] initWithPattern:
            @"Could not connect to ([^\\s]+):([A-Za-z0-9]+) \\(([^\\s()]+)\\), connection timed out(?=\\s|$)"
            options:0 error:NULL];
    });
    NSMutableArray *attempts([NSMutableArray array]);
    NSUInteger offset(0);
    while (offset < message.length) {
        NSTextCheckingResult *match([timeout firstMatchInString:message options:NSMatchingAnchored
            range:NSMakeRange(offset, message.length - offset)]);
        if (match == nil) return message;
        NSString *format(DiagnosticFormat(bundle, @"APT_CONNECT_TIMEOUT",
            @"Could not connect to %@:%@ (%@), connection timed out"));
        [attempts addObject:[NSString stringWithFormat:format,
            [message substringWithRange:[match rangeAtIndex:1]],
            [message substringWithRange:[match rangeAtIndex:2]],
            [message substringWithRange:[match rangeAtIndex:3]]]];
        offset = NSMaxRange(match.range);
        while (offset < message.length && [[NSCharacterSet whitespaceAndNewlineCharacterSet]
                characterIsMember:[message characterAtIndex:offset]]) ++offset;
    }
    return attempts.count == 0 ? message : [attempts componentsJoinedByString:@"\n"];
}

} // namespace

NSString *CydiaAPTDiagnosticMessage(NSString *message, NSBundle *bundle) {
    if (message.length == 0 || message.length > 65536) return message;
    if ([message isEqualToString:@"Some index files failed to download. They have been ignored, or old ones used instead."])
        return DiagnosticFormat(bundle, @"APT_INDEX_DOWNLOAD_FAILED",
            @"Some index files failed to download. They have been ignored, or old ones used instead.");

    /* debmetaindex.cc uses this template only for these Release fields. Keep
     * the field spelling and complete filename, including spaces, intact. */
    for (NSString *field in @[@"Date", @"Valid-Until", @"Signed-By"]) {
        NSString *prefix([NSString stringWithFormat:@"Invalid '%@' entry in Release file ", field]);
        if ([message hasPrefix:prefix] && message.length > prefix.length)
            return [NSString stringWithFormat:DiagnosticFormat(bundle, @"APT_INVALID_RELEASE_FIELD",
                @"Invalid '%@' entry in Release file %@"), field, [message substringFromIndex:prefix.length]];
    }

    NSString *prefix(@"Failed to fetch ");
    if ([message hasPrefix:prefix]) {
        /* update.cc unquotes local paths, which can themselves contain the
         * two-space separator. Keep those ambiguous diagnostics verbatim. */
        NSString *payload([message substringFromIndex:prefix.length]);
        if ([payload hasPrefix:@"file:"] || [payload hasPrefix:@"copy:"]) return message;
        /* Remote URIs are escaped; update.cc separates the URI and the
         * acquire-method reason with exactly two spaces. */
        NSRange separator([message rangeOfString:@"  " options:0
            range:NSMakeRange(prefix.length, message.length - prefix.length)]);
        if (separator.location != NSNotFound && separator.location > prefix.length) {
            NSString *uri([message substringWithRange:NSMakeRange(prefix.length, separator.location - prefix.length)]);
            NSString *reason([message substringFromIndex:NSMaxRange(separator)]);
            return [NSString stringWithFormat:DiagnosticFormat(bundle, @"APT_FETCH_FAILED",
                @"Failed to fetch %@\n%@"), uri, ConnectionDiagnostic(reason, bundle)];
        }
    }
    return ConnectionDiagnostic(message, bundle);
}

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
    if (key == nil) return CydiaAPTDiagnosticMessage([NSString stringWithUTF8String:diagnostic.error.c_str()]);
    NSString *format([[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"]);
    NSString *package([NSString stringWithUTF8String:diagnostic.package.c_str()]);
    NSString *message([NSString stringWithFormat:format, package]);
    if (!diagnostic.path.empty()) message = [message stringByAppendingFormat:@"\n%@",
        [NSString stringWithUTF8String:diagnostic.path.c_str()]];
    if (!diagnostic.uri.empty()) message = [message stringByAppendingFormat:@"\n%@",
        [NSString stringWithUTF8String:diagnostic.uri.c_str()]];
    return message;
}
