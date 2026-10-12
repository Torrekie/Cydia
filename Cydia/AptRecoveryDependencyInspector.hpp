/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoveryDependencyInspector_HPP
#define Cydia_AptRecoveryDependencyInspector_HPP
#include "Cydia/AptRecoveryAuthority.hpp"
#include "Cydia/AptProviderComponentSuccession.hpp"
namespace CydiaAPT { namespace Recovery {
// Cydia-owned, read-only admission of the installed payload's declared closure.
// This is not a worker probe or permission to execute dpkg. Scripts, unknown
// configured command interfaces and undeclared libraries remain unresolved.
DependencyProof InspectInstalledDependencies(const Authority &, const std::string &inventoryIdentity,
    const std::function<bool()> &cancelled);
// Native transaction launches reuse the installed Mach-O reader, but prohibit
// discovering unapproved dependencies. The active dyld cache UUID and target
// bind OS edges independently of the mutable distribution components.
bool CaptureTransactionPlatformIdentity(std::string *, std::string *error);
bool InspectTransactionComponentClosure(const std::string &executable,
    const std::vector<Provider::InstalledComponentEvidence> &components,
    const std::string &nativeConfigurationIdentity, const std::string &platformIdentity,
    Provider::ComponentClosureEvidence *, std::string *error,
    const std::function<bool()> &cancelled = {});
#if defined(CYDIA_NATIVE_DPKG_AUTHORITY_TESTING)
namespace MachO { struct Target; }
// Host fixture target and fixed synthetic cache generation only. The real
// protected bytes, Mach-O parser, ABI/rpath resolution and file rechecks run.
void SetTransactionTargetForTesting(const MachO::Target &);
#endif
#if defined(CYDIA_RECOVERY_DEPENDENCY_TESTING)
// Only the isolated host fixture can substitute already-parsed images. The
// production inspector always opens and hashes protected installed files.
namespace MachO { struct Image; }
DependencyProof InspectConfiguredCommandsForTesting(const std::string &configuration);
DependencyProof InspectDependencyGraphForTesting(const std::map<std::string, MachO::Image> &,
    const std::vector<std::string> &roots, const std::function<bool()> &cancelled = {});
#endif
}}
#endif
