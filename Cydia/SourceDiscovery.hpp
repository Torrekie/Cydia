/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceDiscovery_HPP
#define Cydia_SourceDiscovery_HPP

#include "Cydia/SourcePreflight.hpp"

namespace CydiaAPT {
class AptBackend;

struct DiscoveredSourceSuite {
    std::string suitePath; // The published path, never Release's Suite/Codename.
    std::vector<std::string> components, architectures;
    std::string origin, label, metadataURI;
    bool clearSigned = false;
    /* Discovery never authenticates metadata, even when it is clear-signed.
     * These are advertised options; preflight must validate the selection. */
};

struct SourcePublisherKeyLink {
    std::string uri, label; // A publisher-linked candidate, never approved trust.
};

struct SourceDiscoveryWarning {
    std::string code; // Stable UI identifier; discovery remains best effort.
    std::string uri;
    SourceCheckStatus status = SourceCheckStatus::Unavailable;
};

struct SourceDiscoveryResult {
    SourceCheckStatus status = SourceCheckStatus::Complete;
    bool discoveryUnavailable = true;
    bool flatMetadataAvailable = false;
    std::vector<DiscoveredSourceSuite> suites;
    std::vector<SourcePublisherKeyLink> keyLinks;
    std::vector<SourceDiscoveryWarning> warnings;
    std::size_t requestsPerformed = 0;
};

/* Off-main-thread while holding the same serialization/settings gates as
 * FetchSourceResource. Only bounded, same-origin published links beneath the
 * supplied repository root are followed. No guessed suites or configuration
 * writes. Missing/hidden listings are not evidence that a source is invalid.
 * Limits: 64 requests, four suite path levels, 60 seconds, 2 MiB per response. */
SourceDiscoveryResult DiscoverSourceOptions(AptBackend &backend, const std::string &uri,
    const std::string &temporaryParent,
    const std::function<bool()> &cancelled = std::function<bool()>());

typedef std::function<SourceResourceResult(const SourceResourceRequest &,
    const std::function<bool()> &)> SourceDiscoveryFetcher;

/* Deterministic transport injection for parser/budget tests. Production uses
 * the selected backend's nonredirecting, bounded raw-resource fetcher. */
SourceDiscoveryResult DiscoverSourceOptionsWithFetcher(const std::string &uri,
    const std::string &temporaryParent, const SourceDiscoveryFetcher &fetch,
    const std::function<bool()> &cancelled = std::function<bool()>());

} // namespace CydiaAPT
#endif
