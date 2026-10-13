/* Cydia parent executor for a verified external APT session.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderBroker_HPP
#define Cydia_AptProviderBroker_HPP
#include "Cydia/AptProviderDpkgState.hpp"
#include "Cydia/AptProviderSelection.hpp"
#include "Cydia/AptProviderSession.hpp"
#include "Cydia/AptRecoverySnapshot.hpp"
#include "Cydia/AptProviderTriggerEffects.hpp"
#include "Cydia/AptProviderEffectReviewBundle.hpp"
#include <memory>

namespace CydiaAPT { namespace Provider {
struct BrokerArchiveEvidence {
    std::vector<VerifiedArchiveEvidence> archives;
    std::string errorCode;
};
struct BrokerOptions {
    std::string helperPath, extendedStatesPath;
    RegistrationIdentity authority;
    // Exactly one authority kind is permitted. Recovery is not an external
    // registration and never borrows its provider/configuration identity.
    std::shared_ptr<const Recovery::RequestAuthority> recoveryAuthority;
    std::uint64_t capabilities = 0;
    bool finiteTriggerEffects = false; // Accepted immutable session mode, not support alone.
    // Internal Cydia selector, never a provider capability/boolean or user
    // setting. Install only after complete parent-owned native admission and
    // settlement gates exist. It selects capture; Owner must independently
    // prove every execution gate. Empty preserves the ordinary existing flow.
    std::function<bool(const ReviewedTransaction &, std::string *)> deconfigurationReadiness;
    ReviewPolicy policy;
    // Cydia independently resolves these against the selected source/index
    // snapshot. cydo additionally stages/rechecks the bytes before unpack.
    std::function<BrokerArchiveEvidence(const ReviewedTransaction &,
        const std::vector<ArchiveManifest> &, const RequestControl &)> archives;
    // Rechecks retained parent source/index proof, then calls the native account
    // service. Never derive credentials or an account identity from worker data.
    std::function<ArchiveAuthorizationReply(const ArchiveManifest &, const RequestControl &)> authorizeArchive;
};

class Broker {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
public:
    explicit Broker(const BrokerOptions &options);
    ~Broker();
    Broker(const Broker &) = delete;
    Broker &operator=(const Broker &) = delete;
    // Call once after Session::Start supplies the cryptographic session nonce.
    bool BindSession(const Binding &binding);
    // Read-only parent capture while the preparation frontend lock is held.
    // The worker never proposes the recipient pool or its approval identity.
    bool CaptureEffects(const ReviewedTransaction &, std::shared_ptr<const TriggerEffectEnvelope> *, std::string *,
        std::shared_ptr<const EffectReviewBundle> *deconfiguration = nullptr);
    // Called only by the explicit native confirmation action. Copies the
    // entire manifest and approved auto-state deltas; fetching cannot renew it.
    bool Approve(const ReviewedTransaction &review, const std::vector<AutoInstalledDelta> &changes,
                 const std::set<std::uint64_t> &additionalReviewed = std::set<std::uint64_t>(),
                 const std::set<std::string> &archiveWarningsAccepted = std::set<std::string>(),
                 const std::shared_ptr<const TriggerEffectEnvelope> &effects = {},
                 const std::shared_ptr<const EffectReviewBundle> &deconfiguration = {});
    void SetStatusDescriptor(int descriptor);
    void HandleParentRequest(const Message &request, Message *reply, const RequestControl &control);
    // A successful provider result is acceptable only when this is true.
    bool complete() const;
    bool lockHeld() const;
    bool mutationStarted() const;
    bool indeterminate() const;
    const std::string &errorCode() const;
    // Transport closure/cancellation does not kill a running dpkg child. All
    // methods share Database serialization, so cleanup follows settled child I/O.
    void Invalidate();
};
}} // namespace CydiaAPT::Provider
#endif
