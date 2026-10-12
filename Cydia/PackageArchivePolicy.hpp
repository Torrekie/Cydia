/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_PackageArchivePolicy_HPP
#define Cydia_PackageArchivePolicy_HPP

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
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
};
struct ArchivePolicyResult {
    ArchivePolicyStatus status = ArchivePolicyStatus::Accepted;
    std::string path;
    /* Stable diagnostic code, suitable for a localized presentation layer. */
    std::string reason;
    bool identityVerified = false;
    bool complete = false;
};
/* Read exactly the requested number of decoded bytes; false means failure
 * or premature EOF. Callbacks must themselves avoid unbounded buffering. */
typedef std::function<bool(void *, std::size_t)> ArchiveRead;

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
    ArchivePolicyResult Finish();
  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
#endif
