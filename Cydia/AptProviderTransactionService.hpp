/* Authenticated service hosted only by the existing cydo executable.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderTransactionService_HPP
#define Cydia_AptProviderTransactionService_HPP
#include "Cydia/AptProviderTransactionOwner.hpp"
#include "Cydia/AptProviderTransactionRequest.hpp"
#include "Cydia/AptProviderTransactionChannel.hpp"
namespace CydiaAPT { namespace Provider {
struct TransactionServiceOptions {
    CydiaRuntime::Privileged::ApplicationProcessIdentity application;
    uid_t applicationUID = 0;
    // These callbacks come from cydo after its ordinary direct-parent code
    // authentication. No callback, executable or environment comes from wire.
    std::function<bool(CydiaRuntime::Privileged::ApplicationProcessIdentity *, uid_t *, std::string *)> authenticate;
    std::function<bool(BrokerEnvironment *, std::string *)> prepareEnvironment;
    std::function<ParentExecutionReply(const std::string &, const std::vector<std::string> &,
        int, int, const std::function<void()> &, const CydiaRuntime::NativeLaunchEnvironment &)> execute;
    unsigned nonmutatingMilliseconds = 30000;
};
// Consumes connectedSocket. Begin payload is Privileged::SerializeRequest of
// the wrapped Broker request whose inner payload is EncodeTransactionBegin.
// Capture/Close payload is empty; Execute is Encode(ParentExecutionRequest).
// Commit is Privileged::SerializeFields({baseline, Encode(ExtendedStateRequest)}).
// Explicit scoped-child negotiation requires the retained reviewedEffects
// approval. Both primary and trigger children then acquire independent channel
// pairs, and must acknowledge settlement/release before another scope opens.
// Bounded admission/capture; once mutation starts it is always waited/reaped.
// Transport loss invalidates the lease and never authorizes a retry.
bool ServeProviderTransaction(int connectedSocket, const CydiaRuntime::PackageDatabasePaths &,
    const TransactionServiceOptions &, std::string *error);
}}
#endif
