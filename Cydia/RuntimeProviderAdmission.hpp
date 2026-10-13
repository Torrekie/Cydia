/* Read-only candidate preparation; no adoption, fallback or mutation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RuntimeProviderAdmission_HPP
#define Cydia_RuntimeProviderAdmission_HPP
#include "Cydia/AptBackend.hpp"
#include "Cydia/AptProviderProtocol.hpp"
#include <functional>
namespace CydiaAPT {
enum class RuntimeAdmissionKind { Ready, PreparationFailed, ProviderUnavailable, AuthorityChanged };
struct RuntimeAdmissionResult {
    RuntimeAdmissionKind kind = RuntimeAdmissionKind::ProviderUnavailable;
    std::vector<ErrorData> errors;
};
// A validated negative operation result or an upstream error does not prove a
// broken provider. Liveness comes from the local validated Session binding,
// never from error wording or a worker-supplied diagnostic code. The caller
// retains its existing backend until Ready and owns every adoption decision.
inline RuntimeAdmissionResult PrepareRuntimeProvider(AptBackend &backend,
    const std::function<bool()> &captureFreshAuthority) {
    RuntimeAdmissionResult result;
    Provider::Binding binding;
    const auto failed = [&]() {
        result.kind = backend.providerBinding(&binding) ? RuntimeAdmissionKind::PreparationFailed :
            RuntimeAdmissionKind::ProviderUnavailable;
        return result;
    };
    backend.discardErrors();
    if (!backend.providerBinding(&binding)) return result;
    if (!backend.providerFailure().code.empty()) {
        result.errors = backend.drainErrors(); return failed();
    }
    bool prepared = backend.loadSources();
    result.errors = backend.drainErrors();
    for (const auto &error : result.errors) prepared &= error.warning;
    if (prepared) {
        prepared = backend.openCache();
        auto errors = backend.drainErrors();
        for (const auto &error : errors) prepared &= error.warning;
        result.errors.insert(result.errors.end(), errors.begin(), errors.end());
    }
    if (!backend.providerBinding(&binding)) return result;
    if (!prepared) return failed();
    if (!captureFreshAuthority || !captureFreshAuthority()) {
        result.kind = backend.providerBinding(&binding) ? RuntimeAdmissionKind::AuthorityChanged :
            RuntimeAdmissionKind::ProviderUnavailable;
        return result;
    }
    result.kind = RuntimeAdmissionKind::Ready; return result;
}
}
#endif
