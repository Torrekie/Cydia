/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceDocumentStore_HPP
#define Cydia_SourceDocumentStore_HPP

#include "Cydia/SourceDocument.hpp"

#include <cstdint>

namespace CydiaSources {

/* Pass paths resolved from the running APT configuration. Empty paths and
 * /dev/null disable that input. No bootstrap layout or source name is inferred. */
struct EffectiveLocations {
    std::string mainFile;
    std::string partsDirectory;
};

struct FileIdentity {
    bool exists;
    std::uint64_t device, inode, size, links;
    std::uint32_t mode, owner, group;
    std::int64_t modifiedSeconds, modifiedNanoseconds, changedSeconds, changedNanoseconds;
    FileIdentity();
    bool sameVersion(const FileIdentity &other) const;
};

struct StoredDocument {
    Document document;
    FileIdentity identity;
    std::string canonicalPath;   // Resolved parent plus the non-symlink leaf.
};

enum class StoreError {
    InvalidPath, ReadFailed, UnsafeFile, TooLarge, ChangedDuringRead,
    InvalidDocument, StaleSnapshot, TooManyFiles
};

struct StoreDiagnostic {
    StoreError kind;
    std::string path;
    int errorNumber;
    std::string detail;
};

struct StoreSnapshot {
    std::vector<StoredDocument> documents;
    std::vector<StoreDiagnostic> diagnostics;
    bool ready() const { return diagnostics.empty(); }
};

/* Readers reject symlink/nonregular leaves. Parent paths are canonicalized so
 * legitimate bootstrap aliases such as /etc or a selected rootless mount do
 * not become layout assumptions. This is not a privileged path authorization.
 * The root writer must independently validate trusted directory ownership,
 * reopen its directory capabilities and recheck identities/bytes at commit. */
StoreSnapshot ReadDocument(const std::string &path, Format format,
                           std::size_t maximumBytes = 4 * 1024 * 1024);
StoreSnapshot ReadEffectiveDocuments(const EffectiveLocations &locations,
                                    std::size_t maximumBytes = 4 * 1024 * 1024,
                                    std::size_t maximumFiles = 4096);

/* A new definition belongs in an explicit effective main file or an immediate
 * sourceparts child with an APT-supported filename. This never chooses a
 * filename or creates a directory/repository. */
bool IsEffectiveDestination(const EffectiveLocations &locations, const std::string &path);
StoredDocument NewDocument(const std::string &path, Format format);

struct StorePlan {
    StoreSnapshot fresh;
    StoredDocument target;
    EditResult edit;
    bool ready() const { return fresh.ready() && edit.accepted(); }
};

/* Re-read every effective source file before evaluating roles or constructing
 * a plan. Newly selected destinations use NewDocument, and only addition or
 * explicit import may create a missing file. There is deliberately no writer
 * or policy loader here: selectors must come from separately validated policy. */
StorePlan PlanStoredMutation(const EffectiveLocations &locations,
                             const StoredDocument &expected, const Mutation &mutation,
                             const std::vector<ProtectionSelector> &policy = {},
                             Access access = Access::Ordinary,
                             std::size_t maximumBytes = 4 * 1024 * 1024);

} // namespace CydiaSources
#endif
