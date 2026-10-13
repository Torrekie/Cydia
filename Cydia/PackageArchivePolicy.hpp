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
// The native dpkg dependency chain appends nonempty relationship fields in
// control-record encounter order, then comma groups and alternatives in their
// existing canonical order. The six retained fields include Provides because
// unpack checks reverse Conflicts at that point. Other relationship types are
// ignored by unpack; policy fields are not dependency-chain entries.
// Input order comes only from a record parser, never map iteration. This API
// derives/validates data; it proves no native profile, provenance or readiness.
bool PackageEffectControlFieldOrder(const std::map<std::string, std::string> &canonicalControls,
    const std::vector<std::string> &encounteredFieldNames, std::vector<std::string> *order, std::string *error);
bool ValidPackageEffectControlFieldOrder(const std::map<std::string, std::string> &canonicalControls,
    const std::vector<std::string> &order);
// dpkg 1.23.7 dump.c writes fields in fieldinfos order, which can differ from
// the incoming control record. This pure profile-specific expected sequence
// grants no assertion that a selected binary follows that profile.
bool Dpkg1237WrittenPackageEffectControlFieldOrder(const std::map<std::string, std::string> &canonicalControls,
    std::vector<std::string> *order);

struct ArchiveMaintainerScript {
    // Control-tar evidence only. It predicts neither the installed inode nor
    // ownership after dpkg overrides or maintainer scripts have run.
    bool present = false;
    std::string bytes;
    std::uint32_t mode = 0, uid = 0, gid = 0;
};
struct ArchiveControlMetadata {
    bool complete = false;
    ArchiveIdentity identity;
    std::map<std::string, std::string> controls;
    // Captured from these exact DEBIAN/control bytes only after full archive
    // verification. Index record order is independent and must never replace
    // this actual native INSTALLNEW sequence. Complete with no relationships
    // has verified=true and an empty order.
    bool dependencyOrderVerified = false;
    std::vector<std::string> dependencyOrder;
    std::string rawControlRecord;
    // Absence and an explicitly empty triggers file remain distinguishable.
    bool triggersPresent = false;
    std::string triggers, reason;
    ArchiveMaintainerScript prerm, postinst;
};

struct ArchiveDataInventoryEntry {
    // dpkg fsys name, not a layout-normalized path. In particular, /. and /
    // remain distinct. The inspector refuses ambiguous interior dot/slash
    // spellings instead of silently normalizing them for ownership proofs.
    std::string name;
    // Tar extractor dispatch: regular '0', hardlink '1', symlink '2', directory
    // '5'. A legacy regular member ending in '/' dispatches as a directory.
    char type = '0';
    // Original header type (NUL regular normalized to '0'). Native dpkg passes
    // this unchanged to tarobject even for legacy directory dispatch. A
    // type/headerType mismatch does not prove installed-directory semantics
    // and must be refused by ownership admission until separately supported.
    char headerType = '0';
    // Original link text; hardlinkTarget is its native fsys name for type '1'
    // only. Symlink text is never resolved into an installed ownership name.
    std::string link, hardlinkTarget;
    // One-based data-member order; GNU long-name/link headers are not members.
    std::uint64_t ordinal = 0;
};
struct ArchiveDataInventory {
    // A complete empty data tar is distinct from an unrequested/incomplete
    // inventory. No partial entries or identity are published on failure.
    bool complete = false;
    ArchiveIdentity identity;
    std::vector<ArchiveDataInventoryEntry> entries;
    std::string path, reason;
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
    bool ReadDataTarWithInventory(const ArchiveRead &read);
    bool ReadDataTar(const ArchiveRead &read, const std::vector<std::string> &paths,
                     const ArchivePayloadConsumer &consumer);
    ArchivePolicyResult Finish();
    ArchivePayloadInspection PayloadInspection() const;
    ArchiveControlMetadata ControlMetadata() const;
    // Provisional until Finish succeeds. This is an ordered archive inventory,
    // not proof that dpkg will list/install every member: native filters,
    // diversions and other filesystem policy require separate parent evidence.
    ArchiveDataInventory DataInventory() const;
  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
#endif
