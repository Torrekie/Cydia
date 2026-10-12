/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoveryDependencyInspector_HPP
#define Cydia_AptRecoveryDependencyInspector_HPP
#include "Cydia/AptRecoveryAuthority.hpp"
namespace CydiaAPT { namespace Recovery {
// Cydia-owned, read-only admission of the installed payload's declared closure.
// This is not a worker probe or permission to execute dpkg. Scripts, unknown
// configured command interfaces and undeclared libraries remain unresolved.
DependencyProof InspectInstalledDependencies(const Authority &, const std::string &inventoryIdentity,
    const std::function<bool()> &cancelled);
#if defined(CYDIA_RECOVERY_DEPENDENCY_TESTING)
// Only the isolated host fixture can substitute already-parsed images. The
// production inspector always opens and hashes protected installed files.
namespace MachO { struct Image; }
DependencyProof InspectDependencyGraphForTesting(const std::map<std::string, MachO::Image> &,
    const std::vector<std::string> &roots, const std::function<bool()> &cancelled = {});
#endif
}}
#endif
