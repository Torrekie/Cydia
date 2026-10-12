/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/TransactionReview.h"
#include "Cydia/RuntimeProviderStatus.h"
#include "Cydia/PackageArchitecturePresentation.h"

namespace {
NSString *PackageName(const CydiaAPT::Provider::ExecutionPackage &package, NSArray<NSString *> *architectures) {
    NSString *name([[NSString alloc] initWithBytes:package.package.data() length:package.package.size() encoding:NSUTF8StringEncoding]);
    NSString *architecture([[NSString alloc] initWithBytes:package.architecture.data() length:package.architecture.size() encoding:NSUTF8StringEncoding]);
    if (!name || !architecture) return nil;
    return CydiaPackageNameWithArchitectureCaption(name, CydiaPackageArchitectureCaption(architecture, architectures));
}
NSString *Version(const CydiaAPT::Provider::ExecutionPackage &package) {
    return [[NSString alloc] initWithBytes:package.version.data() length:package.version.size() encoding:NSUTF8StringEncoding];
}
}

@implementation CydiaTransactionReview {
    CydiaAPT::TransactionData transaction_;
    std::set<std::uint64_t> actions_;
    std::set<std::string> archiveWarnings_;
    std::string transactionBytes_;
}
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)review {
    if ((self = [super init])) {
        transaction_ = transaction;
        CydiaAPT::Provider::Encode(transaction_, &transactionBytes_);
        NSMutableArray *operations([NSMutableArray array]);
        NSArray<NSString *> *architectures(CydiaPackageRegisteredArchitectureNames(transaction.registeredArchitectures));
        if (review) for (const auto &action : review->execution.actions) {
            const unsigned kind(static_cast<unsigned>(action.action));
            NSArray *keys(@[@"REVIEW_UNPACK", @"REVIEW_CONFIGURE", @"REVIEW_REMOVE", @"REVIEW_PURGE",
                @"REVIEW_TRIGGERS", @"REVIEW_DECONFIGURE"]);
            if (kind >= keys.count) return nil;
            const auto &package(action.package);
            NSString *identity(PackageName(package, architectures));
            NSString *version(Version(package));
            if (!identity || !version || !actions_.insert(action.identifier).second) return nil;
            [operations addObject:@{@"title": [NSString stringWithFormat:@"%@: %@",
                CydiaRuntimeProviderLocalize(keys[kind]), identity], @"detail": version}];
        }
        _operations = [operations copy];
        NSMutableArray *warnings([NSMutableArray array]);
        // Archive semantics are independent of source-signature policy. The
        // parent still rejects incomplete, invalid or conflicting archives;
        // these exact IDs acknowledge only complete inspections with limits.
        if (review)
            for (const auto &archive : review->execution.archives) {
                NSString *identity(PackageName(archive.package, architectures));
                NSString *version(Version(archive.package));
                if (!identity || !version || !archiveWarnings_.insert(archive.identifier).second) return nil;
                [warnings addObject:@{@"title": [NSString stringWithFormat:@"%@ %@", identity, version],
                    @"detail": [NSString stringWithFormat:CydiaRuntimeProviderLocalize(@"ARCHIVE_REVIEW_LIMITS"), identity]}];
            }
        _archiveWarningRows = [warnings copy];
        _runtimeNotice = review ? @"" : CydiaRuntimeProviderLocalize(@"RECOVERY_REVIEW");
    }
    return self;
}
- (const CydiaAPT::TransactionData &)transaction { return transaction_; }
- (const std::set<std::uint64_t> &)displayedActions { return actions_; }
- (const std::set<std::string> &)displayedArchiveWarnings { return archiveWarnings_; }
- (bool)matchesTransaction:(const CydiaAPT::TransactionData &)transaction {
    std::string bytes;
    return !transactionBytes_.empty() && CydiaAPT::Provider::Encode(transaction, &bytes) && transactionBytes_ == bytes;
}
@end
