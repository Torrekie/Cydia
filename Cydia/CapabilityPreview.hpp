/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_CapabilityPreview_HPP
#define Cydia_CapabilityPreview_HPP
#include <string>
#include <vector>
namespace CydiaRuntime {
struct CapabilityCandidate {
    std::string package, version, action, reason;
    std::string providerArchitecture, providerStatus, providerVersion, providerOwner, providerPackage;
};
struct CapabilityPreview {
    std::string architecture, prefix, adminDirectory, rootDirectory, reviewToken;
    std::vector<CapabilityCandidate> changes, preserved;
};
bool ParseCapabilityPreview(const std::string &bytes, CapabilityPreview *preview);
} // namespace CydiaRuntime
#endif
