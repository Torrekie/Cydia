/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceDocument_HPP
#define Cydia_SourceDocument_HPP

#include <cstddef>
#include <string>
#include <vector>

namespace CydiaSources {

enum class Format { OneLine, Deb822 };

struct Span {
    std::size_t begin;
    std::size_t end;
    Span(std::size_t begin = 0, std::size_t end = 0) : begin(begin), end(end) {}
};

struct Field {
    std::string name;             // Original spelling; Deb822 comparisons ignore case.
    std::string value;            // Folded value, never used to reconstruct bytes.
    Span span;
    Span firstLineValue;
    Span tokenSpan;             // One-line option token only, excluding surrounding whitespace.
};

struct Definition {
    std::string path;
    std::size_t ordinal;
    Span span;                   // Whole owning line or Deb822 stanza.
    std::string original;
    bool enabled;
    std::vector<std::string> types;
    std::vector<std::string> uris;
    std::vector<std::string> suites;
    std::vector<std::string> components;
    std::vector<Field> fields;    // Includes unknown Deb822 fields/list options.
    std::size_t commentOffset;   // Disabled classic line's '#', or std::string::npos.
    Span uriSpan;               // One-line URI token.
    Span suiteSpan;             // One-line suite token.
    Span optionsSpan;           // One-line brackets; empty when no options exist.
    Span componentsSpan;        // Classic component tokens, excluding adjacent whitespace/comment.
    std::string semanticKey;     // Ignores Enabled and X-Cydia-* annotations only.

    Definition();
};

struct Document {
    std::string path;
    Format format;
    std::string bytes;
    std::vector<Definition> definitions;
    std::vector<std::string> diagnostics;
    bool valid() const { return diagnostics.empty(); }
};

/* Pure parser: no file reads, environment assumptions, URI HEAD probes, or
 * cached preference reconstruction. The caller supplies the actual APT file. */
Document ParseDocument(const std::string &path, Format format, const std::string &bytes);
/* Editing-only projection: retains tokenized entries while URI/suite/component
 * relationships are incomplete. Never use this result to validate or commit. */
Document ParseDraftDocument(Format format, const std::string &bytes);
/* One source is one owning stanza/line, or a classic deb/deb-src pair with
 * otherwise identical configuration. Used for additions and single-source
 * replacements. Reparse bytes rather than trusting a caller's DTO. */
bool IsSingleSourceAddition(const Document &document);
/* Folded Deb822 components require explicit definition editing instead of
 * silently dropping comments during legacy component actions. */
bool SourceWithComponents(const Document &document, std::size_t ordinal,
                          const std::vector<std::string> &components,
                          std::string *replacement);

/* Persist these selectors in separately validated, root-owned role policy.
 * They are references, not repository definitions: never materialize a source
 * from a missing selector. originPath is provenance, not a prefix/layout rule. */
struct ProtectionSelector {
    std::string setIdentifier;
    std::string originPath;
    std::string semanticKey;
    std::vector<std::string> uris;
};

ProtectionSelector SelectorForDefinition(const std::string &setIdentifier,
                                        const Definition &definition);

enum class ProtectionState { Unprotected, Protected, ReviewRequired };

struct ProtectionResult {
    ProtectionState state;
    std::vector<std::string> sets;
    std::string detail;
    ProtectionResult() : state(ProtectionState::Unprotected) {}
};

/* `documents` must be a fresh snapshot of every effective source file, also
 * including disabled records. Duplicates, changed or missing selectors fail
 * closed; moving a definition requires explicit advanced review. */
ProtectionResult EvaluateProtection(const std::vector<Document> &documents,
                                    const std::vector<ProtectionSelector> &policy,
                                    const std::string &path, std::size_t ordinal);

enum class Access { Ordinary, AdvancedSettings };
enum class EditKind {
    RemoveDefinition, SetEnabled, ReplaceDefinition, AppendDefinition, ReplaceDocument
};

struct Mutation {
    EditKind kind;
    std::size_t ordinal;
    bool enabled;
    std::string contents;        // Explicit replacement/import bytes, not a cached model.
    explicit Mutation(EditKind kind) : kind(kind), ordinal(0), enabled(true) {}
};

enum class EditStatus {
    Ready, NoChange, StaleDocument, InvalidDocument, InvalidMutation,
    ProtectedDefinition, ProtectionReviewRequired
};

struct EditResult {
    EditStatus status;
    std::string original;
    std::string updated;
    std::string detail;
    bool accepted() const { return status == EditStatus::Ready || status == EditStatus::NoChange; }
};

/* Produces a lossless edit plan. Exact byte comparison is the stale-snapshot
 * guard; semantic keys are only protection references, never security hashes.
 * Access is a caller assertion, NOT an authorization capability. The native
 * integration/privileged writer must authenticate an Advanced Settings action,
 * reload role policy, validate paths, and recheck the preimage before commit. */
EditResult PlanMutation(const Document &snapshot, const std::string &currentBytes,
                        const Mutation &mutation,
                        const std::vector<Document> &documents = {},
                        const std::vector<ProtectionSelector> &policy = {},
                        Access access = Access::Ordinary);

} // namespace CydiaSources
#endif
