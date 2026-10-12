/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderArchiveAuthorization_HPP
#define Cydia_AptProviderArchiveAuthorization_HPP
#include "Cydia/AptProviderServer.hpp"
namespace CydiaAPT { namespace Provider {
// Install lexically around the worker's RunFetcher only. The live context must
// outlive this scope; it must not be used by asynchronous work. Construction
// does not advertise capability or activate a worker. No credential store is
// linked here and every grant remains subject to normal archive verification.
class ScopedWorkerArchiveAuthorization {
    CydiaRuntime::ScopedRepositoryArchiveAuthorizationHandler scope_;
public:
    ScopedWorkerArchiveAuthorization(const ReviewedTransaction &review,
        const ServerRequestContext &context, std::uint64_t negotiatedCapabilities);
    ScopedWorkerArchiveAuthorization(const ScopedWorkerArchiveAuthorization &) = delete;
    ScopedWorkerArchiveAuthorization &operator=(const ScopedWorkerArchiveAuthorization &) = delete;
};
}} // namespace CydiaAPT::Provider
#endif
