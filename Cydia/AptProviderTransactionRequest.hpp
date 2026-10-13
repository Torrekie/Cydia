/* Direct authenticated application request, distinct from worker RPC.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderTransactionRequest_HPP
#define Cydia_AptProviderTransactionRequest_HPP
#include "Cydia/AptProviderDpkgState.hpp"
#include "Cydia/AptProviderTriggerEffects.hpp"
#include <memory>
namespace CydiaAPT { namespace Provider {
struct EffectReviewBundle;
constexpr std::size_t MaximumTransactionBeginBytes = 8 * 1024 * 1024;
// Pure transport of an application approval. Only the native parent capture
// and owner-side recomputation establish the provenance of this value.
bool EncodeTriggerEffectEnvelope(const TriggerEffectEnvelope &, std::string *);
bool DecodeTriggerEffectEnvelope(const std::string &, TriggerEffectEnvelope *);
struct TransactionBeginRequest {
    // New direct app/helper messages use v3. Canonical v2 remains readable for
    // existing callers only when no conditional deconfiguration is attached.
    unsigned formatVersion = 3;
    ReviewedTransaction review;
    std::set<std::uint64_t> additionalActions;
    std::set<std::string> archiveWarnings;
    std::vector<AutoInstalledDelta> changes;
    std::string extendedState;
    std::shared_ptr<const TriggerEffectEnvelope> reviewedEffects;
    // One protected read-only capture supplied both DTOs and the independent
    // methods identity. This transport is not permission to deconfigure.
    std::shared_ptr<const EffectReviewBundle> reviewedDeconfiguration;
};
bool EncodeTransactionBegin(const TransactionBeginRequest &, std::string *);
bool DecodeTransactionBegin(const std::string &, TransactionBeginRequest *);
std::string TransactionBeginDigest(const TransactionBeginRequest &);
struct TransactionExecutionReply { ParentExecutionReply result; DpkgState state; };
bool EncodeTransactionExecutionReply(const TransactionExecutionReply &, std::string *);
bool DecodeTransactionExecutionReply(const std::string &, TransactionExecutionReply *);
}}
#endif
