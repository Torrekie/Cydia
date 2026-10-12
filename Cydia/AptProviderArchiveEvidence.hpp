/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderArchiveEvidence_HPP
#define Cydia_AptProviderArchiveEvidence_HPP
#include "Cydia/AptProviderReview.hpp"
#include <memory>

namespace CydiaAPT { namespace Provider {
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
    // Rechecks the retained source/index snapshot and returns only canonical
    // relationship fields from the exact reviewed Packages record. No archive
    // is needed yet; absence of triggers cannot be inferred from this record.
    bool ControlFields(const ArchiveManifest &requested, std::map<std::string, std::string> *controls,
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
