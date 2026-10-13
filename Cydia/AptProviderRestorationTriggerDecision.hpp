/* Parent restoration scheduling; no native launch or execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderRestorationTriggerDecision_HPP
#define Cydia_AptProviderRestorationTriggerDecision_HPP
#include "Cydia/AptProviderRestorationDebt.hpp"
namespace CydiaAPT { namespace Provider {
enum class RestorationTriggerWork { Quiescent, Drain, Defer, Refuse };
struct RestorationTriggerDecision {
    RestorationTriggerWork work = RestorationTriggerWork::Refuse;
    std::string reason;
};
// Inputs must be the owner's exact current protected checkpoint and prepared
// debt ledger. A decision schedules only; it neither grants a primary action
// nor weakens the native per-child policy or full trigger/state gates.
// Defer means a real reviewed primary boundary must run before any triggers.
// Exact observation comparison for a fresh pre-child/final-CAS recapture;
// identities alone do not cover all selected script content fields.
bool SameRestorationCheckpoint(const RestorationCheckpoint &, const RestorationCheckpoint &);
RestorationTriggerDecision DecideRestorationTriggerWork(const DeconfigurationAllowanceSet &,
    const RestorationDebtLedger &, const TriggerEffectCheckpoint &);
}}
#endif
