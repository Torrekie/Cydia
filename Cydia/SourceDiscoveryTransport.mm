/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDiscovery.hpp"
#include "Cydia/AptBackend.hpp"

namespace CydiaAPT {
SourceDiscoveryResult DiscoverSourceOptions(AptBackend &backend, const std::string &uri,
    const std::string &temporaryParent, const std::function<bool()> &cancelled) {
    return DiscoverSourceOptionsWithFetcher(uri, temporaryParent,
        [&backend](const SourceResourceRequest &request, const std::function<bool()> &stop) {
            return backend.sourceResource(request, stop);
        }, cancelled);
}
} // namespace CydiaAPT
