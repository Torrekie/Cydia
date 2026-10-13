/* Protected read-only native trigger review; never worker authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderTriggerCapture_HPP
#define Cydia_AptProviderTriggerCapture_HPP
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/AptProviderTriggerEffects.hpp"
#include "Cydia/AptProviderDeconfigurationEffects.hpp"

namespace CydiaAPT { namespace Provider {
struct NativeDpkgAuthority;
struct InstalledComponentEvidence;
// Pure canonical binding of independently captured native evidence. This
// hashes exact file generations and metadata; it cannot establish provenance.
std::string TriggerNativeAuthorityIdentity(const NativeDpkgAuthority &,
    const std::vector<InstalledComponentEvidence> &);
// Pure generation binding for an independently succession-authorized current
// component set. The immutable origin remains separately checked by the owner.
// This does not alter the native declaration or establish file provenance.
std::string TriggerNativeGenerationIdentity(const NativeDpkgAuthority &,
    const std::vector<InstalledComponentEvidence> &, const std::string &origin);
// The caller is existing cydo after authenticating its direct Cydia parent and
// independently resolving selected. PATH must already be the selected native
// execution PATH. No provider fields establish authority in these functions.
// Readiness checks declared configuration and actual loader closures only: it
// neither queries dpkg nor needs a frontend lock, and is not approval to run.
bool NativeTriggerEffectsReady(const CydiaRuntime::PackageDatabasePaths &, const BrokerEnvironment &,
    std::string *error, const std::function<bool()> &cancelled = {}, bool *conditionalReviewSupported = nullptr);

// Both capture routes require the real direct parent to hold lock-frontend.
// Every bounded native query rechecks its native declaration and closure. Raw
// database, registry and installed declaration evidence must remain unchanged.
// Unlike the legacy capture, a stable Unincorp is retained and joined with
// dpkg-query's read-only incorporated view; no native file is modified.
bool CaptureEffectAwareDpkgState(const CydiaRuntime::PackageDatabasePaths &, const BrokerEnvironment &,
    DpkgState *, std::string *error, const std::function<bool()> &cancelled = {});
bool CaptureReviewedTriggerEffects(const CydiaRuntime::PackageDatabasePaths &, const BrokerEnvironment &,
    const ReviewedTransaction &, TriggerEffectEnvelope *, std::string *error,
    const std::function<bool()> &cancelled = {});
constexpr unsigned MaximumDeconfigurationCaptureMilliseconds = 30000;
// Retained parent proof for native confirmation; no archive download or child
// mutation. The immutable result is neither worker authority nor permission
// to enable automatic deconfiguration. A future cydo confirmation route may
// encode allowances; Begin must independently recapture and compare them.
struct ProtectedDeconfigurationReview {
    DeconfigurationAllowanceSet allowances;
    TriggerEffectCheckpoint checkpoint;
    std::vector<VerifiedIndexControlEvidence> indexControls;
    InstalledScriptMetadata installedScripts;
    // Retains protected source/index descriptors for later archive refinement.
    // Every use must recheck them; the shared pointer is not perpetual proof.
    std::shared_ptr<const ArchiveEvidenceSnapshot> sourceSnapshot;
};
// Existing authenticated cydo only: selected is independently resolved, the
// actual direct parent retains lock-frontend and its exact review is stable.
// Uses one native authority/state generation for native comparisons (including
// cache hits), target derivation, selected prerm/postinst capture and rebuilding.
// All queries use owned frozen envp and bounded stdout/time; the whole capture
// has a shared deadline. Failure clears output and never falls back to a missing
// or invalid native declaration, embedded comparisons, or worker control data.
// No UI, Begin route, execution capability, policy readiness or helper is added.
bool CaptureReviewedDeconfiguration(const CydiaRuntime::PackageDatabasePaths &, const BrokerEnvironment &,
    const ReviewedTransaction &, std::shared_ptr<const ProtectedDeconfigurationReview> *, std::string *error,
    const std::function<bool()> &cancelled = {});
}}
#endif
