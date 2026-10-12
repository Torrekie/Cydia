/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceDraft_HPP
#define Cydia_SourceDraft_HPP

#include "Cydia/SourceDocument.hpp"

namespace CydiaSources {

enum class ArchitectureMode { Inherit, Replace, Modify };

/* A draft never reads or changes APT configuration. Raw imports retain their
 * exact bytes and format until the user explicitly requests a supported
 * structured conversion. Inherit means no architecture option is emitted. */
struct SourceDraft {
    bool raw;
    Format format;
    std::string rawContents;
    std::string uri;
    bool exactPath;
    std::string distribution;
    std::vector<std::string> components;
    ArchitectureMode architectureMode;
    std::vector<std::string> architectures;
    std::vector<std::string> architecturesAdd;
    std::vector<std::string> architecturesRemove;
    bool includeSourcePackages;
    bool enabled;
    std::string signedBy; // Empty inherits APT trust; never implies approval.
    SourceDraft();
};

struct DraftDiagnostic {
    std::string code;  // Stable identifier for localized UI messages.
    std::string field;
    std::string detail;
    std::string path;
    std::size_t ordinal;
    bool blocking;
};

struct DraftResult {
    Document document;
    std::vector<DraftDiagnostic> diagnostics;
    bool valid() const;
};

SourceDraft ImportSourceDraft(const std::string &bytes, Format format);

/* Reparse every supplied document; never trust caller-supplied spans or DTOs.
 * ignorePath/ignoreOrdinal exclude only an explicitly edited definition.
 * Disabled duplicates are reported without blocking; conflicting enabled
 * Release-level options are errors even when components or types differ. */
DraftResult BuildSourceDraft(const SourceDraft &draft, const std::string &path,
    const std::vector<Document> &existingDocuments = {},
    const std::string &ignorePath = std::string(),
    std::size_t ignoreOrdinal = std::string::npos);

/* Refuses conversion when unknown options, comments, folded values, multiple
 * URIs/suites or source-only records would lose information. The raw draft is
 * still usable and can be edited/imported without conversion. */
bool ConvertDraftToStructured(const SourceDraft &raw, SourceDraft *structured,
                             std::vector<DraftDiagnostic> *diagnostics = NULL);

/* Returns a filename only, never a path. Existing names are supplied by the
 * caller's effective APT directory snapshot. A later atomic write must still
 * guard races and collisions. */
std::string SuggestedSourceFilename(const SourceDraft &draft,
                                   const std::vector<std::string> &existingBasenames);

} // namespace CydiaSources
#endif
