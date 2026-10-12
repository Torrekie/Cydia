/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_PackageArchivePolicy_HPP
#define Cydia_PackageArchivePolicy_HPP

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <map>
#include <string>
#include <vector>

namespace CydiaPackages {
enum class ArchivePolicyStatus { Accepted, Unverified, LayoutMismatch, Invalid, IdentityMismatch };
struct ArchiveIdentity {
    std::string package, version, architecture;
};
struct ArchiveLayout {
    /* Absolute installation prefix, supplied by runtime discovery, never
     * inferred from Architecture. Use / for an unprefixed environment. */
    std::string prefix;
    std::vector<std::string> foreignPrefixes;
};
struct ArchiveLimits {
    std::size_t maxEntries = 100000;
    std::size_t maxPathBytes = 4096;
    std::size_t maxMetadataBytes = 8 * 1024 * 1024;
    std::uint64_t maxStreamBytes = std::uint64_t(4) * 1024 * 1024 * 1024;
    std::size_t maxPayloadFiles = 4096;
};
struct ArchivePolicyResult {
    ArchivePolicyStatus status = ArchivePolicyStatus::Accepted;
    std::string path;
    /* Stable diagnostic code, suitable for a localized presentation layer. */
    std::string reason;
    bool identityVerified = false;
    bool complete = false;
};
// Canonical binary-package control semantics used by both retained Packages
// records and archive/installed control records. Input keys must be lowercase;
// continuation whitespace is permitted in relationship values. This parses no
// source build restrictions, executes nothing and selects no package version.
// Unsupported/malformed fields leave the output empty.
bool CanonicalPackageEffectControlFields(const std::map<std::string, std::string> &fields,
    std::map<std::string, std::string> *controls, std::string *error);
struct ArchiveControlMetadata {
    bool complete = false;
    ArchiveIdentity identity;
    std::map<std::string, std::string> controls;
    // Absence and an explicitly empty triggers file remain distinguishable.
    bool triggersPresent = false;
    std::string triggers, reason;
};

/* Read exactly the requested number of decoded bytes; false means failure
 * or premature EOF. Callbacks must themselves avoid unbounded buffering. */
typedef std::function<bool(void *, std::size_t)> ArchiveRead;

/* Numeric metadata from a regular data.tar member, not a prediction of its
 * installed metadata (dpkg stat overrides and maintainer scripts can change
 * that). Paths are exact normalized absolute installation paths. */
struct ArchivePayloadFileMetadata {
    std::string path;
    std::uint64_t size = 0;
    std::uint32_t mode = 0, uid = 0, gid = 0;
};
struct ArchivePayloadInspection {
    bool complete = false;
    std::string path, reason;
};
/* Consume exactly file.size bytes through the bounded read callback. It is
 * valid only during this call. A callback result is provisional until both
 * Finish() and PayloadInspection() complete; later archive members can
 * invalidate it. The inspector never extracts files or follows host links. */
typedef std::function<bool(const ArchivePayloadFileMetadata &, const ArchiveRead &)> ArchivePayloadConsumer;

/* Read-only, bounded inspection of control/data tar streams. Accepted means
 * no observed layout conflict; it is not a security or script-safety claim.
 * Unsupported tar semantics stop inspection as Unverified, never Accepted. */
class PackageArchivePolicy {
  public:
    PackageArchivePolicy(const ArchiveIdentity &expected, const ArchiveLayout &layout,
                         const ArchiveLimits &limits = ArchiveLimits());
    ~PackageArchivePolicy();
    bool ReadControlTar(const ArchiveRead &read);
    bool ReadDataTar(const ArchiveRead &read);
    bool ReadDataTar(const ArchiveRead &read, const std::vector<std::string> &paths,
                     const ArchivePayloadConsumer &consumer);
    ArchivePolicyResult Finish();
    ArchivePayloadInspection PayloadInspection() const;
    ArchiveControlMetadata ControlMetadata() const;
  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
#endif
