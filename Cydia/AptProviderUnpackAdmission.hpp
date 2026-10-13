/* Protected parent pre-unpack capture; never provider execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderUnpackAdmission_HPP
#define Cydia_AptProviderUnpackAdmission_HPP
#include "Cydia/AptProviderTransactionFiles.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptProviderTriggerCapture.hpp"
#include "Cydia/AptProviderPreDependsEvidence.hpp"
#include "Cydia/AptProviderUnpackOwnership.hpp"
#include "Cydia/AptProviderRestorationCapture.hpp"

namespace CydiaAPT { namespace Provider {
enum class UnpackAdmissionReadiness { FactsVerified, RequiresFreshBoundary, Blocked, Unsupported };
struct AdmittedDeconfigurationCause {
    ExecutionPackage installed;
    DeconfigurationCause cause;
};
struct OrderedPreDependsEvidence {
    std::uint64_t unpackAction = 0;
    std::string archive, canonicalGroup;
    std::size_t field = 0, group = 0; // Actual field position and original comma-group ordinal.
    // Each Result evaluates one native node; its own group ordinals start at zero.
    PreDependsEvidence::Result result;
};
// Opaque result is obtained only from actual retained transaction archives,
// selected native queries, protected ownership and exact finalized launch
// inputs. FactsVerified covers only the captured relationship/ownership facts;
// it is NOT whole-child native execution/inline-trigger readiness. The
// restoration-aware trigger decision and complete transition gate still must
// pass independently. It is not serializable and grants no mutation capability.
// Owner must
// already retain an independently rebuilt and natively approved review; no
// decoded allowance DTO is accepted by this interface.
class ProtectedUnpackAdmission {
    struct Data;
    std::shared_ptr<const Data> data_;
    explicit ProtectedUnpackAdmission(std::shared_ptr<const Data>);
public:
    UnpackAdmissionReadiness readiness() const;
    const std::string &identity() const;
    const TriggerEffectCheckpoint &checkpoint() const;
    const std::vector<AdmittedDeconfigurationCause> &causes() const;
    const UnpackOwnershipResult &ownership() const;
    const std::vector<OrderedPreDependsEvidence> &orderedPreDepends() const;
    // Captured single-archive native dependency loop only: the supported
    // Matched policy has no modeled dependency bypass/hooks and every actual
    // ordered node completed, with each Pre-Depends depisok result Ready.
    // Requires a present, quiescent protected Unincorp checkpoint; excludes
    // its native startup/transitional effects. Revalidate before use. This is
    // not whole-child maintscript/restoration/trigger-transition authority.
    bool singleArchiveNativeChecksReady() const;
    // Call only after lease authorization/private archive substitution and
    // parent fd3 preparation, before PreparePrimary/actual spawn. Current is
    // an opaque fresh restoration capture authorized by the same owner's debt
    // ledger; it may reflect only previously verified native state/history.
    // This capture
    // independently repeats native queries and every physical evidence check.
    // The same owner ledger must retain the exact initially approved origin
    // and have observed every current generation after approved native unpacks.
    // Unsupported policy or relationship never becomes default native policy.
    // Without protected native list-continuity evidence, multi-archive batches
    // request a fresh boundary; they are never split, started or retried here.
    static bool Capture(const BrokerEnvironment &, const NativeDpkgAuthority &,
        const std::vector<InstalledComponentEvidence> &, const ComponentSuccession &, const TransactionArchiveStore &,
        const ProtectedDeconfigurationReview &, const RestorationDebtLedger &, const ProtectedRestorationCheckpoint &current,
        const AuthorizedExecution &,
        const std::vector<std::string> &finalArguments, int receivedStatusDescriptor,
        const TriggerCaptureLock &, std::shared_ptr<const ProtectedUnpackAdmission> *,
        std::string *error, const std::function<bool()> &cancelled = {},
        const TriggerStateSnapshot &snapshot = {});
    // Immediately before the child, recheck the retained identity, physical
    // state, lock, archive copies, native closure and policy/launch binding.
    bool Revalidate(const BrokerEnvironment &, const NativeDpkgAuthority &,
        const std::vector<InstalledComponentEvidence> &, const ComponentSuccession &, const TransactionArchiveStore &,
        const RestorationDebtLedger &, const ProtectedRestorationCheckpoint &current,
        const std::vector<std::string> &finalArguments, const TriggerCaptureLock &,
        std::string *error, const std::function<bool()> &cancelled = {},
        const TriggerStateSnapshot &snapshot = {}) const;
};
}}
#endif
