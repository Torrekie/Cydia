/* Bounded initial-generation allowances, not execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderDeconfigurationEffects_HPP
#define Cydia_AptProviderDeconfigurationEffects_HPP
#include "Cydia/AptProviderBinaryRelationships.hpp"
#include "Cydia/AptProviderInstalledScripts.hpp"

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumDeconfigurationActions = 4096;
constexpr std::size_t MaximumDeconfigurationCauses = 16384;
constexpr std::size_t MaximumDeconfigurationSteps = 65536;
constexpr std::size_t MaximumDeconfigurationInputBytes = 32 * 1024 * 1024;

// Parent-retained exact Packages record. Neither a worker map nor these public
// pure values prove index provenance. Archive controls must separately match
// before execution; scripts for future incoming generations are not admitted.
struct DeconfigurationIndexControl {
    ArchiveManifest archive;
    std::map<std::string, std::string> controls;
    std::string evidenceIdentity;
};
enum class DeconfigurationCauseKind { Breaks, SiblingVersionMismatch };
struct DeconfigurationCause {
    DeconfigurationCauseKind kind = DeconfigurationCauseKind::Breaks;
    std::uint64_t unpackAction = 0;
    std::string archive, canonicalRelation, comparedVersion;
    std::size_t group = 0, alternative = 0;
    std::size_t provide = BinaryRelationships::DirectPackage;
};
struct DeconfigurationEndpoint {
    std::uint64_t action = 0, precedingUnpack = 0;
    ExecutionAction kind = ExecutionAction::Configure;
    ExecutionPackage package;
};
struct DeconfigurationAllowance {
    ExecutionPackage installed;
    DpkgSelection selection = DpkgSelection::Unknown;
    DpkgPackageStatus initialStatus = DpkgPackageStatus::NotInstalled;
    DpkgPackageStatus diskStatus = DpkgPackageStatus::NotInstalled;
    std::string configVersion, installedControlIdentity, installedScriptsIdentity;
    std::vector<DeconfigurationCause> causes;
    DeconfigurationEndpoint endpoint;
};
struct DeconfigurationAllowanceSet {
    std::string identity, initialCheckpoint, nativeAuthorityIdentity;
    ReviewedTransaction primaryReview;
    // Exact old package:architecture@version, never a future victim generation.
    std::map<std::string, DeconfigurationAllowance> allowances;
};

// First derive the exact native capture subset, then independently capture its
// selected installed scripts. The final builder performs identical derivation.
// Multiple exact direct architecture matches remain distinct allowances;
// ambiguous direct/provider or multiple-provider witnesses refuse. Native
// batch admission must still reproduce dpkg's complete unique-conflict rules.
bool SelectDeconfigurationTargets(const ReviewedTransaction &, const TriggerEffectCheckpoint &,
    const std::vector<DeconfigurationIndexControl> &, const BinaryRelationships::VersionComparator &,
    std::vector<ExecutionPackage> *, std::string *error);

// Pure, deterministic binding only. This foundation is NOT wired to execution.
// Retain the successful result immutably, display/approve it, independently
// recapture it at Begin and revalidate each actual batch before activation.
// No IDs, commands or required operations are invented. An unused allowance
// causes no execution; runtime must enforce actual endpoint use and ordering.
// Conflicts-driven removal, Replaces disappearance, future incoming victims,
// conditional invented restoration and unsupported native relations remain
// unavailable. Their prevention is a separate prerequisite to --auto-deconfigure.
bool BuildDeconfigurationAllowances(const ReviewedTransaction &, const TriggerEffectCheckpoint &,
    const std::string &nativeAuthorityIdentity, const std::vector<DeconfigurationIndexControl> &,
    const InstalledScriptMetadata &, const BinaryRelationships::VersionComparator &,
    DeconfigurationAllowanceSet *, std::string *error);
}}
#endif
