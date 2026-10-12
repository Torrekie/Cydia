/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionRequest.hpp"
#include "Cydia/AptProviderBrokerPrivileged.hpp"
namespace CydiaAPT { namespace Provider {
bool EncodeTransactionExecutionReply(const TransactionExecutionReply &value, std::string *bytes) {
    std::string result, state;
    if (!bytes || !Encode(value.result, &result) || !EncodeBrokerState(value.state, &state)) return false;
    *bytes = CydiaRuntime::Privileged::SerializeFields({"CYDIA-TRANSACTION-RESULT-1", result, state});
    return bytes->size() <= 8 * 1024 * 1024;
}
bool DecodeTransactionExecutionReply(const std::string &bytes, TransactionExecutionReply *value) {
    if (!value || bytes.size() > 8 * 1024 * 1024) return false;
    std::vector<std::string> fields; CydiaRuntime::Privileged::Error error; TransactionExecutionReply parsed;
    if (!CydiaRuntime::Privileged::ParseFields(bytes, 3, &fields, &error) || fields[0] != "CYDIA-TRANSACTION-RESULT-1" ||
        !Decode(fields[1], &parsed.result) || !DecodeBrokerState(fields[2], &parsed.state)) return false;
    *value = std::move(parsed); return true;
}
}}
