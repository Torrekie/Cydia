/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDocument.hpp"

#include <algorithm>
#include <map>
#include <sstream>

namespace CydiaSources {
namespace {

struct Line { Span span; std::size_t contentEnd; };

bool Space(char value) { return value == ' ' || value == '\t' || value == '\r' || value == '\n'; }
std::string Lower(std::string value) {
    for (char &character : value)
        if (character >= 'A' && character <= 'Z') character += 'a' - 'A';
    return value;
}
std::string Trim(const std::string &value) {
    std::size_t begin(0), end(value.size());
    while (begin < end && Space(value[begin])) ++begin;
    while (end > begin && Space(value[end - 1])) --end;
    return value.substr(begin, end - begin);
}
std::vector<std::string> Words(const std::string &value) {
    std::vector<std::string> result;
    std::istringstream input(value);
    for (std::string word; input >> word;) result.push_back(word);
    return result;
}
std::vector<Line> Lines(const std::string &bytes) {
    std::vector<Line> lines;
    for (std::size_t offset(0); offset < bytes.size();) {
        const std::size_t newline(bytes.find('\n', offset));
        const std::size_t end(newline == std::string::npos ? bytes.size() : newline + 1);
        std::size_t contentEnd(newline == std::string::npos ? end : newline);
        if (contentEnd > offset && bytes[contentEnd - 1] == '\r') --contentEnd;
        lines.push_back({Span(offset, end), contentEnd});
        offset = end;
    }
    return lines;
}
bool FieldName(const std::string &name) {
    if (name.empty()) return false;
    for (char character : name)
        if (!((character >= 'a' && character <= 'z') ||
              (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') || character == '-')) return false;
    return true;
}
bool Boolean(const std::string &value, bool *result) {
    const std::string lower(Lower(Trim(value)));
    if (lower == "yes" || lower == "true" || lower == "1" || lower == "on") { *result = true; return true; }
    if (lower == "no" || lower == "false" || lower == "0" || lower == "off") { *result = false; return true; }
    return false;
}
const Field *FindField(const Definition &definition, const char *name) {
    for (const Field &field : definition.fields)
        if (Lower(field.name) == name) return &field;
    return NULL;
}
bool ValidShape(const Definition &definition, bool allowIncompleteDisabled = false) {
    if (definition.types.empty()) return false;
    for (const std::string &type : definition.types)
        if (type != "deb" && type != "deb-src") return false;
    // APT skips the URI/suite checks for Enabled: no. Keep disabled templates
    // visible without allowing an incomplete template to be enabled.
    if (allowIncompleteDisabled && !definition.enabled) return true;
    if (definition.uris.empty() || definition.suites.empty()) return false;
    for (const std::string &uri : definition.uris) {
        const std::size_t colon(uri.find(':'));
        if (colon == std::string::npos || colon == 0 || colon + 1 == uri.size()) return false;
    }
    for (const std::string &suite : definition.suites)
        if (suite.empty() || (suite.back() == '/' ? !definition.components.empty() : definition.components.empty()))
            return false;
    return true;
}
void KeyPart(std::string *key, const std::string &value) {
    *key += std::to_string(value.size()) + ":" + value;
}
void KeyWords(std::string *key, std::vector<std::string> values) {
    std::sort(values.begin(), values.end());
    values.erase(std::unique(values.begin(), values.end()), values.end());
    KeyPart(key, std::to_string(values.size()));
    for (const std::string &value : values) KeyPart(key, value);
}
std::string SemanticKey(const Definition &definition, Format format) {
    std::string key;
    KeyWords(&key, definition.types); KeyWords(&key, definition.uris);
    KeyWords(&key, definition.suites); KeyWords(&key, definition.components);
    std::map<std::string, std::string> options;
    for (const Field &field : definition.fields) {
        std::string name(format == Format::Deb822 ? Lower(field.name) : field.name);
        if ((format == Format::Deb822 && name == "enabled") || Lower(name).compare(0, 8, "x-cydia-") == 0) continue;
        if (format == Format::Deb822 && (name == "types" || name == "uris" ||
            name == "suites" || name == "components")) continue;
        if (format == Format::OneLine) {
            if (name == "arch") name = "architectures";
            if (name == "lang") name = "languages";
        }
        std::string value(Trim(field.value));
        if (name == "architectures" || name == "languages") {
            if (format == Format::OneLine) std::replace(value.begin(), value.end(), ',', ' ');
            std::string normalized; KeyWords(&normalized, Words(value)); value.swap(normalized);
        }
        options[name] = value;
    }
    for (const auto &option : options) { KeyPart(&key, option.first); KeyPart(&key, option.second); }
    return key;
}
enum class TokenResult { End, Value, Invalid };
int Hex(char character) {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    if (character >= 'A' && character <= 'F') return character - 'A' + 10;
    return -1;
}
TokenResult NextToken(const std::string &bytes, std::size_t end, std::size_t *offset, std::string *token) {
    while (*offset < end && Space(bytes[*offset])) ++*offset;
    if (*offset == end) return TokenResult::End;
    const std::size_t start(*offset);
    while (*offset < end && !Space(bytes[*offset])) {
        if (bytes[*offset] == '"' || bytes[*offset] == '[') {
            const char close(bytes[*offset] == '"' ? '"' : ']');
            const std::size_t closing(bytes.find(close, *offset + 1));
            if (closing == std::string::npos || closing >= end) return TokenResult::Invalid;
            *offset = closing;
        }
        ++*offset;
    }
    token->clear();
    for (std::size_t index(start); index < *offset; ++index) {
        if (bytes[index] == '"') continue;
        // Match APT's ParseQuoteWord percent decoding, without reconstructing
        // or changing the source line's original spelling.
        if (bytes[index] == '%' && index + 2 < *offset && Hex(bytes[index + 1]) >= 0 && Hex(bytes[index + 2]) >= 0) {
            const char character(static_cast<char>(Hex(bytes[index + 1]) * 16 + Hex(bytes[index + 2])));
            if (character == '\0' || character == '\r' || character == '\n') return TokenResult::Invalid;
            *token += character; index += 2;
        } else *token += bytes[index];
    }
    return token->empty() ? TokenResult::Invalid : TokenResult::Value;
}
std::size_t ClassicEnd(const std::string &bytes, std::size_t begin, std::size_t end) {
    std::size_t opened(0), closed(0);
    for (std::size_t index(begin); index < end; ++index) {
        if (bytes[index] == '[') ++opened;
        if (bytes[index] == ']') ++closed;
        if (bytes[index] == '#' && opened <= closed) return index;
    }
    return end;
}
bool ParseClassic(Document *document, const Line &line, bool draft = false) {
    std::size_t offset(line.span.begin);
    while (offset < line.contentEnd && Space(document->bytes[offset])) ++offset;
    Definition definition;
    if (offset < line.contentEnd && document->bytes[offset] == '#') {
        definition.enabled = false; definition.commentOffset = offset++;
        while (offset < line.contentEnd && Space(document->bytes[offset])) ++offset;
    }
    const std::size_t end(ClassicEnd(document->bytes, offset, line.contentEnd));
    const std::size_t typeBegin(offset);
    while (offset < end && !Space(document->bytes[offset])) ++offset;
    std::string token(document->bytes.substr(typeBegin, offset - typeBegin));
    if (token.empty()) return true;
    if (token != "deb" && token != "deb-src") {
        if (definition.enabled) return false; // Non-source comments remain opaque.
        return true;
    }
    definition.types.push_back(token);
    while (offset < end && Space(document->bytes[offset])) ++offset;
    if (offset < end && document->bytes[offset] == '[') {
        const std::size_t begin(offset++);
        std::size_t close(offset);
        for (; close < end && document->bytes[close] != ']'; ++close)
            if (document->bytes[close] == '"') {
                const std::size_t quote(document->bytes.find('"', close + 1));
                if (quote == std::string::npos || quote >= end) return false;
                close = quote;
            }
        if (close == end) return false;
        definition.optionsSpan = Span(begin, close + 1);
        TokenResult result;
        std::string option;
        while (true) {
            while (offset < close && Space(document->bytes[offset])) ++offset;
            const std::size_t optionBegin(offset);
            result = NextToken(document->bytes, close, &offset, &option);
            if (result != TokenResult::Value) break;
            const std::size_t equals(option.find('='));
            if (equals == std::string::npos || equals == 0 || equals + 1 == option.size()) return false;
            Field field; field.name = option.substr(0, equals); field.value = option.substr(equals + 1);
            field.span = Span(begin, close + 1); field.firstLineValue = field.span;
            field.tokenSpan = Span(optionBegin, offset);
            definition.fields.push_back(field);
        }
        if (result == TokenResult::Invalid) return false;
        offset = close + 1;
        if (offset < end && !Space(document->bytes[offset])) return false;
    }
    while (offset < end && Space(document->bytes[offset])) ++offset;
    definition.uriSpan.begin = offset;
    if (NextToken(document->bytes, end, &offset, &token) != TokenResult::Value) return false;
    definition.uriSpan.end = offset;
    definition.uris.push_back(token);
    while (offset < end && Space(document->bytes[offset])) ++offset;
    definition.suiteSpan.begin = offset;
    if (NextToken(document->bytes, end, &offset, &token) != TokenResult::Value) return false;
    definition.suiteSpan.end = offset;
    definition.suites.push_back(token);
    std::size_t componentsBegin(offset);
    while (componentsBegin < end && Space(document->bytes[componentsBegin])) ++componentsBegin;
    std::size_t componentsEnd(end);
    while (componentsEnd > componentsBegin && Space(document->bytes[componentsEnd - 1])) --componentsEnd;
    definition.componentsSpan = Span(componentsBegin, componentsEnd);
    TokenResult result;
    while ((result = NextToken(document->bytes, end, &offset, &token)) == TokenResult::Value) definition.components.push_back(token);
    if (result == TokenResult::Invalid) return false;
    if (!draft && !ValidShape(definition)) return false;
    definition.path = document->path; definition.ordinal = document->definitions.size();
    definition.span = line.span;
    definition.original = document->bytes.substr(line.span.begin, line.span.end - line.span.begin);
    definition.semanticKey = SemanticKey(definition, document->format);
    document->definitions.push_back(definition);
    return true;
}
bool ParseStanza(Document *document, const std::vector<Line> &lines, std::size_t begin, std::size_t end, bool draft = false) {
    Definition definition;
    for (std::size_t index(begin); index < end; ++index) {
        const Line &line(lines[index]);
        const std::string content(document->bytes.substr(line.span.begin, line.contentEnd - line.span.begin));
        const std::string trimmed(Trim(content));
        // APT's Deb822 comment filter recognizes '#' in column zero only;
        // an indented '#' is part of a folded field (including inline keys).
        if (trimmed.empty() || content[0] == '#') continue;
        if (content[0] == ' ' || content[0] == '\t') {
            if (definition.fields.empty()) return false;
            definition.fields.back().value += "\n" + content.substr(1);
            definition.fields.back().span.end = line.span.end;
            continue;
        }
        const std::size_t colon(content.find(':'));
        if (colon == std::string::npos || !FieldName(content.substr(0, colon))) return false;
        Field field; field.name = content.substr(0, colon); field.value = Trim(content.substr(colon + 1));
        field.span = line.span;
        std::size_t valueBegin(line.span.begin + colon + 1), valueEnd(line.contentEnd);
        while (valueBegin < valueEnd && Space(document->bytes[valueBegin])) ++valueBegin;
        while (valueEnd > valueBegin && Space(document->bytes[valueEnd - 1])) --valueEnd;
        field.firstLineValue = Span(valueBegin, valueEnd);
        if (FindField(definition, Lower(field.name).c_str())) return false;
        definition.fields.push_back(field);
    }
    if (definition.fields.empty()) return true; // Comment-only paragraph.
    const Field *field;
    if ((field = FindField(definition, "types"))) definition.types = Words(field->value);
    if ((field = FindField(definition, "uris"))) definition.uris = Words(field->value);
    if ((field = FindField(definition, "suites"))) definition.suites = Words(field->value);
    if ((field = FindField(definition, "components"))) definition.components = Words(field->value);
    if ((field = FindField(definition, "enabled")) && !Boolean(field->value, &definition.enabled)) return false;
    if (!draft && !ValidShape(definition, true)) return false;
    definition.path = document->path; definition.ordinal = document->definitions.size();
    definition.span = Span(lines[begin].span.begin, lines[end - 1].span.end);
    definition.original = document->bytes.substr(definition.span.begin, definition.span.end - definition.span.begin);
    definition.semanticKey = SemanticKey(definition, document->format);
    document->definitions.push_back(definition);
    return true;
}
void AddSet(ProtectionResult *result, const std::string &set) {
    if (std::find(result->sets.begin(), result->sets.end(), set) == result->sets.end()) result->sets.push_back(set);
}
std::string Newline(const Document &document) {
    return document.bytes.find("\r\n") != std::string::npos ? "\r\n" : "\n";
}
std::string CommentsOnly(const std::string &bytes) {
    std::string result;
    for (const Line &line : Lines(bytes)) {
        const std::string content(bytes.substr(line.span.begin, line.contentEnd - line.span.begin));
        const std::string trimmed(Trim(content));
        if (!trimmed.empty() && content[0] == '#') result += bytes.substr(line.span.begin, line.span.end - line.span.begin);
    }
    return result;
}
std::string EnabledReplacement(const Document &document, const Definition &definition, bool enabled) {
    std::string replacement(definition.original);
    if (definition.enabled == enabled) return replacement;
    if (document.format == Format::OneLine) {
        if (!enabled) {
            std::size_t first(0); while (first < replacement.size() && Space(replacement[first])) ++first;
            replacement.insert(first, "# ");
        } else {
            const std::size_t offset(definition.commentOffset - definition.span.begin);
            const std::size_t count(offset + 1 < replacement.size() && replacement[offset + 1] == ' ' ? 2 : 1);
            replacement.erase(offset, count);
        }
    } else if (const Field *field = FindField(definition, "enabled")) {
        // Enabled is a boolean; never accept a folded/multiline value edit.
        replacement.replace(field->firstLineValue.begin - definition.span.begin,
                            field->firstLineValue.end - field->firstLineValue.begin, enabled ? "yes" : "no");
    } else {
        if (!replacement.empty() && replacement.back() != '\n') replacement += Newline(document);
        replacement += std::string("Enabled: ") + (enabled ? "yes" : "no") + Newline(document);
    }
    return replacement;
}
EditResult Failure(EditStatus status, const Document &document, const char *detail) {
    EditResult result; result.status = status; result.original = document.bytes;
    result.updated = document.bytes; result.detail = detail; return result;
}
} // namespace

Definition::Definition() : ordinal(0), enabled(true), commentOffset(std::string::npos) {}

static Document ParseDocumentImpl(const std::string &path, Format format, const std::string &bytes, bool draft) {
    Document document; document.path = path; document.format = format; document.bytes = bytes;
    if (bytes.find('\0') != std::string::npos) {
        document.diagnostics.push_back("Source document contains a NUL byte"); return document;
    }
    const std::vector<Line> lines(Lines(bytes));
    if (format == Format::OneLine) {
        for (std::size_t index(0); index < lines.size(); ++index)
            if (!ParseClassic(&document, lines[index], draft)) {
                const std::string content(Trim(bytes.substr(lines[index].span.begin,
                    lines[index].contentEnd - lines[index].span.begin)));
                // A commented example need not be an enableable definition.
                // Preserve it as opaque bytes, just as APT does.
                if (content.empty() || content[0] != '#')
                    document.diagnostics.push_back("Invalid source definition at line " + std::to_string(index + 1));
            }
    } else {
        std::size_t begin(0);
        for (std::size_t index(0); index <= lines.size(); ++index) {
            if (index != lines.size() && !Trim(bytes.substr(lines[index].span.begin,
                lines[index].contentEnd - lines[index].span.begin)).empty()) continue;
            if (begin < index && !ParseStanza(&document, lines, begin, index, draft))
                document.diagnostics.push_back("Invalid source stanza at line " + std::to_string(begin + 1));
            begin = index + 1;
        }
    }
    return document;
}

Document ParseDocument(const std::string &path, Format format, const std::string &bytes) {
    return ParseDocumentImpl(path, format, bytes, false);
}

Document ParseDraftDocument(Format format, const std::string &bytes) {
    return ParseDocumentImpl("", format, bytes, true);
}

bool IsSingleSourceAddition(const Document &requested) {
    const Document document(ParseDocument(requested.path, requested.format, requested.bytes));
    if (!document.valid()) return false;
    if (document.definitions.size() == 1) return true;
    if (document.format != Format::OneLine || document.definitions.size() != 2) return false;
    const Definition &first(document.definitions[0]), &second(document.definitions[1]);
    if (first.enabled != second.enabled || first.types.size() != 1 || second.types.size() != 1 ||
        first.types[0] == second.types[0] || first.fields.size() != second.fields.size()) return false;
    for (std::size_t index(0); index < first.fields.size(); ++index)
        if (first.fields[index].name != second.fields[index].name ||
            first.fields[index].value != second.fields[index].value) return false;
    Definition comparable(second);
    comparable.types = first.types;
    return SemanticKey(first, document.format) == SemanticKey(comparable, document.format);
}

bool SourceWithComponents(const Document &requested, std::size_t ordinal,
                          const std::vector<std::string> &components, std::string *replacement) {
    const Document document(ParseDocument(requested.path, requested.format, requested.bytes));
    if (replacement == NULL || !document.valid() || ordinal >= document.definitions.size()) return false;
    std::string joined;
    for (const std::string &component : components) {
        if (component.empty()) return false;
        for (unsigned char character : component)
            if (character <= 32 || character == '#' || character == '"' || character == 127) return false;
        if (!joined.empty()) joined += ' ';
        joined += component;
    }
    const Definition &definition(document.definitions[ordinal]);
    Span span(definition.componentsSpan);
    if (document.format == Format::Deb822) {
        const Field *field(FindField(definition, "components"));
        if (field == NULL || field->value.find('\n') != std::string::npos) return false;
        span = field->firstLineValue;
    }
    std::string output(definition.original);
    output.replace(span.begin - definition.span.begin, span.end - span.begin, joined);
    const Document parsed(ParseDocument(document.path, document.format, output));
    if (!parsed.valid() || parsed.definitions.size() != 1) return false;
    *replacement = output;
    return true;
}

ProtectionSelector SelectorForDefinition(const std::string &setIdentifier, const Definition &definition) {
    ProtectionSelector selector; selector.setIdentifier = setIdentifier; selector.originPath = definition.path;
    selector.semanticKey = definition.semanticKey; selector.uris = definition.uris; return selector;
}

ProtectionResult EvaluateProtection(const std::vector<Document> &documents,
                                    const std::vector<ProtectionSelector> &policy,
                                    const std::string &path, std::size_t ordinal) {
    ProtectionResult result;
    for (const ProtectionSelector &selector : policy) {
        std::vector<const Definition *> exact;
        bool invalid(false);
        for (const Document &document : documents) {
            invalid = invalid || !document.valid();
            for (const Definition &definition : document.definitions) {
                if (definition.semanticKey == selector.semanticKey) exact.push_back(&definition);
            }
        }
        const bool unresolved(invalid || selector.setIdentifier.empty() || selector.semanticKey.empty() ||
                              exact.size() != 1 || exact[0]->path != selector.originPath);
        if (unresolved) {
            // Without a resolved policy reference any ordinary write could be
            // the stripped/replaced protected definition. Require review.
            result.state = ProtectionState::ReviewRequired;
            result.detail = "Protected source policy no longer resolves uniquely at its original file; review Advanced Settings";
            AddSet(&result, selector.setIdentifier);
            continue;
        }
        for (const Definition *definition : exact) {
            if (definition->path != path || definition->ordinal != ordinal) continue;
            AddSet(&result, selector.setIdentifier);
            if (result.state == ProtectionState::Unprotected) result.state = ProtectionState::Protected;
        }
    }
    return result;
}

EditResult PlanMutation(const Document &requestedSnapshot, const std::string &currentBytes,
                        const Mutation &mutation, const std::vector<Document> &documents,
                        const std::vector<ProtectionSelector> &policy, Access access) {
    if (requestedSnapshot.bytes != currentBytes)
        return Failure(EditStatus::StaleDocument, requestedSnapshot, "Source file changed; reload before editing");
    // Spans and semantic selectors are always derived from exact file bytes,
    // never trusted from a caller-supplied DTO or a cached native model.
    const Document snapshot(ParseDocument(requestedSnapshot.path, requestedSnapshot.format, requestedSnapshot.bytes));
    if (!snapshot.valid()) return Failure(EditStatus::InvalidDocument, snapshot, "Cannot edit an invalid source document");
    const bool whole(mutation.kind == EditKind::AppendDefinition || mutation.kind == EditKind::ReplaceDocument);
    if (!whole && mutation.ordinal >= snapshot.definitions.size())
        return Failure(EditStatus::InvalidMutation, snapshot, "Source definition is absent from this snapshot");

    std::vector<Document> current(documents);
    bool found(false);
    for (Document &document : current)
        if (document.path == snapshot.path) {
            if (found || document.bytes != snapshot.bytes)
                return Failure(EditStatus::StaleDocument, snapshot, "Protection snapshot does not match source file");
            document = snapshot; found = true;
        }
    if (!found) current.push_back(snapshot);
    if (access == Access::Ordinary && !policy.empty()) {
        const std::size_t ordinal(whole ? std::string::npos : mutation.ordinal);
        ProtectionResult protection(EvaluateProtection(current, policy, snapshot.path, ordinal));
        if (protection.state == ProtectionState::ReviewRequired)
            return Failure(EditStatus::ProtectionReviewRequired, snapshot, protection.detail.c_str());
        if (protection.state == ProtectionState::Protected)
            return Failure(EditStatus::ProtectedDefinition, snapshot, "Protected source can only change in Advanced Settings");
        if (mutation.kind == EditKind::ReplaceDocument)
            for (const Definition &definition : snapshot.definitions) {
                protection = EvaluateProtection(current, policy, snapshot.path, definition.ordinal);
                if (protection.state != ProtectionState::Unprotected)
                    return Failure(EditStatus::ProtectedDefinition, snapshot, "Import cannot overwrite a protected source document");
            }
    }

    std::string updated(snapshot.bytes);
    if (mutation.kind == EditKind::RemoveDefinition) {
        const Definition &definition(snapshot.definitions[mutation.ordinal]);
        updated.replace(definition.span.begin, definition.span.end - definition.span.begin,
                        snapshot.format == Format::Deb822 ? CommentsOnly(definition.original) : std::string());
    } else if (mutation.kind == EditKind::SetEnabled) {
        const Definition &definition(snapshot.definitions[mutation.ordinal]);
        const Field *enabled(FindField(definition, "enabled"));
        if (enabled && enabled->value.find('\n') != std::string::npos)
            return Failure(EditStatus::InvalidMutation, snapshot, "Cannot rewrite a folded Enabled field");
        updated.replace(definition.span.begin, definition.span.end - definition.span.begin,
                        EnabledReplacement(snapshot, definition, mutation.enabled));
    } else {
        const Document replacement(ParseDocument(snapshot.path, snapshot.format, mutation.contents));
        if (!replacement.valid() ||
            (mutation.kind == EditKind::AppendDefinition && !IsSingleSourceAddition(replacement)) ||
            (mutation.kind == EditKind::ReplaceDefinition && !IsSingleSourceAddition(replacement)))
            return Failure(EditStatus::InvalidMutation, snapshot, "Replacement must be a valid source definition");
        if (mutation.kind == EditKind::ReplaceDocument) updated = mutation.contents;
        else if (mutation.kind == EditKind::ReplaceDefinition) {
            const Definition &definition(snapshot.definitions[mutation.ordinal]);
            std::string bytes(mutation.contents);
            if (definition.span.end < snapshot.bytes.size() && !bytes.empty() && bytes.back() != '\n') bytes += Newline(snapshot);
            updated.replace(definition.span.begin, definition.span.end - definition.span.begin, bytes);
        } else {
            if (!updated.empty() && updated.back() != '\n') updated += Newline(snapshot);
            if (snapshot.format == Format::Deb822 && !updated.empty()) updated += Newline(snapshot);
            updated += mutation.contents;
        }
    }
    const Document after(ParseDocument(snapshot.path, snapshot.format, updated));
    if (!after.valid()) return Failure(EditStatus::InvalidMutation, snapshot, "Edit would produce an invalid source document");
    if (access == Access::Ordinary && !policy.empty()) {
        for (Document &document : current) if (document.path == snapshot.path) document = after;
        // Check every mutation path, including replacement and whole-file
        // import. A formerly unrelated record must not become a second match
        // for a protected selector. The sentinel also checks an empty result.
        const ProtectionResult protection(EvaluateProtection(current, policy, snapshot.path, std::string::npos));
        if (protection.state == ProtectionState::ReviewRequired)
            return Failure(EditStatus::ProtectionReviewRequired, snapshot, "Edit would duplicate or alter protected source selection");
    }
    EditResult result; result.status = updated == snapshot.bytes ? EditStatus::NoChange : EditStatus::Ready;
    result.original = snapshot.bytes; result.updated = updated; return result;
}
} // namespace CydiaSources
