/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_PackageArchiveReader_HPP
#define Cydia_PackageArchiveReader_HPP
#include "Cydia/PackageArchivePolicy.hpp"
#include <map>

namespace CydiaPackages {
/* Uses the active APT compressor configuration. The caller serializes APT
 * access and supplies the exact queued archive identity and selected layout.
 * No files are extracted and no package scripts are executed. Archive hash
 * verification and ensuring this is the file subsequently given to dpkg
 * remain the acquisition/transaction owner's responsibility. */
ArchivePolicyResult InspectPackageArchive(const std::string &path,
                                         const ArchiveIdentity &expected,
                                         const ArchiveLayout &layout,
                                         const ArchiveLimits &limits = ArchiveLimits());
/* Provider-parent proof uses only these independently selected decoder paths,
 * never the embedded APT compressor configuration. Keys are gzip, bzip2, xz,
 * lzma, lz4 and zstd; values are verified absolute executable paths. */
ArchivePolicyResult InspectPackageArchiveWithDecoders(const std::string &path,
    const ArchiveIdentity &expected, const ArchiveLayout &layout,
    const std::map<std::string, std::string> &decoders,
    const ArchiveLimits &limits = ArchiveLimits(),
    const std::function<bool()> &cancelled = std::function<bool()>());
/* Missing optional tools are omitted: uncompressed/gzip archives remain
 * inspectable. Malformed search paths fail; no PATH lookup or shell is used. */
bool ResolveTrustedArchiveDecoders(const std::string &protectedSearchPath,
    std::map<std::string, std::string> *decoders, std::string *error);

struct ArchivePayloadFileEvidence {
    ArchivePayloadFileMetadata metadata;
    std::string sha256;
};
struct ArchivePayloadEvidence {
    ArchivePolicyResult archive;
    ArchivePayloadInspection payload;
    /* All or nothing: populated only after the complete archive, compressed
     * trailers and requested regular members have been checked. */
    std::map<std::string, ArchivePayloadFileEvidence> files;
};
/* Bounded read-only evidence for potential protected-component successors.
 * Requested paths must be distinct, normalized absolute file paths. Links,
 * link ancestors and hardlink aliases of requested files are refused. The
 * caller must retain the approved archive bytes (for example a protected
 * transaction copy), verify its acquisition hash, and independently verify
 * post-dpkg paths/metadata/loader closure before authorizing any successor
 * (including host symlinks, diversions, conffiles and stat overrides).
 * This does not authorize execution, extraction or a runtime identity change.
 * Complete payload evidence can coexist with an ordinary archive-policy
 * warning, which the caller must handle through its existing review policy. */
ArchivePayloadEvidence InspectPackageArchivePayloadWithDecoders(const std::string &path,
    const ArchiveIdentity &expected, const ArchiveLayout &layout,
    const std::vector<std::string> &paths, const std::map<std::string, std::string> &decoders,
    const ArchiveLimits &limits = ArchiveLimits(),
    const std::function<bool()> &cancelled = std::function<bool()>());
}
#endif
