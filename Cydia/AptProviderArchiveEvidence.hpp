/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderArchiveEvidence_HPP
#define Cydia_AptProviderArchiveEvidence_HPP
#include "Cydia/AptProviderReview.hpp"
#include "Cydia/AptBackend.hpp"
#include <memory>

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumIndexControlRecords = 4096;
constexpr std::size_t MaximumIndexControlBytes = 32 * 1024 * 1024;
// A parent-retained Packages record and its provenance, not archive contents or
// native execution authority. Scripts and trigger declarations require a
// separate inspection of the downloaded archive.
struct VerifiedIndexControlEvidence {
    ArchiveManifest archive;
    std::map<std::string, std::string> controls;
    // Exact retained Packages stanza and its nonempty effect-field sequence.
    // This binds index provenance; it does NOT assert the archive's native
    // INSTALLNEW field order. Compare canonical index/archive semantics while
    // keeping both independently captured orders and raw records distinct.
    bool dependencyOrderVerified = false;
    std::vector<std::string> dependencyOrder;
    std::string rawControlRecord;
    std::string evidenceIdentity;
};
struct VerifiedArchiveControlEvidence {
    VerifiedArchiveEvidence archive;
    CydiaPackages::ArchiveControlMetadata control;
};
/* Parent-owned source/index evidence prepared off-main before presenting the
 * native transaction review. Decoder executables are resolved only from the
 * independently protected registration's tool path. No provider or embedded
 * resolver result constitutes this evidence. Keep the snapshot through the
 * confirmation and execution; a source/index change requires a new review. */
class ArchiveEvidenceSnapshot {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
    ArchiveEvidenceSnapshot();
    bool VerifyImpl(const std::vector<ArchiveManifest> &, std::vector<VerifiedArchiveEvidence> *,
        std::vector<VerifiedArchiveControlEvidence> *, const std::function<bool()> &, std::string *) const;
public:
    ~ArchiveEvidenceSnapshot();
    ArchiveEvidenceSnapshot(const ArchiveEvidenceSnapshot &) = delete;
    ArchiveEvidenceSnapshot &operator=(const ArchiveEvidenceSnapshot &) = delete;
    static std::shared_ptr<ArchiveEvidenceSnapshot> Capture(const RuntimeDescriptor &runtime,
        const ReviewedTransaction &review, const std::string &protectedExecutableSearchPath,
        const std::function<bool()> &cancelled, std::string *error);
    // Before a download, recheck retained source/index evidence and derive the
    // account request from those exact records. No archive file is needed yet.
    bool AuthorizationRequest(const ArchiveManifest &requested,
        CydiaRuntime::RepositoryArchiveAuthorizationRequest *request, bool *commercial,
        const std::function<bool()> &cancelled, std::string *error) const;
    // Parent-only pre-confirmation account rows. Source/commercial identity
    // comes from retained indexes; already verified local bytes need no login.
    bool RepositoryAccessRequests(const ReviewedTransaction &review,
        std::vector<RepositoryArchiveAccessRequest> *requests,
        const std::function<bool()> &cancelled, std::string *error) const;
    // Rechecks the retained source/index snapshot and returns only canonical
    // relationship fields from the exact reviewed Packages record. No archive
    // is needed yet; absence of triggers cannot be inferred from this record.
    bool ControlFields(const ArchiveManifest &requested, std::map<std::string, std::string> *controls,
        const std::function<bool()> &cancelled, std::string *error) const;
    // Atomic, bounded batch of exact, distinct reviewed manifests. Each
    // referenced index is hashed once for the entire batch; the retained source
    // snapshot and index identities are checked again before publication.
    // Output preserves request order, while each identity is independent of
    // that order/subset and binds the full manifest, canonical controls and
    // retained source/index provenance. The byte limit covers encoded
    // manifests, canonical controls, ordered fields, raw records and identity
    // strings together. No archive is needed.
    bool ControlEvidence(const std::vector<ArchiveManifest> &requested,
        std::vector<VerifiedIndexControlEvidence> *evidence,
        const std::function<bool()> &cancelled, std::string *error) const;
    // Same archive hash/identity proof as Verify plus an independent archive
    // control/index match. Captured trigger bytes remain unparsed declarations;
    // the trigger effects owner must validate their semantics before admission.
    bool VerifyControl(const std::vector<ArchiveManifest> &requested,
        std::vector<VerifiedArchiveControlEvidence> *evidence,
        const std::function<bool()> &cancelled, std::string *error) const;
    bool Verify(const std::vector<ArchiveManifest> &requested,
        std::vector<VerifiedArchiveEvidence> *evidence,
        const std::function<bool()> &cancelled, std::string *error) const;
};
}} // namespace CydiaAPT::Provider
#endif
