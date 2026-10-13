/* Native logical ownership evidence, not execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderUnpackOwnership_HPP
#define Cydia_AptProviderUnpackOwnership_HPP
#include "Cydia/AptProviderInstalledOwnership.hpp"
#include <memory>

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumUnpackOwnershipArchives = 4096;
constexpr std::size_t MaximumUnpackOwnershipSteps = 1024 * 1024;
constexpr std::size_t MaximumUnpackOwnershipBytes = 32 * 1024 * 1024;

struct UnpackOwnershipArchive {
    ReviewedAction action;
    // Parent-verified retained archive identity, not a worker filename/hash.
    std::string archiveFileIdentity, multiArch;
    std::shared_ptr<const CydiaPackages::ArchiveDataInventory> inventory;
};
enum class NativeUnpackFailureLists { Unverified, PreviousOrCompleteReplacement };
enum class NativeUnpackReplacementList { Unverified, EmptyOrRootOnly, GuaranteedMembers };
struct NativeUnpackArchiveListEvidence {
    std::uint64_t action = 0;
    std::string archive, archiveFileIdentity;
    NativeUnpackFailureLists failureLists = NativeUnpackFailureLists::Unverified;
    // Both successful and unsuccessful native outcomes introduce no list
    // names outside the previous list and this exact archive's native names.
    bool namesBoundedByPreviousAndArchive = false;
    NativeUnpackReplacementList replacement = NativeUnpackReplacementList::Unverified;
    // Exact 1-based inventory ordinals guaranteed to occur in the completed
    // replacement .list by native effective extraction/list rules. Merely
    // appearing in data.tar does NOT establish this guarantee.
    std::vector<std::uint64_t> guaranteedMembers;
};
struct NativeUnpackListEvidence {
    std::string nativeAuthorityIdentity, ownershipIdentity;
    std::vector<NativeUnpackArchiveListEvidence> archives;
};

enum class UnpackOwnershipReadiness { Ready, PotentialDisappearance, RequiresFreshBoundary, Unsupported };
enum class UnpackOwnershipError {
    None, InvalidInput, LimitExceeded, IncompleteInventory, InvalidInventory,
    UnsupportedArchitectureTransition, InconsistentListEvidence,
    NativeListContinuityMissing, SavingPathMissing
};
enum class UnpackOwnershipWitnessKind {
    CurrentTarget, MultiArchSame, AbsentNativeList, EmptyNativeList,
    RootOnlyNativeList, ParentProvenEmptyOrRootOnly, UntouchedSavingName
};
struct UnpackOwnershipWitness {
    ExecutionPackage package;
    std::uint64_t unpackAction = 0, introducedBy = 0;
    UnpackOwnershipWitnessKind kind = UnpackOwnershipWitnessKind::UntouchedSavingName;
    std::string name;
};
struct UnpackOwnershipResult {
    UnpackOwnershipReadiness readiness = UnpackOwnershipReadiness::Unsupported;
    UnpackOwnershipError error = UnpackOwnershipError::None;
    std::string ownershipIdentity, nativeAuthorityIdentity;
    // Failure identifies a potentially affected generation, never a claim
    // that dpkg definitely removes it; reverse dependencies may prevent that.
    ExecutionPackage package;
    std::uint64_t unpackAction = 0, introducedBy = 0;
    std::vector<UnpackOwnershipWitness> witnesses; // Published only for Ready.
};

// The vector is actual authorized dpkg archive operand order, NOT sorted
// action-ID order. All actions must be exact reviewed Unpack actions and all
// inventories complete and independently bound to retained verified bytes.
// Caller separately verifies queue authorization, locks, state freshness,
// selected native effect semantics, options/environment, Conflicts, triggers,
// deconfiguration and trusted maintainer-script effects.
//
// Mirrors the saving-name sufficient condition in dpkg 1.21/1.23
// archives.c::filesavespackage and unpack.c::pkg_disappear_others. It treats
// every incoming native name as potentially NEW_INARCHIVE; no filesystem
// type/existence, filter, diversion-only or reverse-dependency rescue is
// inferred. ConfigFiles packages remain third-party owners. Missing, empty
// and '/.'-only native lists remain distinct native loader cases.
//
// A batch must supply independently established parent NativeUnpackListEvidence
// for every archive before the last. dpkg archivefiles() continues after some
// earlier errors: possible previous-list and replacement-list generations
// both remain candidates. The proof is conditional on exactly these explicit
// native rules, never manufactured from a complete payload inventory.
// Unavailable rules return RequiresFreshBoundary before any child; this API
// does not split commands, retry failures, or enable mutation by itself.
// Public pure values establish no provenance. In particular these native-rule
// values must never be decoded as provider-chosen policy or approval.
UnpackOwnershipResult EvaluateUnpackOwnership(const InstalledOwnershipMetadata &,
    const std::vector<UnpackOwnershipArchive> &, const std::string &nativeArchitecture,
    const NativeUnpackListEvidence & = NativeUnpackListEvidence());
}}
#endif
