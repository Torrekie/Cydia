/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RepositoryTrustProof.hpp"
#include <cstdlib>
#include <iostream>

static void Require(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "[repository-trust-proof] " << message << '\n';
    std::exit(1);
}

int main() {
    const std::string context(64, 'a'), indexes(64, 'b');
    const std::string changedContext(64, 'c'), changedIndexes(64, 'd');
    CydiaRuntime::RepositoryTrustProof proof;
    Require(!proof.Matches(context, indexes), "a cold launch must not trust cached indexes");
    Require(!proof.RecordCompletedRefresh(context, context, indexes, false),
        "partial acquisition must not establish proof");
    Require(!proof.RecordCompletedRefresh(context, changedContext, indexes, true),
        "trust inputs changed during acquisition must not establish proof");
    Require(!proof.RecordCompletedRefresh("invalid", "invalid", indexes, true),
        "failed protected snapshot must not establish proof");
    Require(!proof.RecordCompletedRefresh(context, context, "", true),
        "failed local index snapshot must not establish proof");
    Require(proof.RecordCompletedRefresh(context, context, indexes, true) &&
        proof.Matches(context, indexes), "complete refresh with stable inputs establishes proof");
    Require(!proof.Matches(changedContext, indexes), "changed signing keys or source definitions invalidate proof");
    Require(!proof.Matches(context, changedIndexes), "replaced cached indexes invalidate proof");
    Require(!proof.RecordCompletedRefresh(changedContext, changedContext, changedIndexes, false) &&
        !proof.Matches(changedContext, changedIndexes), "a failed refresh cannot renew a changed cache");
    Require(proof.Matches(context, indexes), "an unchanged cache retains the prior completed-refresh proof");
    CydiaRuntime::RepositoryTrustProof anotherProcess;
    Require(!anotherProcess.Matches(context, indexes), "proof cannot survive an app restart");
    std::cout << "[repository-trust-proof] cold launch, refresh completeness and input invalidation passed\n";
}
