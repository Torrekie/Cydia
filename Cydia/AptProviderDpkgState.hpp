/* Parent-owned dpkg evidence. These types never cross the provider wire.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderDpkgState_HPP
#define Cydia_AptProviderDpkgState_HPP
#include "Cydia/AptProviderReview.hpp"
#include <functional>

namespace CydiaAPT { namespace Provider {

enum class DpkgSelection { Unknown, Install, Hold, Deinstall, Purge };
enum class DpkgPackageStatus {
    NotInstalled, ConfigFiles, HalfInstalled, Unpacked, HalfConfigured,
    TriggersAwaited, TriggersPending, Installed
};
struct DpkgPackageState {
    ExecutionPackage package;
    DpkgSelection selection = DpkgSelection::Unknown;
    DpkgPackageStatus status = DpkgPackageStatus::NotInstalled;
    bool reinstallRequired = false;
    std::string multiArch;
    std::vector<std::string> triggersPending, triggersAwaited;
};
struct DpkgState {
    // RuntimeSnapshot from the same protected environment, captured before and
    // after the read-only queries while this process owns lock-frontend.
    std::string packageStateIdentity, nativeArchitecture;
    std::vector<std::string> registeredArchitectures;
    // Keys are Package:Architecture, retaining actual Architecture: all.
    // Forgotten metadata may leave a not-installed selection with key name:.
    std::map<std::string, DpkgPackageState> packages;
};

// Stable dpkg-query fields, not -l output or localized diagnostic messages.
const char *DpkgStateQueryFormat();
bool ParseDpkgState(const std::string &queryOutput, const std::string &nativeOutput,
                    const std::string &foreignOutput, const std::string &snapshotIdentity,
                    DpkgState *state, std::string *error);

// Production capture. The caller supplies its retained descriptor from
// PrivilegedClient::OpenLock, never a worker-provided descriptor. This reasserts
// its nonblocking write lock and does not close/reopen the lock inode. Keep the
// fd until the transaction is settled. A pending dpkg update journal rejects.
// Does not acquire dpkg's inner lock or run a mutation/repair command.
bool CaptureDpkgState(const CydiaRuntime::Privileged::Environment &environment,
                     int frontendLockDescriptor, DpkgState *state, std::string *error,
                     const std::function<bool()> &cancelled = std::function<bool()>());

// Exact pending selectors from dpkg's structured state. No APT selection or
// worker claim is substituted for dpkg's wanted/status fields.
bool DpkgPendingTargets(const DpkgState &state, ExecutionAction action,
                        std::vector<ExecutionPackage> *targets, std::string *error);

// Fills only state-derived evidence, preserving the parent's binding, lock,
// status fd and independently verified archives. A nonzero fresh identity is
// not itself a lock or file-validation proof. Bare names are included only
// when all recorded instances make the result unambiguous.
// Implicit trigger execution and auto-deconfiguration cannot be predicted
// from status alone and reject. Explicit triggers also require further local
// trigger-dependency evidence; this implementation does not guess it.
bool ApplyDpkgStateEvidence(const DpkgState &state, const ReviewedTransaction &review,
                            const ParentExecutionRequest &request,
                            ParentExecutionEvidence *evidence, std::string *error);

// Observe only after a successful parent dpkg child exit. Verifies exact
// identities and permitted end states for the already authorized action IDs;
// unrelated selection/version/state/trigger changes reject. It does not prove
// filesystem effects of trusted maintainer scripts. Unknown trigger effects,
// deconfiguration, changed architectures and incomplete end states reject.
// On false, invalidate the review; never retry an already-started batch.
bool VerifyDpkgStateTransition(const DpkgState &before, const DpkgState &after,
                              const ReviewedTransaction &review,
                              const AuthorizedExecution &batch, std::string *error);

}} // namespace CydiaAPT::Provider
#endif
