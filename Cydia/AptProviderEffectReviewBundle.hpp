/* Read-only paired native approval transport; never execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderEffectReviewBundle_HPP
#define Cydia_AptProviderEffectReviewBundle_HPP
#include "Cydia/AptProviderDeconfigurationApproval.hpp"
#include "Cydia/AptProviderTransactionRequest.hpp"

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumEffectReviewBundleBytes = 8 * 1024 * 1024;
// Protected capture has its own thirty-second shared deadline. The direct
// helper allowance also covers authority resolution, snapshots and framing.
constexpr unsigned MinimumEffectReviewCaptureMilliseconds = 35000;
constexpr unsigned MaximumEffectReviewCaptureMilliseconds = 45000;
struct EffectReviewCaptureRequest {
    ReviewedTransaction review;
    // Binding has no methods field; carry the selected independent method
    // identity explicitly and compare it with resolved authority in cydo.
    std::string methodsIdentity;
};
struct EffectReviewBundle {
    std::string methodsIdentity;
    TriggerEffectEnvelope triggers;
    DeconfigurationAllowanceSet deconfiguration;
};
// Exact review, initial checkpoint and native authority must agree. Canonical
// DTO framing neither recomputes native proof nor enables any capability.
// No scripts, protected file contents or capture pointers cross this interface.
// Failures clear output; the combined frame, not just each member, is bounded.
bool EncodeEffectReviewCaptureRequest(const EffectReviewCaptureRequest &, std::string *, std::string *error = nullptr);
bool DecodeEffectReviewCaptureRequest(const std::string &, EffectReviewCaptureRequest *, std::string *error = nullptr);
bool EncodeEffectReviewBundle(const EffectReviewBundle &, std::string *, std::string *error = nullptr);
bool DecodeEffectReviewBundle(const std::string &, EffectReviewBundle *, std::string *error = nullptr);
bool EffectReviewBundleMatches(const EffectReviewBundle &, const ReviewedTransaction &,
    const std::string &methodsIdentity, std::string *error = nullptr);
}}
#endif
