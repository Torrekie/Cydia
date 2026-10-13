/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/TransactionReview.h"
#include "Cydia/RuntimeProviderStatus.h"
#include "Cydia/PackageArchitecturePresentation.h"
#include "Cydia/AptProviderTransactionRequest.hpp"

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
    std::string effectsIdentity_;
}
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)review
    runtimeOrigin:(CydiaAPT::RuntimeDescriptorOrigin)origin {
    return [self initWithTransaction:transaction providerReview:review runtimeOrigin:origin reviewedEffects:nullptr];
}
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)review
    runtimeOrigin:(CydiaAPT::RuntimeDescriptorOrigin)origin
    reviewedEffects:(const CydiaAPT::Provider::TriggerEffectEnvelope *)effects {
    if ((self = [super init])) {
        using Origin = CydiaAPT::RuntimeDescriptorOrigin;
        if (origin != Origin::Embedded && origin != Origin::External && origin != Origin::RecoveryWorker) return nil;
        if ((origin == Origin::Embedded) != (review == nullptr)) return nil;
        _runtimeOrigin = origin;
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
        NSMutableArray *processing([NSMutableArray array]);
        if (effects) {
            std::string bytes, primary, shown;
            if (!review || !CydiaAPT::Provider::EncodeTriggerEffectEnvelope(*effects, &bytes) ||
                !CydiaAPT::Provider::Encode(*review, &primary) ||
                !CydiaAPT::Provider::Encode(effects->primaryReview, &shown) || primary != shown) return nil;
            auto packages(effects->recipients);
            packages.insert(effects->awaiters.begin(), effects->awaiters.end());
            for (const auto &item : packages) {
                NSString *name(PackageName(item.second, architectures)), *version(Version(item.second));
                if (!name || !version) return nil;
                [processing addObject:@{@"title": name, @"detail": version}];
            }
            effectsIdentity_ = effects->identity;
        }
        _processingRows = [processing copy];
        _runtimeNotice = origin == Origin::External ? @"" : CydiaRuntimeProviderLocalize(@"RECOVERY_REVIEW");
    }
    return self;
}
- (const CydiaAPT::TransactionData &)transaction { return transaction_; }
- (const std::set<std::uint64_t> &)displayedActions { return actions_; }
- (const std::set<std::string> &)displayedArchiveWarnings { return archiveWarnings_; }
- (const std::string &)displayedEffectsIdentity { return effectsIdentity_; }
- (bool)matchesTransaction:(const CydiaAPT::TransactionData &)transaction {
    std::string bytes;
    return !transactionBytes_.empty() && CydiaAPT::Provider::Encode(transaction, &bytes) && transactionBytes_ == bytes;
}
@end
