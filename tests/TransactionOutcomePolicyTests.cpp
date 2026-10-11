/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/TransactionOutcomePolicy.hpp"
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits.h>
#include <string>
#include <unistd.h>
#include <vector>

namespace {
void Require(bool value, const char *message) {
    if (!value) {
        std::cerr << "[transaction-outcome] FAIL: " << message << '\n';
        std::exit(1);
    }
}

const std::string originalStatus(
    "Package: example\nArchitecture: arm64\nVersion: 1.0\nStatus: install ok unpacked\n\n"
    "Package: companion\nArchitecture: arm64\nVersion: 1.0\nStatus: install ok installed\n\n");
const std::string failedConfigureStatus(
    "Package: example\nArchitecture: arm64\nVersion: 1.0\nStatus: install ok half-configured\n\n"
    "Package: companion\nArchitecture: arm64\nVersion: 1.0\nStatus: install ok installed\n\n");
const std::string partialStatus(
    "Package: example\nArchitecture: arm64\nVersion: 2.0\nStatus: install ok installed\n\n"
    "Package: companion\nArchitecture: arm64\nVersion: 2.0\nStatus: install ok half-configured\n\n");
const std::string completedStatus(
    "Package: example\nArchitecture: arm64\nVersion: 2.0\nStatus: install ok installed\n\n"
    "Package: companion\nArchitecture: arm64\nVersion: 2.0\nStatus: install ok installed\n\n");
const std::string sharedMarks("Package: unrelated\nArchitecture: arm64\nAuto-Installed: 1\nX-Owner: retained\n\n");

bool Write(const std::string &path, const std::string &bytes) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << bytes;
    file.close();
    return file.good();
}
std::string Read(const std::string &path) {
    std::ifstream file(path, std::ios::binary);
    Require(file.good(), "read fixture state");
    return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}

struct Fixture {
    std::string directory, status, extendedState;
    Fixture() {
        const char *temporary(std::getenv("TMPDIR"));
        std::string pattern(temporary == nullptr || temporary[0] == '\0' ? "/tmp" : temporary);
        if (pattern.back() != '/') pattern += '/';
        pattern += "cydia-transaction-outcome.XXXXXX";
        std::vector<char> path(pattern.begin(), pattern.end()); path.push_back('\0');
        const char *created(mkdtemp(path.data()));
        Require(created != nullptr, "create isolated transaction fixture");
        directory = created; status = directory + "/status"; extendedState = directory + "/extended_states";
        Require(Write(status, originalStatus) && Write(extendedState, sharedMarks), "seed actual state files");
    }
    ~Fixture() {
        unlink(status.c_str()); unlink(extendedState.c_str()); rmdir(directory.c_str());
    }
};

// A real child process performs isolated state writes before failing. This
// exercises the Runner/outcome boundary without invoking a host package manager.
int Child(int argc, char *argv[]) {
    if (argc != 4) return 90;
    const std::string action(argv[2]), path(argv[3]);
    if (action == "configure-fail") return Write(path, failedConfigureStatus) ? 1 : 91;
    if (action == "partial") return Write(path, partialStatus) ? 2 : 91;
    if (action == "success") return Write(path, completedStatus) ? 0 : 91;
    if (action == "zero-work-fail") return 1;
    if (action == "signal") {
        if (!Write(path, partialStatus)) return 91;
        std::signal(SIGTERM, SIG_DFL); std::raise(SIGTERM); return 92;
    }
    return 93;
}

std::string ReloadedStatus(const Fixture &fixture, const CydiaRuntime::TransactionCompletionPlan &plan) {
    Require(plan.reloadNow, "failed operations request current package state immediately");
    Require(Read(fixture.extendedState) == sharedMarks, "failed operations preserve unrelated automatic marks");
    return Read(fixture.status);
}

void Verify(const CydiaRuntime::Dpkg::Runner &runner) {
    using namespace CydiaRuntime;
    {
        Fixture fixture;
        const auto process(runner.Run({"--fixture", "configure-fail", fixture.status}));
        const auto result(ConfigureTransactionResult(process));
        const auto plan(PlanTransactionCompletion(result, false, false, true));
        Require(process.kind == Dpkg::ResultKind::Exited && process.code == 1 && result.exitCode == 1,
            "actual failed configure exit survives the transaction boundary");
        Require(!plan.succeeded && std::strcmp(plan.titleKey, "TRANSACTION_FAILED_TITLE") == 0,
            "failed configure with no emitted error text cannot display Complete");
        Require(ReloadedStatus(fixture, plan) == failedConfigureStatus,
            "reload exposes actual half-configured state despite a requested restart");
        Require(!PlanTransactionCompletion(result, true, false, true).succeeded,
            "a contradictory invocation success cannot hide the failed child result");
    }
    {
        Fixture fixture;
        Require(runner.Run({"--fixture", "partial", fixture.status}).code == 2,
            "partial fixture changes one package before the next configuration fails");
        const auto result(PackageManagerTransactionResult(CydiaAPT::PackageManagerResult::Incomplete, false));
        const auto plan(PlanTransactionCompletion(result, false, false, true));
        Require(!result.succeeded() && !plan.succeeded, "incomplete APT execution is never success");
        Require(ReloadedStatus(fixture, plan) == partialStatus,
            "partial execution retains completed work and exposes the remaining damaged package");
        Require(!PackageManagerTransactionResult(CydiaAPT::PackageManagerResult::Failed, false).succeeded(),
            "APT execution failure without queued diagnostics is still failure");
    }
    {
        Fixture fixture;
        const auto result(ConfigureTransactionResult(runner.Run({"--fixture", "zero-work-fail", fixture.status})));
        const auto plan(PlanTransactionCompletion(result, false, false, true));
        Require(!plan.succeeded && ReloadedStatus(fixture, plan) == originalStatus,
            "zero progress and unchanged state do not convert a failing exit into success");
    }
    {
        Fixture fixture;
        const auto result(ConfigureTransactionResult(runner.Run({"--fixture", "signal", fixture.status})));
        const auto plan(PlanTransactionCompletion(result, false, false, true));
        Require(result.signal == SIGTERM && result.exitCode == -1 && !plan.succeeded,
            "signal termination preserves failure details");
        Require(ReloadedStatus(fixture, plan) == partialStatus,
            "signal after partial writes requires a real-state reload");
    }
    {
        Fixture fixture;
        const Dpkg::Runner missing(fixture.directory + "/missing-dpkg");
        const auto result(ConfigureTransactionResult(missing.Run({"--configure", "-a"})));
        const auto plan(PlanTransactionCompletion(result, false, false, true));
        Require(result.launchError == ENOENT && !plan.succeeded && ReloadedStatus(fixture, plan) == originalStatus,
            "unavailable execution preserves launch failure and original state");
    }
    {
        Fixture fixture;
        const auto configured(ConfigureTransactionResult(runner.Run({"--fixture", "success", fixture.status})));
        const auto ordinary(PlanTransactionCompletion(configured, true, false, false));
        Require(ordinary.succeeded && std::strcmp(ordinary.titleKey, "COMPLETE") == 0 &&
            ordinary.reloadNow && Read(fixture.status) == completedStatus,
            "verified successful execution permits Complete and reloads installed state");
        const auto deferred(PlanTransactionCompletion(configured, true, false, true));
        Require(deferred.succeeded && !deferred.reloadNow,
            "successful restart-required work retains deferred reload");
        const auto errors(PlanTransactionCompletion(configured, true, true, true));
        Require(!errors.succeeded && ReloadedStatus(fixture, errors) == completedStatus,
            "error-bearing execution cannot hide actual completed changes behind deferred reload");
        const auto persistenceFailure(PlanTransactionCompletion(configured, false, false, true));
        Require(!persistenceFailure.succeeded && persistenceFailure.reloadNow,
            "failure after package execution remains visible and requires reload");
        Require(PackageManagerTransactionResult(CydiaAPT::PackageManagerResult::Completed, false).succeeded() &&
            !PackageManagerTransactionResult(CydiaAPT::PackageManagerResult::Completed, true).succeeded(),
            "APT completion also requires absence of execution errors");
    }
    {
        TransactionResult notStarted;
        Require(!PlanTransactionCompletion(notStarted, true, false, false).succeeded,
            "an unstarted default result never reports success");
        notStarted.outcome = TransactionOutcome::Succeeded;
        Require(!PlanTransactionCompletion(notStarted, true, false, true).succeeded,
            "a success flag without an execution attempt is insufficient");
        for (auto outcome : {TransactionOutcome::Busy, TransactionOutcome::Stale, TransactionOutcome::Cancelled}) {
            TransactionResult rejected; rejected.outcome = outcome;
            const auto plan(PlanTransactionCompletion(rejected, false, false, true));
            Require(!plan.succeeded && plan.reloadNow, "pre-execution rejection reloads authoritative state");
            Require(std::strcmp(plan.titleKey, outcome == TransactionOutcome::Cancelled ?
                "TRANSACTION_CANCELLED" : "TRANSACTION_FAILED_TITLE") == 0,
                "cancellation stays distinct from a failed or stale operation");
        }
    }
}
} // namespace

int main(int argc, char *argv[]) {
    if (argc > 1 && std::strcmp(argv[1], "--fixture") == 0) return Child(argc, argv);
    char executable[PATH_MAX];
    Require(realpath(argv[0], executable) != nullptr, "resolve spawned fixture executable");
    Verify(CydiaRuntime::Dpkg::Runner(std::string(executable)));
    std::cout << "[transaction-outcome] PASS: failed configure, partial execution and verified completion policy\n";
}
