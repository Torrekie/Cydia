/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RuntimeProviderCoordinator_HPP
#define Cydia_RuntimeProviderCoordinator_HPP
#include "Cydia/AptBackend.hpp"
#include "Cydia/AptProviderSelection.hpp"
#include "Cydia/RuntimeProviderStatus.h"
#include <memory>

namespace CydiaAPT {
// Called before Database is created. This records recovery options without
// initializing embedded APT or allowing its defaults to select an external runtime.
void ConfigureRuntimeProviderStartup(const InitializationOptions &options);

class RuntimeProviderCoordinator {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
public:
    RuntimeProviderCoordinator();
    ~RuntimeProviderCoordinator();
    // Database owns the serialization gate and has invalidated all UI handles.
    // On a failed explicit change an existing runtime is left intact. Automatic
    // startup fallback occurs only here, never during an operation or retry.
    bool Select(AptBackend **backend, AcquireStatus &status, NSString *preference,
        NSString *securityPreference, bool allowRecovery, NSString **diagnostic, bool explicitRequest = false);
    CydiaRuntimeProviderStatus *Status() const;
    bool external() const;
    // Both a distribution adapter and the bundled recovery worker require
    // parent-reviewed execution. Only external() implies distro-owned policy.
    bool remote() const;
    bool healthy() const;
    bool ready() const;
    bool indeterminate() const;
    bool AcceptOpenedCache(const AptBackend &backend);
    // Captures before presenting the confirmation sheet. Confirm only approves
    // this retained value; a later worker reply cannot renew user approval.
    bool CaptureReview(AptBackend &backend, TransactionData *transaction, std::string *error);
    bool ApproveReview(AptBackend &backend, const std::set<std::uint64_t> &shownActions,
        const std::set<std::string> &shownArchiveWarnings, std::string *error);
    bool ReviewUnchanged(const AptBackend &backend) const;
    void InvalidateReview();
    bool executionComplete() const;
    const Provider::ReviewedTransaction *review() const;
};
}
#endif
