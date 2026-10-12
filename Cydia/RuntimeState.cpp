/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeState.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/ExtendedState.hpp"
#include "Cydia/SourceDocumentCommit.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <limits>
#include <sstream>

namespace CydiaRuntime { namespace Privileged {
namespace {
bool Fail(Error *error, const char *code, const char *message) {
    if (error != NULL) { error->code = code; error->message = message; }
    return false;
}
bool HashSnapshot(const Environment &environment, SnapshotScope scope, std::string *token, Error *error) {
    if (token == NULL) return false;
    std::vector<Evidence> inputs;
    if (!CaptureSnapshotInputs(environment, scope, &inputs, error) || !RecheckEvidence(inputs, error)) return false;
    Hashes hash(Hashes::SHA256SUM);
    const std::string domain(scope == SnapshotScope::PackageState ? "CYDIA-PACKAGE-SNAPSHOT-6" : "CYDIA-TRUST-SNAPSHOT-4");
    if (!hash.Add(domain.data(), domain.size())) return Fail(error, "snapshot_failed", "Cannot hash the package-manager snapshot.");
    for (const auto &input : inputs) {
        const std::string frame(SerializeSnapshotEvidence(input));
        if (!hash.Add(frame.data(), frame.size())) return Fail(error, "snapshot_failed", "Cannot hash the package-manager snapshot.");
    }
    *token = hash.GetHashString(Hashes::SHA256SUM).HashValue();
    return token->size() == 64;
}
bool ParseVariableFields(const std::string &bytes, std::vector<std::string> *fields, Error *error) {
    if (bytes.size() > 8 * 1024 * 1024) return false;
    std::size_t cursor(0), count(0);
    while (cursor < bytes.size()) {
        std::size_t length(0), digits(0);
        while (cursor < bytes.size() && bytes[cursor] >= '0' && bytes[cursor] <= '9') {
            const unsigned digit(bytes[cursor++] - '0');
            if (++digits > 20 || length > (std::numeric_limits<std::size_t>::max() - digit) / 10) return false;
            length = length * 10 + digit;
        }
        if (digits == 0 || cursor == bytes.size() || bytes[cursor++] != ':' || length >= bytes.size() - cursor) return false;
        cursor += length;
        if (bytes[cursor++] != ',' || ++count > 196610) return false;
    }
    return count >= 2 && (count - 2) % 3 == 0 && ParseFields(bytes, count, fields, error);
}
bool QueryArchitectures(const Environment &environment, std::string *native, std::vector<std::string> *architectures, Error *error) {
    Dpkg::Runner runner(environment.dpkg);
    std::vector<std::string> args{"--root=" + environment.dpkgRoot, "--admindir=" + environment.dpkgAdmin, "--print-architecture"};
    std::string output;
    if (!runner.RunAndCapture(args, &output, 32768).succeeded()) return Fail(error, "architecture_query_failed", "Cannot query the active dpkg architecture.");
    while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) output.pop_back();
    if (!ValidArchitectureName(output)) return Fail(error, "architecture_query_failed", "dpkg returned an invalid native architecture.");
    *native = output; architectures->push_back(output);
    args.back() = "--print-foreign-architectures";
    if (!runner.RunAndCapture(args, &output, 32768).succeeded()) return Fail(error, "architecture_query_failed", "Cannot query active dpkg foreign architectures.");
    std::istringstream lines(output); std::string architecture;
    while (std::getline(lines, architecture)) {
        if (!architecture.empty() && architecture.back() == '\r') architecture.pop_back();
        if (!ValidArchitectureName(architecture)) return Fail(error, "architecture_query_failed", "dpkg returned an invalid foreign architecture.");
        architectures->push_back(architecture);
    }
    return RecheckEvidence(environment.evidence, error);
}
}
bool RuntimeSnapshot(const Environment &environment, std::string *token, Error *error) {
    return HashSnapshot(environment, SnapshotScope::PackageState, token, error);
}
bool TrustSnapshot(const Environment &environment, std::string *token, Error *error) {
    return HashSnapshot(environment, SnapshotScope::RepositoryTrust, token, error);
}
bool ReadExtendedState(const Environment &environment, std::string *bytes, Error *error) {
    CydiaSources::ProtectedFileSnapshot snapshot;
    if (environment.extendedStates.empty() || !CydiaSources::ReadSharedStateFile(environment.extendedStates, &snapshot))
        return Fail(error, "extended_state_unavailable", "Cannot read protected shared APT state.");
    *bytes = snapshot.bytes; return RecheckEvidence(environment.evidence, error);
}
bool CommitExtendedState(const Environment &environment, const std::string &payload, Error *error) {
    std::vector<std::string> fields;
    if (!ParseVariableFields(payload, &fields, error) || fields[0] != environment.extendedStates)
        return Fail(error, "invalid_extended_state", "Invalid configured APT state request.");
    CydiaSources::ProtectedFileSnapshot original, status;
    if (!CydiaSources::ReadSharedStateFile(environment.extendedStates, &original) ||
        !CydiaSources::ReadSharedStateFile(environment.dpkgAdmin + "/status", &status) || !status.identity.exists)
        return Fail(error, "extended_state_unavailable", "Cannot read protected APT or dpkg state.");
    if (original.bytes != fields[1]) return Fail(error, "stale_extended_state", "Another package manager changed shared APT state.");
    std::vector<AutoStateDelta> deltas;
    for (std::size_t index = 2; index < fields.size(); index += 3) {
        if (fields[index + 2] != "0" && fields[index + 2] != "1") return Fail(error, "invalid_extended_state", "Invalid automatic-package flag.");
        deltas.push_back({fields[index], fields[index + 1], fields[index + 2] == "1"});
    }
    std::string native; std::vector<std::string> architectures;
    if (!QueryArchitectures(environment, &native, &architectures, error)) return false;
    std::string updated;
    if (!MergeExtendedState(original.bytes, status.bytes, native, architectures, deltas, &updated))
        return Fail(error, "invalid_extended_state", "Cannot safely merge the committed package flags.");
    CydiaSources::ProtectedFileSnapshot currentStatus;
    if (!CydiaSources::ReadSharedStateFile(environment.dpkgAdmin + "/status", &currentStatus) ||
        !currentStatus.identity.sameVersion(status.identity) || currentStatus.bytes != status.bytes ||
        !RecheckEvidence(environment.evidence, error)) return Fail(error, "stale_package_state", "The installed package state changed.");
    const auto result(CydiaSources::ReplaceSharedStateFile(environment.extendedStates, original, updated));
    return result.succeeded() || Fail(error, "extended_state_write_failed", "Cannot atomically save shared APT state.");
}
} }
