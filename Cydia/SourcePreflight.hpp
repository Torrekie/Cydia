/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourcePreflight_HPP
#define Cydia_SourcePreflight_HPP

#include "Cydia/SourceDocument.hpp"
#include "Cydia/AptCompatibility.hpp"
#include <functional>

namespace CydiaAPT {

enum class SourceCheckStatus {
    Complete, InvalidDefinition, Unavailable, Cancelled, TimedOut, SizeLimit, InternalError
};
enum class SourceArchitectureAvailability { Unknown, Supported, Unsupported };

struct SourcePreflightRequest {
    std::string definition;
    CydiaSources::Format format = CydiaSources::Format::OneLine;
    /* Optional public key explicitly selected for this draft.
     * Bound only inside the isolated check; never imported into real trust. */
    std::string candidatePublicKey;
    /* Conservative evidence from the matching existing source when editing.
     * A fresh private list directory cannot detect a trust downgrade itself. */
    bool previouslyAuthenticated = false;
    /* A caller-selected temporary directory, never an APT state directory. */
    std::string temporaryParent;
    unsigned timeoutSeconds = 60;
    std::size_t maximumBytes = 128 * 1024 * 1024;
};

struct SourceMetadata {
    std::string uri, suitePath, label, origin;
    /* APT-resolved metadata directory, for bounded retry of a missing
     * signature. May contain source credentials; never display or log it. */
    std::string metadataBaseURI;
    std::vector<std::string> architectures, components;
    /* Exact fetched bytes, retained even when authentication fails, when
     * available. clearSigned distinguishes InRelease from a Release whose
     * detached signature was missing or discarded by APT.
     * These bytes are not authenticated merely because they were fetched. */
    std::string metadata, detachedSignature;
    bool clearSigned = false;
    bool authenticated = false;
};

struct SourcePreflightResult {
    SourceCheckStatus status = SourceCheckStatus::InternalError;
    bool allowed = false;
    bool authenticated = false;
    SourceArchitectureAvailability architecture = SourceArchitectureAvailability::Unknown;
    std::vector<FetchFailureData> warnings, failures;
    std::vector<SourceMetadata> repositories;
    /* Diagnostic text from APT, not instructions and not localization keys. */
    std::vector<ErrorData> errors;
};

struct SourceResourceRequest {
    std::string uri, temporaryParent;
    unsigned timeoutSeconds = 20;
    std::size_t maximumBytes = 2 * 1024 * 1024;
};
struct SourceResourceResult {
    SourceCheckStatus status = SourceCheckStatus::InternalError;
    std::string bytes;
    std::vector<ErrorData> errors;
};

/* Synchronous, off the main thread, while holding Database's serialization
 * boundary and settings-change gate. APT has process-global configuration.
 * Both operations restore it and remove their private temporary files. No
 * real source file, package cache, dpkg state or shared list is written; no
 * update hooks are executed. A true cancellation callback stops acquisition.
 * Raw resources use HTTP(S), never redirect and carry no Cydia identity
 * headers. The caller controls same-origin discovery and the request budget. */
SourcePreflightResult RunSourcePreflight(const SourcePreflightRequest &request,
    const std::function<bool()> &cancelled = std::function<bool()>());
SourceResourceResult FetchSourceResource(const SourceResourceRequest &request,
    const std::function<bool()> &cancelled = std::function<bool()>());

} // namespace CydiaAPT
#endif
