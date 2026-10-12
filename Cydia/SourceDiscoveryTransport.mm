/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDiscovery.hpp"

namespace CydiaAPT {
SourceDiscoveryResult DiscoverSourceOptions(const std::string &uri,
    const std::string &temporaryParent, const std::function<bool()> &cancelled) {
    return DiscoverSourceOptionsWithFetcher(uri, temporaryParent, FetchSourceResource, cancelled);
}
} // namespace CydiaAPT
