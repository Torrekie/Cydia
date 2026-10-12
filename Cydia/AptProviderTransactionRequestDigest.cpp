/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionRequest.hpp"
#include <apt-pkg/hashes.h>
namespace CydiaAPT { namespace Provider {
std::string TransactionBeginDigest(const TransactionBeginRequest &value) {
    std::string bytes; if (!EncodeTransactionBegin(value, &bytes)) return {};
    const char domain[] = "CYDIA-TRANSACTION-REVIEW-1";
    Hashes hashes(Hashes::SHA256SUM);
    if (!hashes.Add(domain, sizeof(domain)-1) || !hashes.Add(bytes.data(), bytes.size())) return {};
    return hashes.GetHashString(Hashes::SHA256SUM).HashValue();
}
}}
