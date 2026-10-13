/* Bounded primary-native relationship readiness; no execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderPrimaryReadiness_HPP
#define Cydia_AptProviderPrimaryReadiness_HPP
#include "Cydia/AptProviderBinaryRelationships.hpp"
#include "Cydia/AptProviderTriggerEffects.hpp"
namespace CydiaAPT { namespace Provider {
enum class PrimaryReadiness { Ready, Blocked, Unsupported, ComparisonFailed };
struct PrimaryRelationshipObservation {
    ExecutionPackage source;
    BinaryRelationships::Kind kind = BinaryRelationships::Kind::Depends;
    std::string canonical;
    BinaryRelationships::Evaluation matches;
};
struct PrimaryReadinessResult {
    PrimaryReadiness readiness = PrimaryReadiness::Unsupported;
    std::string checkpointIdentity, reason;
    std::vector<PrimaryRelationshipObservation> relationships;
};
// Caller binds this pure projection to a protected complete checkpoint, exact
// selected-native comparator and matched no-extra-effects policy immediately
// before spawn. No unconfigured/awaited candidate is treated as Installed;
// cycles/forcing/deferred repair are outside this simple-case admission.
// Remove/Purge conservatively require all remaining configured dependencies
// of recorded Unpacked-or-later packages to be immediately satisfied without
// the removed generation. This can refuse a preexisting unrelated breakage.
PrimaryReadinessResult EvaluatePrimaryRelationshipReadiness(const TriggerEffectCheckpoint &,
    ExecutionAction, const std::vector<ExecutionPackage> &targets,
    const BinaryRelationships::VersionComparator &);
}}
#endif
