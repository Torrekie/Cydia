/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceDocumentCommit_HPP
#define Cydia_SourceDocumentCommit_HPP

#include "Cydia/SourceDocumentStore.hpp"
#include <sys/types.h>

namespace CydiaSources {

struct PolicySnapshot {
    std::string bytes;
    std::vector<ProtectionSelector> selectors;
    bool present;
    bool valid;
    PolicySnapshot() : present(false), valid(false) {}
};

std::string SerializeProtectionPolicy(const std::vector<ProtectionSelector> &selectors);
bool ParseProtectionPolicy(const std::string &bytes, std::vector<ProtectionSelector> *selectors);
/* Missing/invalid role policy never silently removes bootstrap protection.
 * Only an explicit Advanced Settings review may initialize an empty policy. */
PolicySnapshot ReadProtectionPolicy(const std::string &path, uid_t trustedOwner = 0);

enum class CommitKind { EditDocument, SetProtectionPolicy };
struct CommitRequest {
    CommitKind kind;
    StoredDocument expected;
    Mutation mutation;
    Access access;
    std::string expectedPolicy;
    bool initializePolicy;
    std::vector<ProtectionSelector> selectors;
    CommitRequest() : kind(CommitKind::EditDocument), mutation(EditKind::RemoveDefinition),
        access(Access::Ordinary), initializePolicy(false) {}
};

std::string SerializeCommitRequest(const CommitRequest &request);
bool ParseCommitRequest(const std::string &bytes, CommitRequest *request);

enum class CommitStatus {
    Completed, Unchanged, InvalidRequest, UnsafePath, StaleSnapshot,
    ProtectionReviewRequired, ProtectedDefinition, IOFailure, SourceAppliedPolicyReviewRequired
};
struct CommitResult {
    CommitStatus status;
    int errorNumber;
    bool succeeded() const { return status == CommitStatus::Completed || status == CommitStatus::Unchanged; }
};

struct ProtectedFileSnapshot {
    std::string bytes;
    FileIdentity identity;
};
/* Low-level protected-file boundary for independently resolved APT state.
 * The caller owns the configured scope and shared lock. Never authorize a
 * destination merely because it arrived in a request. */
bool ReadProtectedFile(const std::string &path, ProtectedFileSnapshot *snapshot, uid_t trustedOwner = 0);
CommitResult ReplaceProtectedFile(const std::string &path, const ProtectedFileSnapshot &expected,
    const std::string &updated, uid_t trustedOwner = 0);

/* The caller authenticates the native action, independently resolves these
 * locations/policy path from trusted configuration, holds the APT frontend
 * lock, and revalidates that configuration immediately before calling. No
 * path/role supplied by the unprivileged payload grants authorization.
 * trustedOwner is an injectable filesystem principal for host fixtures;
 * privileged device callers always use the default root principal. */
CommitResult CommitSourceRequest(const EffectiveLocations &locations,
    const std::string &policyPath, const CommitRequest &request, uid_t trustedOwner = 0);
/* Explicit native Advanced edits may change or remove a protected definition.
 * Refresh only its exact existing selectors after the source commit; deletion
 * removes these references while preserving every other role and definition.
 * Ambiguous references require separate Advanced role review before editing.
 * The two file writes are ordered under the caller's frontend lock. If the
 * second step fails, ordinary edits remain blocked by stale selectors and the
 * distinct result requires Advanced review; the source is never rolled back.
 * beforePolicyWrite is an optional trusted revalidation hook, never wire data. */
CommitResult CommitSourceRequestWithProtectionRefresh(const EffectiveLocations &locations,
    const std::string &policyPath, const CommitRequest &request, uid_t trustedOwner = 0,
    bool (*beforePolicyWrite)(void *) = nullptr, void *context = nullptr);


} // namespace CydiaSources
#endif
