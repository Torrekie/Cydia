/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_TransactionOutcomePolicy_HPP
#define Cydia_TransactionOutcomePolicy_HPP

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/TransactionResult.hpp"

namespace CydiaRuntime {

inline TransactionResult ConfigureTransactionResult(const Dpkg::Result &process) {
    TransactionResult result;
    // Once execution is attempted, conservatively reload even if launching or
    // waiting failed: absence of a success result does not prove no changes.
    result.packageManagerStarted = true;
    result.launchError = process.error;
    if (process.kind == Dpkg::ResultKind::Exited) result.exitCode = process.code;
    if (process.kind == Dpkg::ResultKind::Signaled) result.signal = process.code;
    result.outcome = process.kind == Dpkg::ResultKind::Exited && process.code == 0 && process.error == 0 ?
        TransactionOutcome::Succeeded : TransactionOutcome::Failed;
    return result;
}

inline TransactionResult PackageManagerTransactionResult(CydiaAPT::PackageManagerResult execution,
                                                         bool containsErrors) {
    TransactionResult result;
    result.packageManagerStarted = true;
    result.outcome = execution == CydiaAPT::PackageManagerResult::Completed && !containsErrors ?
        TransactionOutcome::Succeeded : TransactionOutcome::Failed;
    return result;
}

struct TransactionCompletionPlan {
    bool succeeded;
    bool reloadNow;
    const char *titleKey;
};

inline TransactionCompletionPlan PlanTransactionCompletion(const TransactionResult &result,
    bool invocationSucceeded, bool containsErrors, bool restartRequired) {
    const bool succeeded = invocationSucceeded && !containsErrors && result.succeeded() &&
        result.packageManagerStarted && result.launchError == 0 && result.signal == 0 &&
        (result.exitCode == -1 || result.exitCode == 0);
    // A failed/partial operation must expose actual dpkg state before the user
    // retries, even if a maintscript requested a restart. Only successful work
    // may retain the existing deferred-reload behavior around that restart.
    return {succeeded, !restartRequired || !succeeded,
        succeeded ? "COMPLETE" : result.outcome == TransactionOutcome::Cancelled ?
            "TRANSACTION_CANCELLED" : "TRANSACTION_FAILED_TITLE"};
}

} // namespace CydiaRuntime

#endif
