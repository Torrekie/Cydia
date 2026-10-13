/* Pure parent projections; no capture, native-policy proof or execution.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderConditionalDeconfiguration_HPP
#define Cydia_AptProviderConditionalDeconfiguration_HPP
#include "Cydia/AptProviderRestorationDebt.hpp"

namespace CydiaAPT { namespace Provider {
struct ConditionalDeconfigurationCauseObservation {
    ExecutionPackage installed;
    DeconfigurationCause cause;
};
// Project only from a fresh opaque protected pre-unpack admission that passed
// the complete parent native-policy/ordered-field/ownership/Pre-Depends gate.
// It records actual queued causes, not the larger Begin allowance pool. Each
// old generation appears at most once; native sibling queuing precedes the
// field loop independently of auto-deconfigure. Breaks is projected only when
// the opaque producer matched effective native auto-deconfigure and no forced
// Breaks bypass; raw argv alone is not that policy (config/environment apply).
// These public values never replace the opaque producer or its immediate
// recheck, and must never be decoded from provider requests.
struct ConditionalDeconfigurationAdmission {
    std::string approvalIdentity, checkpointIdentity, stateIdentity;
    std::uint64_t batch = 0;
    std::vector<std::uint64_t> actions;
    std::vector<ConditionalDeconfigurationCauseObservation> causes;
};
bool ValidateConditionalDeconfigurationAdmission(const DeconfigurationAllowanceSet &,
    const AuthorizedExecution &, const DpkgState &, const std::string &expectedCheckpoint,
    const ConditionalDeconfigurationAdmission &, std::string *error);

// Parent supplies actual successful/reaped child result, fresh opaque
// protected before/after restoration captures, and successor proofs obtained
// by comparing actual retained archives to installed controls/scripts. Shape
// or digest validation here never establishes that provenance. Full trigger
// graph, component succession, native policy and final CAS remain independent
// mandatory owner gates. Failed/cancelled/uncertain children cannot settle.
struct ConditionalDeconfigurationTransition {
    ConditionalDeconfigurationAdmission admission;
    RestorationCheckpoint before, after;
    RestorationChildResult child;
    std::vector<RestorationSuccessorProof> successors;
};
// Checks a COPY of the already prepared ledger and exact complete state
// projection. Caller must settle its real ledger only after every full-state
// gate passes; failure must invalidate real authority without consuming IDs or
// retrying a started child. Returned slots are only the closed approval slots,
// and are published atomically after validation, never normalized phases.
bool ValidateConditionalDeconfigurationTransition(const DpkgState &, const DpkgState &,
    const ReviewedTransaction &, const AuthorizedExecution &, const DeconfigurationAllowanceSet &,
    const RestorationDebtLedger &prepared, const ConditionalDeconfigurationTransition &,
    std::set<std::string> *restorationSlots, std::string *error);
}}
#endif
