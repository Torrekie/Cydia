/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_TransactionResult_HPP
#define Cydia_TransactionResult_HPP
namespace CydiaRuntime {
enum class TransactionOutcome { NotStarted, Succeeded, Failed, Cancelled, Stale, Busy };
struct TransactionResult {
    TransactionOutcome outcome;
    bool packageManagerStarted;
    int launchError;
    int exitCode;
    int signal;
    TransactionResult() : outcome(TransactionOutcome::NotStarted),
        packageManagerStarted(false), launchError(0), exitCode(-1), signal(0) {}
    bool succeeded() const { return outcome == TransactionOutcome::Succeeded; }
};
}
#endif
