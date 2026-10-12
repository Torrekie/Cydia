/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionRequest.hpp"
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/ExtendedState.hpp"

namespace CydiaAPT { namespace Provider {
namespace {
bool Valid(const TransactionBeginRequest &value) {
    Message bound; bound.operation = Operation::RunPackageManager; bound.binding = value.review.binding;
    if (!ValidRequestBinding(bound) || value.changes.size() > MaximumCollectionItems ||
        value.additionalActions.size() > MaximumCollectionItems || value.archiveWarnings.size() > MaximumCollectionItems ||
        value.extendedState.size() > 4 * 1024 * 1024) return false;
    std::set<std::string> packages;
    for (const auto &change : value.changes) {
        if (!CydiaRuntime::ValidPackageName(change.package) || !CydiaRuntime::ValidArchitectureName(change.architecture) ||
            change.architecture == "any" || change.architecture == "native" ||
            !packages.insert(change.package + ':' + change.architecture).second) return false;
    }
    for (auto id : value.additionalActions) if (!id) return false;
    for (const auto &id : value.archiveWarnings) if (!ValidIdentityToken(id)) return false;
    return true;
}
}
bool EncodeTransactionBegin(const TransactionBeginRequest &value, std::string *bytes) {
    if (!bytes || !Valid(value)) return false;
    Writer writer;
    if (!writer(std::string("CYDIA-TRANSACTION-BEGIN-1"), value.review, value.additionalActions,
        value.archiveWarnings, value.changes, value.extendedState) || writer.result().size() > 8 * 1024 * 1024) return false;
    *bytes = writer.result(); return true;
}
bool DecodeTransactionBegin(const std::string &bytes, TransactionBeginRequest *value) {
    if (!value || bytes.size() > 8 * 1024 * 1024) return false;
    Reader reader(bytes); TransactionBeginRequest parsed; std::string version;
    if (!reader(version, parsed.review, parsed.additionalActions, parsed.archiveWarnings,
        parsed.changes, parsed.extendedState) || !reader.complete() || version != "CYDIA-TRANSACTION-BEGIN-1" ||
        !Valid(parsed)) return false;
    std::string canonical;
    if (!EncodeTransactionBegin(parsed, &canonical) || canonical != bytes) return false;
    *value = std::move(parsed); return true;
}
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
