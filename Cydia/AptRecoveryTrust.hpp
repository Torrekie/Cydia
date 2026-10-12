/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoveryTrust_HPP
#define Cydia_AptRecoveryTrust_HPP
#include "Cydia/AptRecoverySnapshot.hpp"
#include "Cydia/RepositoryTrustProof.hpp"
namespace CydiaAPT { namespace Recovery {
// Session-local evidence of this worker's completed refresh. No persisted
// trust flag and no execution authority are derived from this reader.
class WorkerTrustProof {
    CydiaRuntime::RepositoryTrustProof proof_;
public:
    std::string BeginRefresh(const Snapshot &, const std::function<bool()> &cancelled);
    bool CompleteRefresh(const Snapshot &, const std::string &before, bool complete,
        const std::function<bool()> &cancelled);
    bool Matches(const Snapshot &, const std::function<bool()> &cancelled) const;
};
}}
#endif
