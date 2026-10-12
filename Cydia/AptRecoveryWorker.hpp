/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoveryWorker_HPP
#define Cydia_AptRecoveryWorker_HPP
#include "Cydia/AptRecoverySnapshot.hpp"
#include "Cydia/AptProviderServer.hpp"

namespace CydiaAPT { namespace Recovery {
// These requests can only execute through an independently approving parent
// broker. No dpkg invocation, lock ownership, fallback or shared-state writer
// exists in this process. A failed batch ends the sequence without retry.
Provider::PackageManagerReply ExecuteReviewedActions(const RuntimeDescriptor &runtime,
    const Provider::ReviewedTransaction &review, const std::vector<AutoInstalledDelta> &changes,
    const Provider::ServerRequestContext &context);

// Explicit process entry; no startup effects when linked into the app. FD 3
// must be a private, read-only, unlinked parent capsule. Session stdin/stdout
// must be duplicates of one connected AF_UNIX stream socket. The parent is
// responsible for fresh protected authority and dependency-closure inspection;
// capsule parsing/component checks cannot manufacture that authority.
// This function never selects or activates recovery in the parent app.
int RunWorker(int argc, char *argv[]);
}} // namespace CydiaAPT::Recovery
#endif
