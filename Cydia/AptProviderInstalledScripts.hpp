/* Protected, parent-selected installed maintainer-script evidence.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderInstalledScripts_HPP
#define Cydia_AptProviderInstalledScripts_HPP
#include "Cydia/AptProviderTriggerEffects.hpp"

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumInstalledScriptBytes = 1024 * 1024;
constexpr std::size_t MaximumInstalledScriptsBytes = 16 * 1024 * 1024;
struct InstalledPackageScripts {
    ExecutionPackage package;
    std::string configVersion;
    DpkgPackageStatus diskStatus = DpkgPackageStatus::NotInstalled;
    // A missing file and a present empty file are distinct. Identity includes
    // native path, protected stat metadata and exact bytes; nothing is run.
    CydiaRuntime::Privileged::Evidence prerm, postinst;
    std::string evidenceIdentity;
};
struct InstalledScriptMetadata {
    std::map<std::string, InstalledPackageScripts> packages; // name:actual arch
    // Also binds status, info/format, migration absence and both possible
    // names of each selected script, including unused-name absence.
    std::vector<CydiaRuntime::Privileged::Evidence> files;
    std::string packageStateIdentity, evidenceIdentity;
};
// Library-only native capture. The parent derives exactTargets independently;
// no worker selector or assertion is authority. Nonempty selection requires
// root, the actual retained frontend lock and a fresh protected query state.
// Unknown/duplicate/generation-mismatched targets refuse atomically. Format0
// uses bare names; format1 qualifies Multi-Arch:same names. Conflicting names,
// symlink/hardlink leaves and metadata migrations refuse. Empty selection is a
// no-op and leaves output empty, so existing trigger capture gains no scripts.
bool CaptureInstalledScripts(const CydiaRuntime::Privileged::Environment &, const DpkgState &,
    const TriggerCaptureLock &, const std::vector<ExecutionPackage> &exactTargets,
    InstalledScriptMetadata *, std::string *error,
    const std::function<bool()> &cancelled = std::function<bool()>(),
    const TriggerStateSnapshot &snapshot = TriggerStateSnapshot());
}} // namespace CydiaAPT::Provider
#endif
