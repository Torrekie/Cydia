/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderConffilePolicy.hpp"
#include <algorithm>
namespace CydiaAPT { namespace Provider {
namespace N = NativeEffectPolicy;
namespace D = CydiaRuntime::Dpkg;
namespace {
bool Digest(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
bool Budget(const std::vector<std::string> &arguments) {
    if (arguments.size() > 100000) return false;
    std::size_t bytes = 0;
    for (const auto &argument : arguments) {
        if (argument.size() > 1024 * 1024 - bytes || argument.find('\0') != std::string::npos) return false;
        bytes += argument.size();
    }
    return true;
}
}
D::ConffileInputPolicy ConffilePolicyForMatch(const N::Match &match, const std::string &profile) {
    if (profile != "dpkg-1.23.7-effects-1" || match.status != N::Status::Matched || !match.settings || !match.settings->unmodeledOptions.empty())
        return D::ConffileInputPolicy::Unverified;
    const auto &forces = match.settings->forces;
    const auto has = [&](N::Force force) { return std::find(forces.begin(), forces.end(), force) != forces.end(); };
    if (has(N::Force::Confnew) || has(N::Force::Confold)) return D::ConffileInputPolicy::Automatic;
    if (has(N::Force::Confdef)) return D::ConffileInputPolicy::Automatic;
    return D::ConffileInputPolicy::Interactive;
}
bool ValidConffilePolicyDecision(const ConffilePolicyDecision &value) {
    if (static_cast<unsigned>(value.match) > static_cast<unsigned>(N::Status::Invalid) ||
        !Digest(value.inputIdentity) || !Digest(value.launchIdentity)) return false;
    if (value.match == N::Status::Matched)
        return Digest(value.recordIdentity) && (value.input == D::ConffileInputPolicy::Interactive ||
            value.input == D::ConffileInputPolicy::Automatic || value.input == D::ConffileInputPolicy::DefaultUnknown);
    return value.recordIdentity.empty() && value.input == D::ConffileInputPolicy::Unverified;
}
bool FinalizeNativeChildArguments(const std::vector<std::string> &arguments, std::size_t prefix,
    std::size_t index, int descriptor, std::vector<std::string> *output) {
    if (!output) return false;
    // Alias-safe: inspect everything before clearing/copying the output.
    if (!Budget(arguments) || descriptor < 3 || prefix > arguments.size() || index >= prefix) { output->clear(); return false; }
    const bool separate = arguments[index] == "--status-fd";
    if (separate ? (index + 1 >= prefix || arguments[index + 1] != std::to_string(descriptor)) :
        arguments[index] != "--status-fd=" + std::to_string(descriptor)) { output->clear(); return false; }
    auto result = arguments;
    if (separate) result[index + 1] = "3";
    else result[index] = "--status-fd=3";
    *output = std::move(result); return true;
}
bool ValidFinalNativeChildArguments(const std::vector<std::string> &arguments, std::size_t index) {
    if (!Budget(arguments) || index >= arguments.size()) return false;
    return arguments[index] == "--status-fd=3" || (arguments[index] == "--status-fd" &&
        index + 1 < arguments.size() && arguments[index + 1] == "3");
}
}}
