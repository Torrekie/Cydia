/* Semantic admission of captured files; separate from raw runtime snapshots.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEvidence.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <apt-pkg/hashes.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
std::string Digest(const ProtectedTriggerEvidence &evidence) {
    Hashes hash(Hashes::SHA256SUM);
    const std::string domain("CYDIA-PROTECTED-TRIGGERS-1");
    if (!hash.Add(domain.data(), domain.size())) return "";
    const char synchronized = evidence.synchronized ? '1' : '0';
    if (!hash.Add(&synchronized, 1)) return "";
    for (const auto &file : evidence.files) {
        const std::string bytes = P::SerializeSnapshotEvidence(file) + std::to_string(file.identity.st_nlink) + ':';
        if (!hash.Add(bytes.data(), bytes.size())) return "";
    }
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
}
bool CaptureProtectedTriggerEvidence(const P::Environment &environment, ProtectedTriggerEvidence *evidence,
    std::string *error, const std::function<bool()> &cancelled, unsigned timeoutMilliseconds) {
    if (!evidence) return Fail(error, "provider_trigger_input_invalid");
    *evidence = ProtectedTriggerEvidence();
    ProtectedTriggerEvidence result;
    if (!CaptureProtectedTriggerFiles(environment, &result.files, &result.synchronized, error, cancelled, timeoutMilliseconds)) return false;
    TriggerRegistryInput input;
    input.directoryPresent = !result.files.front().absent;
    for (const auto &file : result.files) {
        if (file.directory || file.absent) continue;
        input.files.emplace(file.path.substr(file.path.find_last_of('/') + 1), file.bytes);
    }
    if (!ParseTriggerRegistry(input, &result.state, error)) return false;
    result.evidenceIdentity = Digest(result);
    if (result.evidenceIdentity.size() != 64) return Fail(error, "provider_trigger_hash_failed");
    *evidence = std::move(result); return true;
}
bool RecheckProtectedTriggerEvidence(const P::Environment &environment,
    const ProtectedTriggerEvidence &expected, std::string *error, const std::function<bool()> &cancelled,
    unsigned timeoutMilliseconds) {
    if (!expected.synchronized || expected.evidenceIdentity.size() != 64)
        return Fail(error, "provider_trigger_evidence_unadmitted");
    ProtectedTriggerEvidence actual;
    if (!CaptureProtectedTriggerEvidence(environment, &actual, error, cancelled, timeoutMilliseconds)) return false;
    return (actual.synchronized && actual.evidenceIdentity == expected.evidenceIdentity &&
            actual.state.canonicalIdentity == expected.state.canonicalIdentity) ||
        Fail(error, "provider_trigger_state_changed");
}
}} // namespace CydiaAPT::Provider
