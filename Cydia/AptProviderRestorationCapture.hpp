/* Protected restoration observations, not permission to deconfigure packages.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderRestorationCapture_HPP
#define Cydia_AptProviderRestorationCapture_HPP
#include "Cydia/AptProviderRestorationDebt.hpp"
#include "Cydia/AptProviderTransactionFiles.hpp"
#include <memory>
namespace CydiaAPT { namespace Provider {
// Only Capture can construct this object. It retains the complete protected
// phase-bound evidence separately from the phase/history-independent hashes
// consumed by the debt ledger. Public DTO identities never establish capture.
class ProtectedRestorationCheckpoint {
    struct Data;
    std::unique_ptr<Data> data_;
    explicit ProtectedRestorationCheckpoint(std::unique_ptr<Data>);
public:
    ~ProtectedRestorationCheckpoint();
    ProtectedRestorationCheckpoint(const ProtectedRestorationCheckpoint &) = delete;
    ProtectedRestorationCheckpoint &operator=(const ProtectedRestorationCheckpoint &) = delete;
    const RestorationCheckpoint &observation() const;
    const TriggerEffectCheckpoint &trigger() const;
    const InstalledScriptMetadata &scripts() const;
    // Parent supplies fresh selected-native query state and its frozen snapshot
    // reader. Capture itself checks the real frontend lock, native status,
    // declaration files, selected scripts and trigger registry before/after.
    // Slots come from independently approved allowances; current generation
    // comes ONLY from the fresh state. Empty/forgotten slots remain absent.
    // Versioned NotInstalled selections stay present with their real phase,
    // controls and selected-script evidence; present is not installed state.
    static bool Capture(const CydiaRuntime::Privileged::Environment &, const DpkgState &,
        const TriggerCaptureLock &, const DeconfigurationAllowanceSet &,
        std::shared_ptr<const ProtectedRestorationCheckpoint> *, std::string *error,
        const std::function<bool()> &cancelled = {}, const TriggerStateSnapshot &snapshot = {});
    friend bool VerifyRestorationSuccessors(const CydiaRuntime::Privileged::Environment &,
        const TriggerCaptureLock &, const DeconfigurationAllowanceSet &, const AuthorizedExecution &,
        const ProtectedRestorationCheckpoint &, const ProtectedRestorationCheckpoint &,
        const TransactionArchiveStore &, std::vector<RestorationSuccessorProof> *, std::string *,
        const std::function<bool()> &, const TriggerStateSnapshot &);
};
// Call after actual successful/reaped Unpack and complete fresh protected
// native/physical after capture. Produce read-only successor evidence BEFORE
// full conditional transition/trigger/debt validation, which consumes this
// proof; that final validation must precede publishing any ledger updates.
// This does not mark a child successful, settle IDs or authorize its effects.
// Uses the actual retained, rehashed TransactionArchiveStore (effect controls
// must have been captured) and opaque before/after protected captures. It
// matches exact reviewed successor actions, canonical controls/declarations,
// and installed prerm/postinst bytes/metadata. No worker policy/readiness flags.
// Fresh after-evidence and lock are rechecked around archive verification.
// Only exact preserved regular-script uid/gid/mode is supported; transformed
// extraction metadata refuses rather than guessing a tar implementation or
// umask. Full native config/loader/effect-policy proof remains the owner's job.
bool VerifyRestorationSuccessors(const CydiaRuntime::Privileged::Environment &,
    const TriggerCaptureLock &, const DeconfigurationAllowanceSet &, const AuthorizedExecution &,
    const ProtectedRestorationCheckpoint &before, const ProtectedRestorationCheckpoint &after,
    const TransactionArchiveStore &, std::vector<RestorationSuccessorProof> *, std::string *error,
    const std::function<bool()> &cancelled = {}, const TriggerStateSnapshot &snapshot = {});
}}
#endif
