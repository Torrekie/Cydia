/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionRequest.hpp"
#include <apt-pkg/hashes.h>
namespace CydiaAPT { namespace Provider {
std::string TransactionBeginDigest(const TransactionBeginRequest &value) {
    std::string bytes; if (!EncodeTransactionBegin(value, &bytes)) return {};
    const std::string domain(value.formatVersion == 2 ? "CYDIA-TRANSACTION-REVIEW-2" : "CYDIA-TRANSACTION-REVIEW-3");
    Hashes hashes(Hashes::SHA256SUM);
    if (!hashes.Add(domain.data(), domain.size()) || !hashes.Add(bytes.data(), bytes.size())) return {};
    return hashes.GetHashString(Hashes::SHA256SUM).HashValue();
}
}}
