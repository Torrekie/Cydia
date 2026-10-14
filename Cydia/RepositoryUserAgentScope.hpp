/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RepositoryUserAgentScope_HPP
#define Cydia_RepositoryUserAgentScope_HPP
#include "Cydia/RepositoryIdentity.hpp"
#include <apt-pkg/configuration.h>
#include <algorithm>
#include <cctype>
#include <vector>

namespace CydiaAPT { namespace Internal {
inline void CopyRepositoryConfiguration(const Configuration::Item *item, Configuration &copy,
        const std::string &prefix = "") {
    for (; item; item = item->Next) {
        const std::string name = prefix.empty() ? item->Tag : prefix + "::" + item->Tag;
        copy.Set(name, item->Value); CopyRepositoryConfiguration(item->Child, copy, name);
    }
}
inline void FindRepositoryUserAgentOverrides(const Configuration::Item *item,
        std::vector<std::string> &names, const std::string &prefix = "") {
    for (; item; item = item->Next) {
        const std::string name = prefix.empty() ? item->Tag : prefix + "::" + item->Tag;
        std::string lower = name;
        std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return std::tolower(c); });
        const auto acquire = lower.compare(0, 9, "acquire::") == 0 ? 0 :
            lower.compare(0, 8, "binary::") == 0 ? lower.find("::acquire::") : std::string::npos;
        const auto start = acquire == std::string::npos ? std::string::npos : acquire + (acquire == 0 ? 9 : 11);
        const auto end = start == std::string::npos ? std::string::npos : lower.find("::", start);
        const std::string method = start == std::string::npos ? "" : lower.substr(start, end - start);
        const bool http = method == "http" || method == "https";
        if (lower.size() >= 12 && lower.compare(lower.size() - 12, 12, "::user-agent") == 0 &&
            http) names.push_back(name);
        FindRepositoryUserAgentOverrides(item->Child, names, name);
    }
}
inline void ApplyRepositoryUserAgent(Configuration &configuration) {
    const std::string agent = CydiaRuntime::RepositoryDownloadUserAgent();
    if (!CydiaRuntime::ValidRepositoryUserAgent(agent)) return;
    // Host- or Binary-specific settings must not override the user's explicit
    // identity. This copy exists only for this Cydia acquisition.
    std::vector<std::string> overrides;
    FindRepositoryUserAgentOverrides(configuration.Tree(nullptr), overrides);
    for (const auto &name : overrides) configuration.Set(name, agent);
    for (const char *method : {"http", "https"})
        configuration.Set(std::string("Acquire::") + method + "::User-Agent", agent);
}
class RepositoryUserAgentScope {
    Configuration *original_;
    Configuration configuration_;
public:
    RepositoryUserAgentScope() : original_(_config) {
        CopyRepositoryConfiguration(original_->Tree(nullptr), configuration_);
        ApplyRepositoryUserAgent(configuration_); _config = &configuration_;
    }
    ~RepositoryUserAgentScope() { _config = original_; }
    RepositoryUserAgentScope(const RepositoryUserAgentScope &) = delete;
    RepositoryUserAgentScope &operator=(const RepositoryUserAgentScope &) = delete;
};
} }
#endif
