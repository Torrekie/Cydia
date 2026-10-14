/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_TransactionReview_H
#define Cydia_TransactionReview_H
#import <Foundation/Foundation.h>
#include "Cydia/AptBackend.hpp"
#include "Cydia/AptProviderProtocol.hpp"
#include "Cydia/AptProviderTriggerEffects.hpp"
#include "Cydia/AptRuntimeDescriptor.hpp"
#include "Cydia/AptProviderEffectReviewBundle.hpp"

// Parent-local presentation identity over every canonical paired approval
// byte. It binds the immutable display; it grants no execution authority.
std::string CydiaDeconfigurationReviewIdentity(const CydiaAPT::Provider::EffectReviewBundle &);
NSString *CydiaDeconfigurationReviewLocalize(NSString *key);

// Immutable parent-owned value retained by both Database and its confirmation
// controller. Its object identity is the approval token; no worker token alone
// can authorize an operation or replace what the controller displayed.
@interface CydiaTransactionReview : NSObject
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *operations;
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *archiveWarningRows;
@property(nonatomic, copy, readonly) NSString *runtimeNotice;
// Copied from the coordinator's adopted immutable descriptor; protocol review
// presence and worker identifiers never determine recovery policy presentation.
@property(nonatomic, readonly) CydiaAPT::RuntimeDescriptorOrigin runtimeOrigin;
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *processingRows;
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *conditionalRows;
// Exact network acquisitions requiring commercial account preparation. These
// immutable rows are presentation only; final fetching obtains fresh grants.
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *repositoryAccessRequests;
@property(nonatomic, readonly) BOOL repositoryAuthorizedDownloadsSupported;
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)providerReview
    runtimeOrigin:(CydiaAPT::RuntimeDescriptorOrigin)origin;
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)providerReview
    runtimeOrigin:(CydiaAPT::RuntimeDescriptorOrigin)origin
    reviewedEffects:(const CydiaAPT::Provider::TriggerEffectEnvelope *)effects;
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)providerReview
    runtimeOrigin:(CydiaAPT::RuntimeDescriptorOrigin)origin
    reviewedEffects:(const CydiaAPT::Provider::TriggerEffectEnvelope *)effects
    reviewedDeconfiguration:(const std::shared_ptr<const CydiaAPT::Provider::EffectReviewBundle> &)deconfiguration;
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)providerReview
    runtimeOrigin:(CydiaAPT::RuntimeDescriptorOrigin)origin
    reviewedEffects:(const CydiaAPT::Provider::TriggerEffectEnvelope *)effects
    reviewedDeconfiguration:(const std::shared_ptr<const CydiaAPT::Provider::EffectReviewBundle> &)deconfiguration
    repositoryAccessRequests:(const std::vector<CydiaAPT::RepositoryArchiveAccessRequest> &)requests;
- (instancetype)initWithTransaction:(const CydiaAPT::TransactionData &)transaction
    providerReview:(const CydiaAPT::Provider::ReviewedTransaction *)providerReview
    runtimeOrigin:(CydiaAPT::RuntimeDescriptorOrigin)origin
    reviewedEffects:(const CydiaAPT::Provider::TriggerEffectEnvelope *)effects
    reviewedDeconfiguration:(const std::shared_ptr<const CydiaAPT::Provider::EffectReviewBundle> &)deconfiguration
    repositoryAccessRequests:(const std::vector<CydiaAPT::RepositoryArchiveAccessRequest> &)requests
    repositoryAuthorizedDownloadsSupported:(BOOL)supported;
- (const CydiaAPT::TransactionData &)transaction;
- (const std::set<std::uint64_t> &)displayedActions;
- (const std::set<std::string> &)displayedArchiveWarnings;
- (const std::string &)displayedEffectsIdentity;
- (const std::string &)displayedDeconfigurationIdentity;
- (bool)matchesTransaction:(const CydiaAPT::TransactionData &)transaction;
@end
#endif
