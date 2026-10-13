/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderEffectReviewBundle.hpp"

namespace CydiaAPT { namespace Provider {
namespace {
const char CaptureTag[] = "CYDIA-EFFECT-REVIEW-CAPTURE-1";
const char BundleTag[] = "CYDIA-EFFECT-REVIEW-BUNDLE-1";
bool Fail(std::string *error, const char *code = "provider_effect_review_invalid") {
    if (error) *error = code;
    return false;
}
bool Review(const ReviewedTransaction &review, std::string *bytes) {
    Message bound; bound.sequence = 1; bound.operation = Operation::RunPackageManager; bound.binding = review.binding;
    return ValidRequestBinding(bound) && !review.execution.actions.empty() &&
        review.execution.actions.size() <= MaximumDeconfigurationActions &&
        review.execution.archives.size() <= MaximumDeconfigurationActions && Encode(review, bytes) &&
        bytes->size() <= MaximumEffectReviewBundleBytes;
}
bool Pair(const EffectReviewBundle &bundle, std::string *triggers, std::string *deconfiguration, std::string *error) {
    std::string first, second;
    if (!ValidIdentityToken(bundle.methodsIdentity) ||
        bundle.triggers.initialCheckpoint != bundle.deconfiguration.initialCheckpoint ||
        bundle.triggers.nativeAuthorityIdentity != bundle.deconfiguration.nativeAuthorityIdentity ||
        !Review(bundle.triggers.primaryReview, &first) || !Review(bundle.deconfiguration.primaryReview, &second) || first != second ||
        !EncodeTriggerEffectEnvelope(bundle.triggers, triggers) ||
        !EncodeDeconfigurationApproval(bundle.deconfiguration, deconfiguration, error)) return Fail(error);
    // Avoid allocating an oversized outer frame even if both standalone
    // encoders individually accepted a value close to their own byte ceiling.
    if (triggers->size() > MaximumEffectReviewBundleBytes ||
        deconfiguration->size() > MaximumEffectReviewBundleBytes - triggers->size())
        return Fail(error, "provider_effect_review_too_large");
    return true;
}
}
bool EncodeEffectReviewCaptureRequest(const EffectReviewCaptureRequest &value, std::string *bytes, std::string *error) {
    if (error) error->clear();
    if (!bytes) return Fail(error);
    bytes->clear(); std::string review;
    if (!ValidIdentityToken(value.methodsIdentity) || !Review(value.review, &review)) return Fail(error);
    Writer writer;
    if (!writer(std::string(CaptureTag), value.methodsIdentity, review) || writer.result().size() > MaximumEffectReviewBundleBytes)
        return Fail(error, "provider_effect_review_too_large");
    *bytes = writer.result(); return true;
}
bool DecodeEffectReviewCaptureRequest(const std::string &bytes, EffectReviewCaptureRequest *value, std::string *error) {
    if (error) error->clear();
    if (!value) return Fail(error);
    *value = EffectReviewCaptureRequest();
    if (bytes.size() > MaximumEffectReviewBundleBytes) return Fail(error, "provider_effect_review_too_large");
    Reader reader(bytes); EffectReviewCaptureRequest parsed; std::string tag, review, canonical;
    if (!reader(tag, parsed.methodsIdentity, review) || !reader.complete() || tag != CaptureTag ||
        !Decode(review, &parsed.review) || !EncodeEffectReviewCaptureRequest(parsed, &canonical, error) || canonical != bytes)
        return Fail(error);
    *value = std::move(parsed); return true;
}
bool EncodeEffectReviewBundle(const EffectReviewBundle &value, std::string *bytes, std::string *error) {
    if (error) error->clear();
    if (!bytes) return Fail(error);
    bytes->clear(); std::string triggers, deconfiguration;
    if (!Pair(value, &triggers, &deconfiguration, error)) return false;
    Writer writer;
    if (!writer(std::string(BundleTag), value.methodsIdentity, triggers, deconfiguration) ||
        writer.result().size() > MaximumEffectReviewBundleBytes) return Fail(error, "provider_effect_review_too_large");
    *bytes = writer.result(); return true;
}
bool DecodeEffectReviewBundle(const std::string &bytes, EffectReviewBundle *value, std::string *error) {
    if (error) error->clear();
    if (!value) return Fail(error);
    *value = EffectReviewBundle();
    if (bytes.size() > MaximumEffectReviewBundleBytes) return Fail(error, "provider_effect_review_too_large");
    Reader reader(bytes); EffectReviewBundle parsed; std::string tag, triggers, deconfiguration, canonical;
    if (!reader(tag, parsed.methodsIdentity, triggers, deconfiguration) || !reader.complete() || tag != BundleTag ||
        !DecodeTriggerEffectEnvelope(triggers, &parsed.triggers) ||
        !DecodeDeconfigurationApproval(deconfiguration, &parsed.deconfiguration, error) ||
        !EncodeEffectReviewBundle(parsed, &canonical, error) || canonical != bytes) return Fail(error);
    *value = std::move(parsed); return true;
}
bool EffectReviewBundleMatches(const EffectReviewBundle &value, const ReviewedTransaction &review,
    const std::string &methodsIdentity, std::string *error) {
    if (error) error->clear();
    std::string first, second, canonical;
    if (!EncodeEffectReviewBundle(value, &canonical, error)) return false;
    if (value.methodsIdentity != methodsIdentity || !Review(review, &first) ||
        !Review(value.deconfiguration.primaryReview, &second) || first != second)
        return Fail(error, "provider_effect_review_changed");
    return true;
}
}}
