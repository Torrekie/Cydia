/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionRequest.hpp"
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/ExtendedState.hpp"

namespace CydiaAPT { namespace Provider {
namespace {
bool Digest(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
bool Pool(const std::map<std::string, ExecutionPackage> &pool) {
    if (pool.size() > MaximumTriggerEffectPackages) return false;
    for (const auto &item : pool) {
        const auto &package = item.second;
        if (!CydiaRuntime::ValidPackageName(package.package) ||
            !CydiaRuntime::ValidArchitectureName(package.architecture) || package.architecture == "any" ||
            package.architecture == "native" || package.version.empty() || package.version.size() > 1024 ||
            package.version.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+:~-") != std::string::npos ||
            item.first != package.package + ':' + package.architecture + '@' + package.version) return false;
    }
    return true;
}
bool EffectApproval(const TriggerEffectEnvelope &value) {
    if (!Digest(value.identity) || !Digest(value.initialCheckpoint) || !Digest(value.nativeAuthorityIdentity) ||
        !Pool(value.recipients) || !Pool(value.awaiters) ||
        value.incoming.size() > MaximumTriggerEffectPackages) return false;
    for (const auto &recipient : value.recipients) {
        const auto waiter = value.awaiters.find(recipient.first);
        if (waiter == value.awaiters.end()) return false;
    }
    for (const auto &incoming : value.incoming) if (!value.recipients.count(incoming)) return false;
    Message bound; bound.sequence = 1; bound.operation = Operation::RunPackageManager; bound.binding = value.primaryReview.binding;
    return ValidRequestBinding(bound) && !value.primaryReview.execution.actions.empty();
}
bool Valid(const TransactionBeginRequest &value) {
    Message bound; bound.sequence = 1; bound.operation = Operation::RunPackageManager; bound.binding = value.review.binding;
    if (!ValidRequestBinding(bound) || value.changes.size() > MaximumCollectionItems ||
        value.additionalActions.size() > MaximumCollectionItems || value.archiveWarnings.size() > MaximumCollectionItems ||
        value.extendedState.size() > 4 * 1024 * 1024) return false;
    std::set<std::string> packages;
    for (const auto &change : value.changes) {
        if (!CydiaRuntime::ValidPackageName(change.package) || !CydiaRuntime::ValidArchitectureName(change.architecture) ||
            change.architecture == "any" || change.architecture == "native" ||
            !packages.insert(change.package + ':' + change.architecture).second) return false;
    }
    for (auto id : value.additionalActions) if (!id) return false;
    for (const auto &id : value.archiveWarnings) if (!ValidIdentityToken(id)) return false;
    if (value.reviewedEffects) {
        std::string first, second;
        if (!EffectApproval(*value.reviewedEffects) || !Encode(value.review, &first) ||
            !Encode(value.reviewedEffects->primaryReview, &second) || first != second) return false;
    }
    return true;
}
}
bool EncodeTriggerEffectEnvelope(const TriggerEffectEnvelope &value, std::string *bytes) {
    if (!bytes || !EffectApproval(value)) return false;
    Writer writer;
    if (!writer(std::string("CYDIA-TRIGGER-APPROVAL-2"), value.identity, value.initialCheckpoint, value.nativeAuthorityIdentity,
        value.primaryReview, value.recipients, value.awaiters, value.incoming) ||
        writer.result().size() > MaximumMessageBytes) return false;
    *bytes = writer.result(); return true;
}
bool DecodeTriggerEffectEnvelope(const std::string &bytes, TriggerEffectEnvelope *value) {
    if (!value || bytes.size() > MaximumMessageBytes) return false;
    Reader reader(bytes); TriggerEffectEnvelope parsed; std::string version, canonical;
    if (!reader(version, parsed.identity, parsed.initialCheckpoint, parsed.nativeAuthorityIdentity, parsed.primaryReview,
        parsed.recipients, parsed.awaiters, parsed.incoming) || !reader.complete() ||
        version != "CYDIA-TRIGGER-APPROVAL-2" || !EncodeTriggerEffectEnvelope(parsed, &canonical) || canonical != bytes) return false;
    *value = std::move(parsed); return true;
}
bool EncodeTransactionBegin(const TransactionBeginRequest &value, std::string *bytes) {
    if (!bytes || !Valid(value)) return false;
    Writer writer; std::string effects;
    if (value.reviewedEffects && !EncodeTriggerEffectEnvelope(*value.reviewedEffects, &effects)) return false;
    if (!writer(std::string("CYDIA-TRANSACTION-BEGIN-2"), value.review, value.additionalActions,
        value.archiveWarnings, value.changes, value.extendedState, effects) || writer.result().size() > 8 * 1024 * 1024) return false;
    *bytes = writer.result(); return true;
}
bool DecodeTransactionBegin(const std::string &bytes, TransactionBeginRequest *value) {
    if (!value || bytes.size() > 8 * 1024 * 1024) return false;
    Reader reader(bytes); TransactionBeginRequest parsed; std::string version, effects;
    if (!reader(version, parsed.review, parsed.additionalActions, parsed.archiveWarnings,
        parsed.changes, parsed.extendedState, effects) || !reader.complete() || version != "CYDIA-TRANSACTION-BEGIN-2") return false;
    if (!effects.empty()) {
        std::shared_ptr<TriggerEffectEnvelope> approval(new TriggerEffectEnvelope());
        if (!DecodeTriggerEffectEnvelope(effects, approval.get())) return false;
        parsed.reviewedEffects = std::move(approval);
    }
    if (!Valid(parsed)) return false;
    std::string canonical;
    if (!EncodeTransactionBegin(parsed, &canonical) || canonical != bytes) return false;
    *value = std::move(parsed); return true;
}
}}
