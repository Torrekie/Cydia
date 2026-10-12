/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceKeyDiscovery_HPP
#define Cydia_SourceKeyDiscovery_HPP

#include "Cydia/SourceDiscovery.hpp"

@class Database;

namespace CydiaAPT {

enum class SourceKeyDiscoveryStatus { Complete, Cancelled, TimedOut, VerifierUnavailable, NoSignedMetadata, MetadataUnavailable };
enum class SourceKeyProvenance { LocalFile, InstalledPackage, PublisherLink, Keyserver, AvailablePackage };

struct SourceSigningKeyCandidate {
    std::string publicBytes;
    std::vector<std::string> fingerprints, signerFingerprints;
    SourceKeyProvenance provenance = SourceKeyProvenance::LocalFile;
    std::string provenanceURI, package, packageVersion, packagePath;
    /* Set only for a currently installed package's protected .gpg/.asc file.
     * Use referenceBytes (the exact installed bytes) for Keyring::Input.bytes
     * together with referencePackage/referencePath. Use normalized publicBytes
     * for the isolated source preflight's candidatePublicKey. */
    std::string referencePackage, referencePath, referenceBytes;
};
struct SourceKeyDiscoveryRequest {
    std::string repositoryURI, temporaryParent;
    std::string definition;
    CydiaSources::Format format = CydiaSources::Format::OneLine;
    std::vector<std::string> sourceKeyringPaths;
    std::vector<SourcePublisherKeyLink> publisherKeys;
    unsigned timeoutSeconds = 60;
};
struct SourceKeyDiscoveryResult {
    SourceKeyDiscoveryStatus status = SourceKeyDiscoveryStatus::Complete;
    std::vector<SourceSigningKeyCandidate> candidates;
    /* Stable diagnostic codes for unavailable optional discovery providers. */
    std::vector<std::string> warnings;
    std::size_t candidatesExamined = 0, requestsPerformed = 0;
};

/* Off-main-thread, inside Database's settings gate and serialization boundary.
 * Discovery never approves trust, adds a repository, installs a package or
 * executes its scripts. Every returned keyring was normalized and matched
 * against signed metadata for every requested URI/suite. Incomplete metadata
 * or a draft exceeding the four-scope limit returns no candidates. Cancellation retains
 * no newly trusted key. Bounds: 64 local candidates, 24 package manifests,
 * eight publisher links, four full-fingerprint keyserver queries, four 4 MiB
 * package downloads and at most 16 returned candidates. */
SourceKeyDiscoveryResult DiscoverSourceSigningKeys(Database *database,
    const SourcePreflightResult &preflight, const SourceKeyDiscoveryRequest &request,
    const std::function<bool()> &cancelled = std::function<bool()>());

} // namespace CydiaAPT
#endif
