/* Parent-native conffile input suppression; no execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderConffilePolicy_HPP
#define Cydia_AptProviderConffilePolicy_HPP
#include "Cydia/DpkgConffile.hpp"
#include "Cydia/AptProviderNativeEffectPolicy.hpp"
namespace CydiaAPT { namespace Provider {
struct NativeDpkgAuthority;
struct InstalledComponentEvidence;
struct ConffilePolicyDecision {
    NativeEffectPolicy::Status match = NativeEffectPolicy::Status::Invalid;
    CydiaRuntime::Dpkg::ConffileInputPolicy input = CydiaRuntime::Dpkg::ConffileInputPolicy::Unverified;
    std::string inputIdentity, recordIdentity, launchIdentity;
};
// Exact show_prompt semantics from dpkg-1.23.7 src/main/configure.c:120-151.
// These flags are a projection of freshly matched complete native force state.
// The exact supported profile only emits CFO_PROMPT_KEEP (table at80-84 and
// all call paths at430-473), so confdef is automatic too. Unknown profiles
// cannot infer this from user/distro edit flags or the generic status record.
CydiaRuntime::Dpkg::ConffileInputPolicy ConffilePolicyForMatch(const NativeEffectPolicy::Match &, const std::string &semanticProfile);
bool ValidConffilePolicyDecision(const ConffilePolicyDecision &);
// The parent parser supplied these indices. No token scanning, option arity
// inference, worker permission or native policy parsing occurs here.
bool FinalizeNativeChildArguments(const std::vector<std::string> &, std::size_t optionPrefixSize,
    std::size_t statusOptionIndex, int receivedStatusDescriptor, std::vector<std::string> *);
bool ValidFinalNativeChildArguments(const std::vector<std::string> &, std::size_t statusOptionIndex);
// Protected fresh graph/components + exact parent-final argv/env. Missing or
// unmodeled assertions yield Unverified, never a guessed interactive policy.
// False denotes failed authority/binding and must prevent child launch.
bool CaptureConffilePolicy(const NativeDpkgAuthority &, const std::string &executable,
    const std::vector<InstalledComponentEvidence> &, NativeEffectPolicy::Role,
    const std::vector<std::string> &finalArguments, std::size_t optionPrefixSize,
    ConffilePolicyDecision *, std::string *, const std::function<bool()> &cancelled = {});
}}
#endif
