/* Protected native ownership metadata, not permission to replace files.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderInstalledOwnership_HPP
#define Cydia_AptProviderInstalledOwnership_HPP
#include "Cydia/AptProviderTriggerEffects.hpp"

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumOwnershipFileBytes = 4 * 1024 * 1024;
constexpr std::size_t MaximumOwnershipStatusBytes = 8 * 1024 * 1024;
constexpr std::size_t MaximumOwnershipBytes = 32 * 1024 * 1024;
constexpr std::size_t MaximumOwnershipPackages = 4096;
constexpr std::size_t MaximumOwnershipPaths = 262144;
constexpr std::size_t MaximumOwnershipPathBytes = 4096;
constexpr std::size_t MaximumOwnershipDiversions = 16384;
constexpr std::size_t MaximumOwnershipReaderGroups = 1024;

enum class InstalledOwnershipErrorCode {
    None, InvalidInput, LimitExceeded, Cancelled, FrontendLockMissing,
    StateChanged, Unavailable, UnsafeInput, UnsupportedFormat,
    UnsupportedPath, MalformedList, MalformedDiversions, ConflictingDiversions
};
struct InstalledOwnershipError {
    InstalledOwnershipErrorCode code = InstalledOwnershipErrorCode::None;
    std::string path; // Evidence path or offending raw pathname, never a command.
};
struct InstalledDiversion {
    std::string original, diverted, package;
    bool local = false; // Native ':' owner; package is empty only in this case.
};
struct InstalledPackageOwnership {
    ExecutionPackage package;
    DpkgSelection selection = DpkgSelection::Unknown;
    DpkgPackageStatus status = DpkgPackageStatus::NotInstalled;
    DpkgPackageStatus diskStatus = DpkgPackageStatus::NotInstalled;
    bool reinstallRequired = false;
    std::string configVersion, multiArch, controlIdentity, evidenceIdentity;
    // ConfigFiles owners still participate in sharing but cannot themselves
    // disappear. Eligibility does not claim a nonempty or complete file list.
    bool disappearanceEligible = false;
    CydiaRuntime::Privileged::Evidence list;
    // Native database names in order, with only dpkg's single trailing slash
    // removal. '/.' is a distinct native sentinel; no filesystem types follow
    // from these names. Duplicates are retained, not invented ownership edges.
    std::vector<std::string> paths;
};
struct InstalledOwnershipMetadata {
    bool complete = false; // Complete capture, not a no-disappearance proof.
    unsigned infoFormat = 0;
    std::map<std::string, InstalledPackageOwnership> packages; // name:actual arch
    CydiaRuntime::Privileged::Evidence diversions;
    std::vector<InstalledDiversion> diversionRecords;
    // Unique native input paths: status, info identity, format/migration,
    // both candidate .list names, and diversions including absence.
    std::vector<CydiaRuntime::Privileged::Evidence> files;
    std::string packageStateIdentity, evidenceIdentity;
};

// Supported subset of dpkg db-fsys-files.c/db-fsys-divert.c syntax. Raw bytes
// remain in the capture. Absolute canonical byte paths and '/.' are supported;
// ambiguous relative/dot/repeated-slash forms refuse instead of guessing.
// Missing final newlines, control bytes and conflicting diversion endpoints
// refuse atomically. Parsing alone proves no installed state or provenance.
bool ParseInstalledOwnershipList(const std::string &, std::vector<std::string> *, InstalledOwnershipError *);
bool ParseInstalledOwnershipDiversions(const std::string &, std::vector<InstalledDiversion> *, InstalledOwnershipError *);

// Read-only root capture under the actual retained frontend lock. Targets are
// derived from fresh protected native status, never supplied by a worker.
// Captures every non-NotInstalled owner (including ConfigFiles for sharing).
// Missing lists are retained as absent; they are not repaired or represented
// as known-empty ownership. An empty eligible set still captures the database
// and diversions and produces an explicit complete empty result.
// Protected parent aliases may be used; symlink/hardlink file leaves refuse.
// No package paths are joined to a layout root or inspected on disk here.
bool CaptureInstalledOwnership(const CydiaRuntime::Privileged::Environment &, const DpkgState &,
    const TriggerCaptureLock &, InstalledOwnershipMetadata *, InstalledOwnershipError *,
    const std::function<bool()> &cancelled = {}, const TriggerStateSnapshot &snapshot = {});
}}
#endif
