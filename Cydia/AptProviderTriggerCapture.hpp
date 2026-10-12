/* Protected read-only native trigger review; never worker authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderTriggerCapture_HPP
#define Cydia_AptProviderTriggerCapture_HPP
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/AptProviderTriggerEffects.hpp"

namespace CydiaAPT { namespace Provider {
struct NativeDpkgAuthority;
struct InstalledComponentEvidence;
// Pure canonical binding of independently captured native evidence. This
// hashes exact file generations and metadata; it cannot establish provenance.
std::string TriggerNativeAuthorityIdentity(const NativeDpkgAuthority &,
    const std::vector<InstalledComponentEvidence> &);
// The caller is existing cydo after authenticating its direct Cydia parent and
// independently resolving selected. PATH must already be the selected native
// execution PATH. No provider fields establish authority in these functions.
// Readiness checks declared configuration and actual loader closures only: it
// neither queries dpkg nor needs a frontend lock, and is not approval to run.
bool NativeTriggerEffectsReady(const CydiaRuntime::PackageDatabasePaths &, const BrokerEnvironment &,
    std::string *error, const std::function<bool()> &cancelled = {});

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
}}
#endif
