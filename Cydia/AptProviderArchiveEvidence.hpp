/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderArchiveEvidence_HPP
#define Cydia_AptProviderArchiveEvidence_HPP
#include "Cydia/AptProviderReview.hpp"
#include <memory>

namespace CydiaAPT { namespace Provider {
/* Parent-owned source/index evidence prepared off-main before presenting the
 * native transaction review. Decoder executables are resolved only from the
 * independently protected registration's tool path. No provider or embedded
 * resolver result constitutes this evidence. Keep the snapshot through the
 * confirmation and execution; a source/index change requires a new review. */
class ArchiveEvidenceSnapshot {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
    ArchiveEvidenceSnapshot();
public:
    ~ArchiveEvidenceSnapshot();
    ArchiveEvidenceSnapshot(const ArchiveEvidenceSnapshot &) = delete;
    ArchiveEvidenceSnapshot &operator=(const ArchiveEvidenceSnapshot &) = delete;
    static std::shared_ptr<ArchiveEvidenceSnapshot> Capture(const RuntimeDescriptor &runtime,
        const ReviewedTransaction &review, const std::string &protectedExecutableSearchPath,
        const std::function<bool()> &cancelled, std::string *error);
    bool Verify(const std::vector<ArchiveManifest> &requested,
        std::vector<VerifiedArchiveEvidence> *evidence,
        const std::function<bool()> &cancelled, std::string *error) const;
};
}} // namespace CydiaAPT::Provider
#endif
