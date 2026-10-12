/* Direct authenticated application request, distinct from worker RPC.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderTransactionRequest_HPP
#define Cydia_AptProviderTransactionRequest_HPP
#include "Cydia/AptProviderDpkgState.hpp"
namespace CydiaAPT { namespace Provider {
struct TransactionBeginRequest {
    ReviewedTransaction review;
    std::set<std::uint64_t> additionalActions;
    std::set<std::string> archiveWarnings;
    std::vector<AutoInstalledDelta> changes;
    std::string extendedState;
};
bool EncodeTransactionBegin(const TransactionBeginRequest &, std::string *);
bool DecodeTransactionBegin(const std::string &, TransactionBeginRequest *);
std::string TransactionBeginDigest(const TransactionBeginRequest &);
struct TransactionExecutionReply { ParentExecutionReply result; DpkgState state; };
bool EncodeTransactionExecutionReply(const TransactionExecutionReply &, std::string *);
bool DecodeTransactionExecutionReply(const std::string &, TransactionExecutionReply *);
}}
#endif
