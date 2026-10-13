/* Protected parent pre-unpack capture; never provider execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderUnpackAdmission_HPP
#define Cydia_AptProviderUnpackAdmission_HPP
#include "Cydia/AptProviderTransactionFiles.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptProviderTriggerCapture.hpp"
#include "Cydia/AptProviderPreDependsEvidence.hpp"
#include "Cydia/AptProviderUnpackOwnership.hpp"

namespace CydiaAPT { namespace Provider {
enum class UnpackAdmissionReadiness { FactsVerified, RequiresFreshBoundary, Blocked, Unsupported };
struct AdmittedDeconfigurationCause {
    ExecutionPackage installed;
    DeconfigurationCause cause;
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
    // Call only after lease authorization/private archive substitution and
    // parent fd3 preparation, before PreparePrimary/actual spawn. This capture
    // independently repeats native queries and every physical evidence check.
    // Unsupported policy or relationship never becomes default native policy.
    // Without protected native list-continuity evidence, multi-archive batches
    // request a fresh boundary; they are never split, started or retried here.
    static bool Capture(const BrokerEnvironment &, const NativeDpkgAuthority &,
        const std::vector<InstalledComponentEvidence> &, const TransactionArchiveStore &,
        const ProtectedDeconfigurationReview &, const AuthorizedExecution &,
        const std::vector<std::string> &finalArguments, int receivedStatusDescriptor,
        const TriggerCaptureLock &, std::shared_ptr<const ProtectedUnpackAdmission> *,
        std::string *error, const std::function<bool()> &cancelled = {},
        const TriggerStateSnapshot &snapshot = {});
    // Immediately before the child, recheck the retained identity, physical
    // state, lock, archive copies, native closure and policy/launch binding.
    bool Revalidate(const BrokerEnvironment &, const NativeDpkgAuthority &,
        const std::vector<InstalledComponentEvidence> &, const TransactionArchiveStore &,
        const std::vector<std::string> &finalArguments, const TriggerCaptureLock &,
        std::string *error, const std::function<bool()> &cancelled = {},
        const TriggerStateSnapshot &snapshot = {}) const;
};
}}
#endif
