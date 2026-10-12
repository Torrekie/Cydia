/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderClient_HPP
#define Cydia_AptProviderClient_HPP
#include "Cydia/AptProviderProtocol.hpp"
#include <functional>
#include <memory>

namespace CydiaAPT { namespace Provider {
class RecoveryLaunchCapsule;

struct ProbeResult {
    Availability availability = Availability::Missing;
    Info info;
    std::string executableIdentity, registrationPath, errorCode;
    // Populated only by ProbeRecovery. Ordinary external launches must never
    // inherit this private recovery snapshot accidentally.
    std::shared_ptr<const RecoveryLaunchCapsule> recoveryCapsule;
    bool compatible() const { return availability == Availability::Ready; }
};

/* The caller selects the path from protected runtime configuration, never an
 * arbitrary PATH entry or repository data. This validates the protected path,
 * performs a bounded nonmutating --cydia-provider-info query, and rechecks the
 * executable identity. In --cydia-provider-info mode, stdin is one
 * Request/Hello frame (sequence 1) whose payload is the independently captured
 * Environment. The adapter verifies its registered paths and static identities
 * and echoes packageStateIdentity as parent-owned opaque state. It returns one
 * Response/Hello frame, sequence 1, with Info as payload. This read-only probe
 * exchange differs from the subsequent session's full Hello handshake.
 * APT's --version is never a capability declaration.
 * No server/adapter is bundled by this client implementation. A probe is not
 * an active session or authority to invoke package-manager operations.
 */
ProbeResult Probe(const std::string &executable, const Environment &expected,
    unsigned timeoutMilliseconds = 3000,
    const std::function<bool()> &cancelled = std::function<bool()>(),
    const std::string &registrationPath = std::string());

ProbeResult ProbeRecovery(const std::string &executable, const Environment &expected,
    const std::shared_ptr<const RecoveryLaunchCapsule> &capsule, unsigned timeoutMilliseconds = 3000,
    const std::function<bool()> &cancelled = std::function<bool()>());

}} // namespace CydiaAPT::Provider
#endif
