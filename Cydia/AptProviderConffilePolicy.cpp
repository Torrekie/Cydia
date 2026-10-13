/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderConffilePolicy.hpp"
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include <apt-pkg/hashes.h>
namespace CydiaAPT { namespace Provider {
bool CaptureConffilePolicy(const NativeDpkgAuthority &authority, const std::string &executable,
    const std::vector<InstalledComponentEvidence> &components, NativeEffectPolicy::Role role,
    const std::vector<std::string> &arguments, std::size_t prefixSize,
    ConffilePolicyDecision *output, std::string *error, const std::function<bool()> &cancelled) {
    namespace N = NativeEffectPolicy;
    if (!output) return false;
    *output = ConffilePolicyDecision();
    if (prefixSize > arguments.size() || prefixSize > N::MaximumItems) {
        if (error) *error = "provider_native_effect_policy_invalid";
        return false;
    }
    const std::vector<std::string> prefix(arguments.begin(), arguments.begin() + prefixSize);
    N::Inputs inputs;
    if (!BuildNativeEffectPolicyInputs(authority, executable, components, "dpkg-1.23.7-effects-1",
        role, prefix, &inputs, error, cancelled)) return false;
    const N::SHA256 sha = [](const std::string &bytes) {
        Hashes hash(Hashes::SHA256SUM);
        return hash.Add(bytes.data(), bytes.size()) ? hash.GetHashString(Hashes::SHA256SUM).HashValue() : "";
    };
    auto match = N::MatchRecord(authority.effectRecords, inputs, sha);
    if (authority.effectRecordState == NativeEffectRecordState::Invalid) {
        match = N::Match(); match.error = authority.effectRecordError;
    }
    ConffilePolicyDecision value; value.match = match.status; value.input = ConffilePolicyForMatch(match, inputs.semanticProfile);
    value.recordIdentity = match.recordIdentity;
    if (!N::InputIdentity(inputs, sha, &value.inputIdentity) || !N::LaunchIdentity(inputs, arguments, sha, &value.launchIdentity) ||
        !ValidConffilePolicyDecision(value) || (cancelled && cancelled())) {
        if (error) *error = "provider_native_effect_policy_invalid";
        return false;
    }
    *output = std::move(value);
    if (error) error->clear();
    return true;
}
}}
