/* Cydia parent executor for a verified external APT session.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderBroker_HPP
#define Cydia_AptProviderBroker_HPP
#include "Cydia/AptProviderDpkgState.hpp"
#include "Cydia/AptProviderSelection.hpp"
#include "Cydia/AptProviderSession.hpp"
#include <memory>

namespace CydiaAPT { namespace Provider {
struct BrokerArchiveEvidence {
    std::vector<VerifiedArchiveEvidence> archives;
    std::string errorCode;
};
struct BrokerOptions {
    std::string helperPath, extendedStatesPath;
    RegistrationIdentity authority;
    ReviewPolicy policy;
    // Cydia independently resolves these against the selected source/index
    // snapshot. cydo additionally stages/rechecks the bytes before unpack.
    std::function<BrokerArchiveEvidence(const ReviewedTransaction &,
        const std::vector<ArchiveManifest> &, const RequestControl &)> archives;
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
    // Called only by the explicit native confirmation action. Copies the
    // entire manifest and approved auto-state deltas; fetching cannot renew it.
    bool Approve(const ReviewedTransaction &review, const std::vector<AutoInstalledDelta> &changes,
                 const std::set<std::uint64_t> &additionalReviewed = std::set<std::uint64_t>(),
                 const std::set<std::string> &archiveWarningsAccepted = std::set<std::string>());
    void SetStatusDescriptor(int descriptor);
    void HandleParentRequest(const Message &request, Message *reply, const RequestControl &control);
    // A successful provider result is acceptable only when this is true.
    bool complete() const;
    bool lockHeld() const;
    bool mutationStarted() const;
    const std::string &errorCode() const;
    // Transport closure/cancellation does not kill a running dpkg child. All
    // methods share Database serialization, so cleanup follows settled child I/O.
    void Invalidate();
};
}} // namespace CydiaAPT::Provider
#endif
