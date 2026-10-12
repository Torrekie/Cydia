/* Parent-owned native dpkg trigger evidence, never provider-supplied authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderTriggerEvidence_HPP
#define Cydia_AptProviderTriggerEvidence_HPP
#include "Cydia/PrivilegedRuntime.hpp"
#include <functional>
#include <map>

namespace CydiaAPT { namespace Provider {

static const std::size_t MaximumTriggerEvidenceBytes = 32 * 1024 * 1024;
static const std::size_t MaximumDeferredTriggerBytes = 4 * 1024 * 1024;
static const std::size_t MaximumTriggerRegistryFiles = 4096;
static const std::size_t MaximumTriggerRelations = 65536;

struct TriggerInterest {
    std::string trigger;
    // Literal native dpkg selector, including its architecture qualifier if any.
    // Bare names and special qualifiers remain unresolved: a later installed
    // state check must prove a unique actual identity before authorizing effects.
    std::string package;
    bool await = true;
};
struct DeferredTriggerActivation {
    std::string trigger;
    std::vector<std::string> awaiters;
    bool noAwait = false; // The native '-' entry, not a package name.
};
struct TriggerRegistryInput {
    bool directoryPresent = false;
    // Immediate native registry leaves, including Lock when it exists.
    std::map<std::string, std::string> files;
};
struct TriggerRegistryState {
    bool directoryPresent = false, lockPresent = false;
    bool fileRegistryPresent = false, deferredPresent = false;
    // Canonical order; duplicate queue activations coalesce, unlike duplicate
    // File interests (which dpkg rejects). Unknown syntax is never ignored.
    std::vector<TriggerInterest> interests;
    std::vector<DeferredTriggerActivation> deferred;
    std::string canonicalIdentity;
};
// Pure syntax admission and SHA256 identity, not installed-package evidence or
// permission to run effects. Retains await/noawait and literal all/foreign arches.
// Covers dpkg's File, named interests and Unincorp; it does not read info/*.triggers.
bool ParseTriggerRegistry(const TriggerRegistryInput &input,
                          TriggerRegistryState *state, std::string *error);

struct ProtectedTriggerEvidence {
    TriggerRegistryState state;
    // Includes the native Lock identity. Recheck through the API below, never
    // generic RecheckEvidence (reopening/closing Lock can release POSIX locks).
    std::vector<CydiaRuntime::Privileged::Evidence> files;
    std::string evidenceIdentity;
    // False for a missing directory/Lock. Such absence can be displayed or
    // fingerprinted, but MUST NOT admit execution or a settled effect checkpoint.
    bool synchronized = false;
};
// Raw bounded snapshot inputs, including unknown or unfinished native files.
// This does not parse/admit effects. Ordinary package-state snapshots use it to
// fingerprint state without requiring the trigger directory or Lock to exist.
bool CaptureProtectedTriggerFiles(const CydiaRuntime::Privileged::Environment &environment,
    std::vector<CydiaRuntime::Privileged::Evidence> *files, bool *synchronized, std::string *error,
    const std::function<bool()> &cancelled = std::function<bool()>(),
    unsigned timeoutMilliseconds = 2000);
// Captures root-owned immediate regular files under the selected admin directory.
// A bounded shared POSIX lock on an existing triggers/Lock excludes native
// deferred writers; no file is created, truncated or rewritten. The caller must
// separately hold the frontend transaction lock to exclude dpkg registry writes.
// The trigger lock is released on return, before any dpkg/dpkg-query subprocess.
// Missing directory/Lock yields readable but explicitly unsynchronized evidence;
// lock contention, malformed input, unsafe leaves or a changing capture fail.
bool CaptureProtectedTriggerEvidence(const CydiaRuntime::Privileged::Environment &environment,
    ProtectedTriggerEvidence *evidence, std::string *error,
    const std::function<bool()> &cancelled = std::function<bool()>(),
    unsigned timeoutMilliseconds = 2000);
// Requires both captures to have held the native lock and exact identities,
// content and membership to match. This alone grants no execution authority.
bool RecheckProtectedTriggerEvidence(const CydiaRuntime::Privileged::Environment &environment,
    const ProtectedTriggerEvidence &expected, std::string *error,
    const std::function<bool()> &cancelled = std::function<bool()>(),
    unsigned timeoutMilliseconds = 2000);

}} // namespace CydiaAPT::Provider
#endif
