/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoveryInstalledAuthority_HPP
#define Cydia_AptRecoveryInstalledAuthority_HPP
#include "Cydia/AptRecoverySnapshot.hpp"

namespace CydiaAPT { namespace Recovery {
// The package-owned manifest lives beside the fixed installed worker at
// CydiaHelperPath("cydia-recovery.payload"). Netstring fields are:
// {"CYDIA-RECOVERY-PAYLOAD-1", libraries, dataFiles, requiredMethods}; each
// list is itself Privileged::SerializeFields. Libraries/data are absolute
// protected paths; methods are single filenames. No executable, interpreter,
// inspector hook, wildcard, environment expansion or search path is accepted.
// The manifest is itself part of the fingerprinted data inventory.
bool ParsePayloadInventory(const std::string &bytes, const std::string &workerPath,
    BundleInputs *, CydiaRuntime::Privileged::Error *);

// authenticatedUID is provided by existing cydo parent authentication, never
// decoded from the request. Paths and cache seeds are reconstructed locally.
// Production uses Cydia's read-only dependency inspector. The optional callback
// is a trusted parent injection seam, never a decoded worker/manifest hook.
bool ResolveInstalledAuthority(const CydiaRuntime::PackageDatabasePaths &, uid_t authenticatedUID,
    const Preferences &, const Identity *expected, Authority *, CydiaRuntime::Privileged::Error *,
    const DependencyInspector &inspect = DependencyInspector(), unsigned timeoutMilliseconds = 4000,
    const std::function<bool()> &cancelled = std::function<bool()>());
}} // namespace CydiaAPT::Recovery
#endif
