/* Native Pre-Depends readiness evidence; never execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderPreDependsEvidence_HPP
#define Cydia_AptProviderPreDependsEvidence_HPP
#include "Cydia/AptProviderBinaryRelationships.hpp"
#include "Cydia/AptProviderTriggerEffects.hpp"

namespace CydiaAPT { namespace Provider { namespace PreDependsEvidence {
constexpr std::size_t MaximumPackages = 4096;
constexpr std::size_t MaximumSteps = 65536;
constexpr std::size_t MaximumInputBytes = 32 * 1024 * 1024;
constexpr std::size_t MaximumOutputBytes = 32 * 1024 * 1024;

enum class Readiness { Ready, Blocked, Unsupported, ComparisonFailed };
enum class Origin { Installed, Incoming };
enum class Reason {
    MissingCandidate, PhaseNotEligible, NeverConfigured,
    CurrentVersionMismatch, ConfiguredVersionMismatch, QueuedDeconfiguration
};
struct CandidateEvidence {
    BinaryRelationships::Witness match;
    Origin origin = Origin::Installed;
    DpkgPackageStatus queryStatus = DpkgPackageStatus::NotInstalled;
    DpkgPackageStatus diskStatus = DpkgPackageStatus::NotInstalled;
    std::string configVersion, metadataIdentity;
};
struct Witness {
    CandidateEvidence candidate;
    bool historicalVersionRequired = false;
};
struct Blocker {
    std::size_t group = 0, alternative = 0;
    Reason reason = Reason::MissingCandidate;
    bool hasCandidate = false;
    CandidateEvidence candidate;
};
struct GroupEvidence {
    // OR alternatives within each group, AND between groups. Blockers are
    // retained only for an unsatisfied group; they never authorize a repair.
    std::vector<Witness> witnesses;
    std::vector<Blocker> blockers;
};
struct Result {
    Readiness readiness = Readiness::Unsupported;
    BinaryRelationships::Error error;
    std::string packageStateIdentity;
    std::vector<GroupEvidence> groups;
};

// Mirrors native depisok(..., allowunconfigd=true) without client queues,
// resolver guesses, force-depends or inline TRIGPROC_REQUIRED. Installed and
// triggers-pending direct candidates use current Version. Unpacked,
// half-configured and triggers-awaited direct candidates require informative
// Config-Version and BOTH current/historical versions satisfying the same
// alternative. Installed virtual providers need installed/pending phase and
// their actual provided version; historical Config-Version cannot rescue them.
//
// exactIncoming is the single parent-retained INSTALLNEW package. Its exact
// current incoming version/Provides may satisfy self dependencies, as native
// dpkg does; the replaced installed instance's old Provides are not consulted.
// No other future incoming package is invented. Incoming/disk/query origins
// remain explicit in witnesses; no package is normalized to installed.
//
// sameChildQueuedDeconfigurations contains exact CURRENT generations already
// queued for deconfiguration by this same child. They block real/provider
// satisfaction outright (PKG_ISTOBE_DECONFIGURE), even with usable history.
// Already observed half-configured debt from a preceding child is evaluated
// through its actual phase and retained Config-Version instead. This is not
// an optional policy a worker may choose.
//
// Pure public inputs establish no provenance, lock, native-policy or command
// authority. The parent independently binds field/source to retained canonical
// archive/index controls and state/metadata to the same protected capture.
// Metadata files are not read here. Invalid/incomplete/unsupported evidence or
// exhausted bounds returns Unsupported with no partial groups. Comparator
// failure returns ComparisonFailed with no partial groups, never lexical or
// guessed-executable fallback. Blocked gives exact native candidate blockers;
// it neither runs triggers nor promises that processing them would be safe.
// Ready describes only these exact groups at the supplied evidence point;
// it is not whole-child no-inline-trigger proof after queued/native effects.
Result Evaluate(const BinaryRelationships::Field &preDepends,
    const BinaryRelationships::Package &exactIncoming, const DpkgState &actualState,
    const InstalledTriggerMetadata &retainedMetadata, const std::string &nativeArchitecture,
    const BinaryRelationships::VersionComparator &trustedNativeCompare,
    const std::vector<ExecutionPackage> &sameChildQueuedDeconfigurations = {});

}}} // namespace CydiaAPT::Provider::PreDependsEvidence
#endif
