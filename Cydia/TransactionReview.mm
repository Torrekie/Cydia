/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/TransactionReview.h"
#include "Cydia/RuntimeProviderStatus.h"
#include "Cydia/PackageArchitecturePresentation.h"
#include "Cydia/AptProviderTransactionRequest.hpp"
#include <CommonCrypto/CommonDigest.h>

std::string CydiaDeconfigurationReviewIdentity(const CydiaAPT::Provider::EffectReviewBundle &value) {
    std::string bytes;
    if (!CydiaAPT::Provider::EncodeEffectReviewBundle(value, &bytes)) return {};
    const char domain[] = "CYDIA-DECONFIGURATION-PRESENTATION-1";
    CC_SHA256_CTX context; unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (!CC_SHA256_Init(&context) || !CC_SHA256_Update(&context, domain, sizeof(domain) - 1) ||
        !CC_SHA256_Update(&context, bytes.data(), static_cast<CC_LONG>(bytes.size())) || !CC_SHA256_Final(digest, &context)) return {};
    const char hex[] = "0123456789abcdef"; std::string identity; identity.reserve(sizeof(digest) * 2);
    for (unsigned char byte : digest) { identity += hex[byte >> 4]; identity += hex[byte & 15]; }
    return identity;
}
NSString *CydiaDeconfigurationReviewLocalize(NSString *key) {
    NSDictionary *fallbacks(@{
        @"PACKAGE_TEMPORARY_CHANGES": @"Temporary package changes",
        @"PACKAGE_TEMPORARY_CHANGES_HELP": @"These installed package versions may temporarily become unconfigured. The follow-up operations shown here must finish before Cydia completes."
    });
    return [[NSBundle mainBundle] localizedStringForKey:key value:fallbacks[key] ?: key table:@"Actions"];
}

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
NSString *ExactPackageName(const CydiaAPT::Provider::ExecutionPackage &package) {
    const std::string qualified(package.package + ':' + package.architecture);
    return [[NSString alloc] initWithBytes:qualified.data() length:qualified.size() encoding:NSUTF8StringEncoding];
}
}

@implementation CydiaTransactionReview {
    CydiaAPT::TransactionData transaction_;
    std::set<std::uint64_t> actions_;
    std::set<std::string> archiveWarnings_;
    std::string transactionBytes_;
    std::string effectsIdentity_;
    std::string deconfigurationIdentity_;
    std::shared_ptr<const CydiaAPT::Provider::EffectReviewBundle> deconfiguration_;
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
    return [self initWithTransaction:transaction providerReview:review runtimeOrigin:origin reviewedEffects:effects
        reviewedDeconfiguration:std::shared_ptr<const CydiaAPT::Provider::EffectReviewBundle>()];
}
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)review
    runtimeOrigin:(CydiaAPT::RuntimeDescriptorOrigin)origin
    reviewedEffects:(const CydiaAPT::Provider::TriggerEffectEnvelope *)effects
    reviewedDeconfiguration:(const std::shared_ptr<const CydiaAPT::Provider::EffectReviewBundle> &)deconfiguration {
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
        NSMutableArray *conditional([NSMutableArray array]);
        if (deconfiguration) {
            // A copied or independently captured trigger DTO must not be joined
            // into this presentation. Both pools belong to this same pair.
            std::string shownTransaction;
            if (!review || effects != &deconfiguration->triggers ||
                !CydiaAPT::Provider::EffectReviewBundleMatches(*deconfiguration, *review, deconfiguration->methodsIdentity) ||
                !CydiaAPT::Provider::Encode(deconfiguration->deconfiguration.primaryReview.transaction, &shownTransaction) ||
                shownTransaction != transactionBytes_) return nil;
            deconfigurationIdentity_ = CydiaDeconfigurationReviewIdentity(*deconfiguration);
            if (deconfigurationIdentity_.size() != 64) return nil;
            std::map<std::uint64_t, const CydiaAPT::Provider::ReviewedAction *> actionsByID;
            for (const auto &action : review->execution.actions) actionsByID.emplace(action.identifier, &action);
            for (const auto &entry : deconfiguration->deconfiguration.allowances) {
                const auto &allowance(entry.second);
                NSString *installed(ExactPackageName(allowance.installed)), *oldVersion(Version(allowance.installed));
                if (!installed || !oldVersion) return nil;
                [conditional addObject:@{@"title": installed, @"detail": oldVersion, @"kind": @"installed"}];
                for (const auto &cause : allowance.causes) {
                    const auto found(actionsByID.find(cause.unpackAction));
                    if (found == actionsByID.end()) return nil;
                    const auto *incoming(found->second);
                    NSString *name(ExactPackageName(incoming->package)), *version(Version(incoming->package));
                    NSString *relation([[NSString alloc] initWithBytes:cause.canonicalRelation.data() length:cause.canonicalRelation.size()
                        encoding:NSUTF8StringEncoding]);
                    if (!name || !version || !relation) return nil;
                    // Literal relationship syntax is package metadata. For a
                    // sibling cause, show the two exact differing generations.
                    NSString *detail(cause.kind == CydiaAPT::Provider::DeconfigurationCauseKind::Breaks ?
                        [NSString stringWithFormat:@"%@\n%@", version, relation] :
                        [NSString stringWithFormat:@"%@ ↔ %@", version, oldVersion]);
                    [conditional addObject:@{@"title": [NSString stringWithFormat:@"%@: %@",
                        CydiaRuntimeProviderLocalize(@"REVIEW_UNPACK"), name], @"detail": detail, @"kind": @"cause"}];
                }
                NSString *name(ExactPackageName(allowance.endpoint.package)), *version(Version(allowance.endpoint.package));
                NSString *key(allowance.endpoint.kind == CydiaAPT::Provider::ExecutionAction::Configure ? @"REVIEW_CONFIGURE" :
                    allowance.endpoint.kind == CydiaAPT::Provider::ExecutionAction::Remove ? @"REVIEW_REMOVE" : @"REVIEW_PURGE");
                if (!name || !version) return nil;
                [conditional addObject:@{@"title": [NSString stringWithFormat:@"%@: %@", CydiaRuntimeProviderLocalize(key), name],
                    @"detail": version, @"kind": @"endpoint"}];
            }
            deconfiguration_ = deconfiguration;
        }
        _conditionalRows = [conditional copy];
        _runtimeNotice = origin == Origin::External ? @"" : CydiaRuntimeProviderLocalize(@"RECOVERY_REVIEW");
    }
    return self;
}
- (const CydiaAPT::TransactionData &)transaction { return transaction_; }
- (const std::set<std::uint64_t> &)displayedActions { return actions_; }
- (const std::set<std::string> &)displayedArchiveWarnings { return archiveWarnings_; }
- (const std::string &)displayedEffectsIdentity { return effectsIdentity_; }
- (const std::string &)displayedDeconfigurationIdentity { return deconfigurationIdentity_; }
- (bool)matchesTransaction:(const CydiaAPT::TransactionData &)transaction {
    std::string bytes;
    return !transactionBytes_.empty() && CydiaAPT::Provider::Encode(transaction, &bytes) && transactionBytes_ == bytes;
}
@end
