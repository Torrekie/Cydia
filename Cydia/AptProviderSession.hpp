/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderSession_HPP
#define Cydia_AptProviderSession_HPP

#include "Cydia/AptProviderClient.hpp"
#include <memory>

namespace CydiaAPT { namespace Provider {

struct RequestControl {
    // Valid only during the callback; do not retain these closures. Parent
    // callbacks run synchronously under the caller's Database gate.
    // They must use these bounds for their own I/O. An executing dpkg must be
    // allowed to settle safely; transport cancellation never kills that child.
    std::function<bool()> cancelled;
    std::function<unsigned()> remainingMilliseconds;
};

struct SessionCallbacks {
    // Return a typed payload/error/succeeded result. The session constructs the
    // response envelope. This callback must independently authorize arguments,
    // archive identities and protected configuration; the worker is not root
    // authority. No callback means a reverse request is denied.
    std::function<void(const Message &, Message *, const RequestControl &)> parentRequest;
    std::function<void(const ProgressEvent &)> progress;
    // Called once on shutdown. The app still owns any acquired frontend lock
    // and decides how to release it after its executor has settled.
    std::function<void(bool indeterminate)> closed;
};

/* One serialized, long-lived unprivileged worker per database epoch family.
 * All methods except destruction require the same Database serialization gate;
 * callbacks must not reenter this object. Nothing auto-selects a fallback.
 * The separately packaged provider implements --cydia-provider-session over
 * framed stdin/stdout; stderr is discarded because it may contain credentials.
 * This client does not supply or install a Remorix adapter/helper.
 * Provider selection is a separate gate: merely compiling this transport does
 * not activate an external provider or replace the embedded backend.
 */
class Session {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
public:
    Session();
    ~Session();
    Session(const Session &) = delete;
    Session &operator=(const Session &) = delete;

    // Uses a successful, same-environment Probe, checks its executable identity
    // again, and replaces Hello.challenge with 256 bits from the OS RNG.
    bool Start(const std::string &executable, const ProbeResult &probe, Hello hello,
        const SessionCallbacks &callbacks = SessionCallbacks(), unsigned timeoutMilliseconds = 3000,
        const std::function<bool()> &cancelled = std::function<bool()>());

    // True means a validated response arrived; inspect reply.succeeded for an
    // operation error. Invalid input is rejected before sending. A cancellation
    // sends Cancel(target sequence), then gives the same worker at most 2 s to
    // acknowledge and settle the original response; no further reverse mutation
    // is accepted. Transport loss after a parent mutation is indeterminate.
    // Successful policy/architecture changes close the old binding and report
    // provider_reprobe_required; the caller must obtain a fresh environment.
    bool Call(Operation operation, const std::string &payload, Message *reply,
        unsigned timeoutMilliseconds = 30000,
        const std::function<bool()> &cancelled = std::function<bool()>());
    void Close();
    bool active() const;
    bool indeterminate() const;
    bool mutationStarted() const;
    // Actual executor start observed during the most recent serialized Call,
    // including a call that settled its reply while cancellation was pending.
    // Independent of historical mutation and indeterminate-outcome latches.
    bool lastCallExecutionStarted() const;
    bool parentLockHeld() const;
    const Binding &binding() const;
    const Info &info() const;
    const std::string &lastError() const;
#if defined(CYDIA_PROVIDER_SESSION_TESTING) && CYDIA_PROVIDER_SESSION_TESTING
    // Test-only transport seam. Consumes a socketpair endpoint, exercising the
    // full handshake without weakening production executable-path validation.
    bool StartConnected(int descriptor, const Info &expected, Hello hello,
        const SessionCallbacks &callbacks = SessionCallbacks(), unsigned timeoutMilliseconds = 3000,
        const std::function<bool()> &cancelled = std::function<bool()>());
#endif
};

}} // namespace CydiaAPT::Provider
#endif
