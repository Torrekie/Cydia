/* Finite parent-owned trigger effects; no worker claims grant authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderTriggerEffects_HPP
#define Cydia_AptProviderTriggerEffects_HPP
#include "Cydia/AptProviderDpkgState.hpp"
#include "Cydia/AptProviderTriggerEvidence.hpp"
#include "Cydia/AptProviderArchiveEvidence.hpp"

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumTriggerEffectPackages = 4096;
constexpr unsigned MaximumTriggerPassesPerCheckpoint = 32;
constexpr unsigned MaximumTriggerPassesPerTransaction = 256;

enum class TriggerDeclarationKind { Interest, Activate };
struct TriggerDeclaration {
    TriggerDeclarationKind kind = TriggerDeclarationKind::Interest;
    std::string trigger;
    bool await = true;
};
struct TriggerPackageMetadata {
    ExecutionPackage package;
    // Native control field names are lowercase. Folding whitespace is
    // normalized, but relationship alternatives/order/version syntax are kept.
    std::map<std::string, std::string> controls;
    // Installed captures retain actual protected status stanza sequence/bytes;
    // refined incoming metadata retains the actual archive sequence instead.
    // Native dump may reorder a whole database into fieldinfos order after a
    // child; neither domain is inferred from canonical map iteration.
    bool dependencyOrderVerified = false;
    std::vector<std::string> dependencyOrder;
    std::string rawControlRecord;
    // Installed-only native semantic value: Version for installed/pending,
    // otherwise the retained Config-Version (possibly empty). Never part of
    // incoming archive/index control equality.
    std::string configVersion;
    // Raw protected status-file phase, before dpkg-query incorporates deferred
    // trigger state in memory. DpkgState::status is the separate query view.
    DpkgPackageStatus diskStatus = DpkgPackageStatus::NotInstalled;
    std::vector<TriggerDeclaration> declarations;
    std::string declarationIdentity, evidenceIdentity;
};
struct InstalledTriggerMetadata {
    // Package:actual-Architecture, with exact version retained in each record.
    std::map<std::string, TriggerPackageMetadata> packages;
    std::vector<CydiaRuntime::Privileged::Evidence> files;
    std::string packageStateIdentity, evidenceIdentity;
};
struct TriggerCaptureLock {
    // Exactly one route: the calling process's retained frontend descriptor,
    // or the already-authenticated app parent checked by the helper using the
    // kernel lock owner and getppid. Never a provider-supplied assertion.
    int descriptor = -1;
    pid_t parent = 0;
};
// Shared installed-metadata capture gate. Checks the retained native lock;
// neither acquiring a new lock nor accepting a provider assertion.
bool TriggerCaptureLockHeld(const CydiaRuntime::Privileged::Environment &, const TriggerCaptureLock &);
// Parent-internal frozen transaction snapshot reader. It may map protected
// bytes to the retained lease state token; never populated from provider IPC.
// An empty function uses the normal selected RuntimeSnapshot implementation.
using TriggerStateSnapshot = std::function<bool(std::string *, std::string *)>;
// Pure parsers do not establish archive, filesystem or installed authority.
bool ParseTriggerDeclarations(const std::string &bytes, std::vector<TriggerDeclaration> *declarations,
                              std::string *error);
bool ParseInstalledTriggerControl(const std::string &status, const DpkgState &state,
                                 std::map<std::string, TriggerPackageMetadata> *packages, std::string *error);
// Captures native status and installed info/*.triggers, including absence and
// exact qualified filenames. Both candidate filenames are bound; conflicting
// unqualified/qualified controls refuse. No query or mutation is executed.
bool CaptureInstalledTriggerMetadata(const CydiaRuntime::Privileged::Environment &, const DpkgState &,
    const TriggerCaptureLock &, InstalledTriggerMetadata *, std::string *error,
    const std::function<bool()> &cancelled = std::function<bool()>(),
    const TriggerStateSnapshot &snapshot = TriggerStateSnapshot());

struct TriggerEffectCheckpoint {
    DpkgState packages; // Parent-query view, including read-only incorporation.
    ProtectedTriggerEvidence registry;
    InstalledTriggerMetadata metadata;
    std::string identity;
};
// Pure binding of already parent-captured evidence; not proof of provenance.
std::string TriggerEffectCheckpointIdentity(const TriggerEffectCheckpoint &);
// Caller first obtains fresh structured state through the selected protected
// dpkg/query. This routine binds it to the same raw state and declaration files
// before/after capture. It does not relax CaptureDpkgState's default refusal of
// nonempty Unincorp; effect-aware query integration is a separate parent route.
bool CaptureTriggerEffectCheckpoint(const CydiaRuntime::Privileged::Environment &, const DpkgState &,
    const TriggerCaptureLock &, TriggerEffectCheckpoint *, std::string *error,
    const std::function<bool()> &cancelled = std::function<bool()>(),
    const TriggerStateSnapshot &snapshot = TriggerStateSnapshot());

struct TriggerEffectEnvelope {
    std::string identity, initialCheckpoint;
    std::string nativeAuthorityIdentity;
    ReviewedTransaction primaryReview;
    // Generation keys retain version as well as architecture. Incoming exact
    // identities can be disclosed before download but remain unrefined until a
    // parent archive-control proof exists; they grant no guessed relationships.
    std::map<std::string, ExecutionPackage> recipients, awaiters;
    std::set<std::string> incoming;
};
bool BuildTriggerEffectEnvelope(const ReviewedTransaction &, const TriggerEffectCheckpoint &,
                               TriggerEffectEnvelope *, std::string *error,
                               const std::string &nativeAuthorityIdentity = {});

struct TriggerDrainPlan {
    std::string envelopeIdentity, checkpointIdentity;
    std::uint64_t pass = 0, primaryCheckpoint = 0;
    // Complete parent-derived set. Empty is meaningful only when a native
    // deferred queue must be incorporated without an interested recipient.
    std::vector<ExecutionPackage> targets;
    bool incorporateDeferred = false;
};
// Single-use effect ledger. Its pass IDs are separate from ReviewedAction IDs.
// Incoming generations require parent-verified archive/index control evidence
// before any unpack. No operation runs dpkg or substitutes for authorization
// of primary actions, frontend locks, protected file retention or native policy.
class TriggerEffectLedger {
    TriggerEffectEnvelope envelope_;
    TriggerEffectCheckpoint current_;
    TriggerDrainPlan pending_;
    AuthorizedExecution primary_;
    std::set<std::string> seenGraphs_;
    std::set<std::uint64_t> primaryActions_;
    std::map<std::string, TriggerPackageMetadata> incomingMetadata_;
    std::map<std::string, std::string> incomingArchiveIdentities_;
    std::uint64_t nextPass_ = 1, primaryCheckpoint_ = 0;
    unsigned checkpointPasses_ = 0, totalPasses_ = 0;
    bool initialized_ = false, active_ = false, uncertain_ = false;
    bool Reject(std::string *, const char *);
public:
    bool Begin(const TriggerEffectEnvelope &, const TriggerEffectCheckpoint &, std::string *error);
    // Parent-only proof from ArchiveEvidenceSnapshot::VerifyControl, after UI
    // approval of the immutable incoming recipient pool. Complete set, once,
    // before primary execution. Does not expand recipients or action IDs.
    bool RefineIncoming(const std::vector<VerifiedArchiveControlEvidence> &, std::string *error);
    // Must run before the primary child. Unrefined incoming effects are denied
    // here, never discovered only after an unpack has already changed state.
    bool PreparePrimary(const std::string &expectedCheckpoint, const AuthorizedExecution &, std::string *error);
    // After a successful, actually observed parent child: checks the ordinary
    // primary transition with the existing verifier after normalizing only
    // admitted trigger states. Primary action IDs cannot be reused. This slice
    // permits declaration replacement/removal only for exact primary targets;
    // dependency-driven deconfiguration remains unavailable.
    bool Reconcile(const AuthorizedExecution &, const ParentExecutionReply &,
                   const TriggerEffectCheckpoint &, std::string *error);
    bool NextDrain(const std::string &expectedCheckpoint, TriggerDrainPlan *, std::string *error);
    bool SettleDrain(std::uint64_t pass, const ParentExecutionReply &, const TriggerEffectCheckpoint &,
                     std::string *error);
    bool quiescent() const;
    bool active() const { return active_; }
    bool indeterminate() const { return uncertain_; }
    const std::string &stateIdentity() const { return current_.identity; }
    void Invalidate(bool executionUncertain = false);
};

}} // namespace CydiaAPT::Provider
#endif
