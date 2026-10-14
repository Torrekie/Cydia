/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RepositoryIdentity_HPP
#define Cydia_RepositoryIdentity_HPP
#include <string>

namespace CydiaRuntime {
inline bool ValidRepositoryIdentity(const std::string &value) {
    return value == "cydia" || value == "sileo" || value == "zebra" || value == "custom";
}
inline bool ValidRepositoryUserAgent(const std::string &value) {
    if (value.empty() || value.size() > 512 || value.front() == ' ' || value.back() == ' ') return false;
    for (unsigned char character : value) if (character < 32 || character > 126) return false;
    return true;
}
// Account and repository requests share a selected identity. Zebra's released
// client deliberately uses a different acquisition UA before iOS 15.
std::string RepositoryUserAgent(const std::string &identity, const std::string &custom, bool download);
// Read the user's Cydia preference for each new native acquisition. This has
// no effect on the bootstrap's configuration or external provider protocol.
std::string RepositoryDownloadUserAgent();
}
#endif
