/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDraft.hpp"

#include <algorithm>
#include <cstdint>
#include <iomanip>
#include <map>
#include <set>
#include <sstream>

namespace CydiaSources {
namespace {
bool Space(unsigned char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
std::string Lower(std::string value) {
    for (char &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}
std::string Trim(const std::string &value) {
    std::size_t begin(0), end(value.size());
    while (begin < end && Space(value[begin])) ++begin;
    while (end > begin && Space(value[end - 1])) --end;
    return value.substr(begin, end - begin);
}
std::vector<std::string> Words(std::string value, bool commas = false) {
    if (commas) std::replace(value.begin(), value.end(), ',', ' ');
    std::vector<std::string> result;
    std::istringstream input(value);
    for (std::string word; input >> word;) result.push_back(word);
    return result;
}
std::string Join(const std::vector<std::string> &values, const char *separator = " ") {
    std::string result;
    for (const std::string &value : values) {
        if (!result.empty()) result += separator;
        result += value;
    }
    return result;
}
std::vector<std::string> Sorted(std::vector<std::string> values) {
    std::sort(values.begin(), values.end());
    values.erase(std::unique(values.begin(), values.end()), values.end());
    return values;
}
bool Overlap(const std::vector<std::string> &a, const std::vector<std::string> &b) {
    for (const std::string &value : a)
        if (std::find(b.begin(), b.end(), value) != b.end()) return true;
    return false;
}
void Diagnose(std::vector<DraftDiagnostic> *diagnostics, const char *code, const char *field,
              const char *detail, bool blocking = true, const std::string &path = std::string(),
              std::size_t ordinal = std::string::npos) {
    DraftDiagnostic diagnostic;
    diagnostic.code = code; diagnostic.field = field; diagnostic.detail = detail;
    diagnostic.blocking = blocking; diagnostic.path = path; diagnostic.ordinal = ordinal;
    diagnostics->push_back(diagnostic);
}
bool Token(const std::string &value) {
    if (value.empty()) return false;
    for (unsigned char c : value)
        if (c <= 32 || c == 127 || c == '#' || c == '"' || c == '[' || c == ']') return false;
    return true;
}
bool Tokens(const std::vector<std::string> &values) {
    for (const std::string &value : values) if (!Token(value)) return false;
    return Sorted(values).size() == values.size();
}
bool URI(const std::string &value) {
    if (value.empty()) return false;
    for (unsigned char c : value) if (c <= 32 || c == 127 || c == '"' || c == '#') return false;
    const std::size_t colon(value.find(':'));
    if (colon == std::string::npos || colon == 0 || colon + 1 == value.size()) return false;
    for (std::size_t i(0); i < colon; ++i) {
        const char c(value[i]);
        const bool alpha((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'));
        if (!alpha && (i == 0 || !((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'))) return false;
    }
    return true;
}
bool Architectures(const std::vector<std::string> &values) {
    if (Sorted(values).size() != values.size()) return false;
    for (const std::string &value : values) {
        if (value.empty()) return false;
        for (char c : value)
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    }
    return true;
}
bool SigningValues(const std::string &value) {
    if (value.empty()) return true;
    for (unsigned char c : value)
        if ((c < 32 && c != '\t') || c == 127 || c == '#' || c == '"' || c == '[' || c == ']') return false;
    const std::vector<std::string> tokens(Words(value, true));
    if (tokens.empty()) return false;
    for (std::string token : tokens) {
        if (token[0] == '/') continue;
        if (token.back() == '!') token.pop_back();
        if (token.size() != 40 && token.size() != 64) return false;
        for (char c : token)
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
    }
    return true;
}
/* Classic APT tokens percent-decode, even when quoted. Escape '%' so a URL's
 * own escapes survive, and quote only when needed for an option's separators. */
std::string ClassicToken(const std::string &value) {
    std::string result;
    for (char c : value) result += c == '%' ? "%25" : std::string(1, c);
    return result;
}
std::string Serialize(const SourceDraft &draft) {
    if (draft.raw) return draft.rawContents;
    if (draft.format == Format::Deb822) {
        std::string result("Types: deb");
        if (draft.includeSourcePackages) result += " deb-src";
        result += "\nURIs: " + draft.uri + "\nSuites: " + draft.distribution + "\n";
        if (!draft.components.empty()) result += "Components: " + Join(draft.components) + "\n";
        if (draft.architectureMode == ArchitectureMode::Replace)
            result += "Architectures: " + Join(draft.architectures) + "\n";
        if (draft.architectureMode == ArchitectureMode::Modify) {
            if (!draft.architecturesAdd.empty()) result += "Architectures-Add: " + Join(draft.architecturesAdd) + "\n";
            if (!draft.architecturesRemove.empty()) result += "Architectures-Remove: " + Join(draft.architecturesRemove) + "\n";
        }
        if (!draft.signedBy.empty()) result += "Signed-By: " + Join(Words(draft.signedBy, true)) + "\n";
        if (!draft.enabled) result += "Enabled: no\n";
        return result;
    }
    std::vector<std::string> options;
    if (draft.architectureMode == ArchitectureMode::Replace)
        options.push_back("arch=" + Join(draft.architectures, ","));
    if (draft.architectureMode == ArchitectureMode::Modify) {
        if (!draft.architecturesAdd.empty()) options.push_back("arch+=" + Join(draft.architecturesAdd, ","));
        if (!draft.architecturesRemove.empty()) options.push_back("arch-=" + Join(draft.architecturesRemove, ","));
    }
    if (!draft.signedBy.empty()) options.push_back("signed-by=" + ClassicToken(Join(Words(draft.signedBy, true), ",")));
    std::string body;
    if (!options.empty()) body = "[" + Join(options) + "] ";
    body += ClassicToken(draft.uri) + " " + ClassicToken(draft.distribution);
    for (const std::string &component : draft.components) body += " " + ClassicToken(component);
    body += '\n';
    const std::string prefix(draft.enabled ? "" : "# ");
    std::string result(prefix + "deb " + body);
    if (draft.includeSourcePackages) result += prefix + "deb-src " + body;
    return result;
}
void ValidateStructured(const SourceDraft &draft, std::vector<DraftDiagnostic> *diagnostics) {
    if (!URI(draft.uri)) Diagnose(diagnostics, "invalid_uri", "uri", "Enter a source URI without spaces, fragments or control characters");
    if (!Token(draft.distribution) || (draft.distribution.back() == '/') != draft.exactPath)
        Diagnose(diagnostics, "invalid_distribution", "distribution", "Exact paths must end with a slash; suites must not end with a slash");
    if (!Tokens(draft.components) || (draft.exactPath ? !draft.components.empty() : draft.components.empty()))
        Diagnose(diagnostics, "invalid_components", "components", "Exact paths have no components; suite sources need at least one component");
    if (!Architectures(draft.architectures) || !Architectures(draft.architecturesAdd) || !Architectures(draft.architecturesRemove) ||
        (draft.architectureMode == ArchitectureMode::Replace && (draft.architectures.empty() || !draft.architecturesAdd.empty() || !draft.architecturesRemove.empty())) ||
        (draft.architectureMode == ArchitectureMode::Inherit && (!draft.architectures.empty() || !draft.architecturesAdd.empty() || !draft.architecturesRemove.empty())) ||
        (draft.architectureMode == ArchitectureMode::Modify && (!draft.architectures.empty() || Overlap(draft.architecturesAdd, draft.architecturesRemove))))
        Diagnose(diagnostics, "invalid_architectures", "architectures", "Choose inherited architectures, a replacement list, or nonconflicting additions and removals");
    if (!SigningValues(draft.signedBy))
        Diagnose(diagnostics, "invalid_signed_by", "signedBy", "Signed-By must contain absolute keyring paths or full fingerprints");
}
std::string OptionName(const Field &field, Format format) {
    if (format == Format::Deb822) return Lower(field.name);
    if (field.name == "arch") return "architectures";
    if (field.name == "arch+") return "architectures-add";
    if (field.name == "arch-") return "architectures-remove";
    if (field.name == "lang") return "languages";
    if (field.name == "lang+") return "languages-add";
    if (field.name == "lang-") return "languages-remove";
    return field.name;
}
bool Structural(const std::string &name, Format format) {
    return format == Format::Deb822 && (name == "types" || name == "uris" || name == "suites" || name == "components" || name == "enabled");
}
typedef std::map<std::string, std::string> Options;
Options SourceOptions(const Definition &definition, Format format) {
    Options options;
    for (const Field &field : definition.fields) {
        const std::string name(OptionName(field, format));
        if (Structural(name, format) || Lower(name).compare(0, 2, "x-") == 0) continue;
        std::string value(Trim(field.value));
        if (name == "architectures" || name == "architectures-add" || name == "architectures-remove" ||
            name == "languages" || name == "languages-add" || name == "languages-remove" || name == "signed-by") {
            // Inline public keys are compared byte-for-byte, not tokenized.
            if (value.find("-----BEGIN PGP") == std::string::npos)
                value = Join(Sorted(Words(value, format == Format::OneLine)));
        } else {
            const std::string lower(Lower(value));
            if (lower == "true" || lower == "1" || lower == "on") value = "yes";
            if (lower == "false" || lower == "0" || lower == "off") value = "no";
        }
        options[name] = value;
    }
    return options;
}
bool ReleaseConflict(const Options &a, const Options &b) {
    // These configure the shared Release object, not an individual index.
    const char *names[] = {"signed-by", "trusted", "allow-insecure", "allow-weak",
        "allow-downgrade-to-insecure", "check-valid-until", "valid-until-min",
        "valid-until-max", "check-date", "date-max-future", "inrelease-path"};
    for (const char *name : names) {
        const Options::const_iterator ai(a.find(name)), bi(b.find(name));
        if (ai == a.end() && bi == b.end()) continue;
        if (ai == a.end() || bi == b.end() || ai->second != bi->second) return true;
    }
    return false;
}
std::string RepositoryURI(std::string uri) {
    // APT treats the source base URI as a directory. Preserve case, credentials,
    // escapes and schemes; none can safely be discarded for identity matching.
    if (!uri.empty() && uri.back() != '/') uri += '/';
    return uri;
}
std::vector<std::string> RepositoryURIs(const Definition &definition) {
    std::vector<std::string> uris;
    for (const std::string &uri : definition.uris) uris.push_back(RepositoryURI(uri));
    return uris;
}
void CheckExisting(const Document &candidate, const std::vector<Document> &documents,
                   const std::string &ignorePath, std::size_t ignoreOrdinal,
                   std::vector<DraftDiagnostic> *diagnostics) {
    for (const Document &input : documents) {
        const Document document(ParseDocument(input.path, input.format, input.bytes));
        if (!document.valid()) {
            Diagnose(diagnostics, "existing_document_invalid", "existingSources", "An existing source document cannot be parsed", true, document.path);
            continue;
        }
        for (const Definition &existing : document.definitions) {
            if (document.path == ignorePath && existing.ordinal == ignoreOrdinal) continue;
            bool conflict(false), duplicate(false), active(false);
            for (const Definition &added : candidate.definitions) {
                if (!Overlap(RepositoryURIs(added), RepositoryURIs(existing)) || !Overlap(added.suites, existing.suites)) continue;
                const bool bothEnabled(added.enabled && existing.enabled);
                const Options a(SourceOptions(added, candidate.format)), b(SourceOptions(existing, document.format));
                if (ReleaseConflict(a, b)) {
                    conflict = true; active = active || bothEnabled;
                } else if (Overlap(added.types, existing.types) &&
                    ((added.components.empty() && existing.components.empty()) || Overlap(added.components, existing.components))) {
                    // Disjoint explicit architecture filters acquire distinct
                    // indexes and may legitimately coexist. Inherited/modified
                    // filters cannot be resolved without runtime APT settings.
                    const Options::const_iterator aa(a.find("architectures")), ba(b.find("architectures"));
                    if (aa != a.end() && ba != b.end() && !Overlap(Words(aa->second), Words(ba->second))) continue;
                    duplicate = true; active = active || bothEnabled;
                }
            }
            if (conflict) Diagnose(diagnostics, "conflicting_options", "existingSources", "This repository already has conflicting Release or trust options", active, document.path, existing.ordinal);
            else if (duplicate) Diagnose(diagnostics, "duplicate_source", "existingSources", "This source overlaps an existing package index", active, document.path, existing.ordinal);
        }
    }
}
bool HasComments(const Document &document) {
    if (document.format == Format::Deb822) {
        std::istringstream lines(document.bytes);
        for (std::string line; std::getline(lines, line);)
            if (!line.empty() && line[0] == '#') return true;
        return false;
    }
    std::string remaining(document.bytes);
    // Disabling markers are represented by the enabled field; other comments
    // have no structured counterpart and must remain in raw mode.
    for (const Definition &definition : document.definitions)
        if (!definition.enabled && definition.commentOffset < remaining.size()) remaining[definition.commentOffset] = ' ';
    return remaining.find('#') != std::string::npos;
}
} // namespace

SourceDraft::SourceDraft() : raw(false), format(Format::OneLine), exactPath(true), distribution("./"),
    architectureMode(ArchitectureMode::Inherit), includeSourcePackages(false), enabled(true) {}

bool DraftResult::valid() const {
    if (!document.valid()) return false;
    for (const DraftDiagnostic &diagnostic : diagnostics) if (diagnostic.blocking) return false;
    return true;
}

SourceDraft ImportSourceDraft(const std::string &bytes, Format format) {
    SourceDraft draft; draft.raw = true; draft.format = format; draft.rawContents = bytes; return draft;
}

DraftResult BuildSourceDraft(const SourceDraft &draft, const std::string &path,
    const std::vector<Document> &existingDocuments, const std::string &ignorePath, std::size_t ignoreOrdinal) {
    DraftResult result;
    result.document.path = path; result.document.format = draft.format;
    if (!draft.raw) {
        ValidateStructured(draft, &result.diagnostics);
        if (!result.diagnostics.empty()) return result;
    }
    result.document = ParseDocument(path, draft.format, Serialize(draft));
    if (!result.document.valid()) Diagnose(&result.diagnostics, "invalid_document", "rawContents", "The source definition is not valid APT source syntax");
    else if (!IsSingleSourceAddition(result.document)) Diagnose(&result.diagnostics, "multiple_sources", "rawContents", "Add one source definition or a matching deb/deb-src pair at a time");
    else CheckExisting(result.document, existingDocuments, ignorePath, ignoreOrdinal, &result.diagnostics);
    return result;
}

bool ConvertDraftToStructured(const SourceDraft &raw, SourceDraft *structured,
                             std::vector<DraftDiagnostic> *diagnostics) {
    if (structured == NULL) return false;
    if (!raw.raw) { *structured = raw; return true; }
    const DraftResult result(BuildSourceDraft(raw, ""));
    bool supported(result.valid() && !result.document.definitions.empty());
    SourceDraft converted; converted.format = raw.format;
    if (supported) {
        const Definition &definition(result.document.definitions[result.document.definitions.size() == 2 &&
            result.document.definitions.front().types.front() == "deb-src" ? 1 : 0]);
        supported = definition.uris.size() == 1 && definition.suites.size() == 1 &&
            std::find(definition.types.begin(), definition.types.end(), "deb") != definition.types.end() &&
            Sorted(definition.types).size() == definition.types.size() && !HasComments(result.document);
        if (supported) {
            converted.uri = definition.uris[0]; converted.distribution = definition.suites[0];
            converted.exactPath = !converted.distribution.empty() && converted.distribution.back() == '/';
            converted.components = definition.components; converted.enabled = definition.enabled;
            converted.includeSourcePackages = definition.types.size() > 1 || result.document.definitions.size() > 1;
            std::set<std::string> found;
            for (const Field &field : definition.fields) {
                const std::string name(OptionName(field, raw.format));
                if (Structural(name, raw.format)) {
                    if (field.value.find('\n') != std::string::npos) supported = false;
                    continue;
                }
                if (!found.insert(name).second || field.value.find('\n') != std::string::npos) supported = false;
                if (name == "architectures") { converted.architectureMode = ArchitectureMode::Replace; converted.architectures = Words(field.value, raw.format == Format::OneLine); }
                else if (name == "architectures-add") converted.architecturesAdd = Words(field.value, raw.format == Format::OneLine);
                else if (name == "architectures-remove") converted.architecturesRemove = Words(field.value, raw.format == Format::OneLine);
                else if (name == "signed-by") converted.signedBy = Join(Words(field.value, raw.format == Format::OneLine));
                else supported = false;
            }
            if (!converted.architecturesAdd.empty() || !converted.architecturesRemove.empty()) {
                if (converted.architectureMode == ArchitectureMode::Replace) supported = false;
                converted.architectureMode = ArchitectureMode::Modify;
            }
            if (supported && !BuildSourceDraft(converted, "").valid()) supported = false;
        }
    }
    if (!supported) {
        if (diagnostics != NULL) Diagnose(diagnostics, "unsupported_conversion", "rawContents", "Keep this definition in raw mode to preserve its comments, options or multiple values");
        return false;
    }
    *structured = converted;
    return true;
}

std::string SuggestedSourceFilename(const SourceDraft &draft, const std::vector<std::string> &existingBasenames) {
    const DraftResult result(BuildSourceDraft(draft, ""));
    std::string identity(draft.uri);
    if (!result.document.definitions.empty() && !result.document.definitions[0].uris.empty()) identity = result.document.definitions[0].uris[0];
    // Derive the readable part from the host only; do not expose credentials,
    // query tokens or arbitrary URL paths in configuration filenames.
    std::string label("source");
    const std::size_t scheme(identity.find("://"));
    if (scheme != std::string::npos) {
        const std::size_t begin(scheme + 3), end(identity.find_first_of("/?#", begin));
        std::string authority(identity.substr(begin, end == std::string::npos ? end : end - begin));
        const std::size_t credentials(authority.rfind('@'));
        if (credentials != std::string::npos) authority.erase(0, credentials + 1);
        label.clear();
        for (char c : Lower(authority)) {
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') label += c;
            else if (label.empty() || label.back() != '-') label += '-';
            if (label.size() == 48) break;
        }
        while (!label.empty() && label.back() == '-') label.pop_back();
        if (label.empty()) label = "source";
    }
    // FNV-1a is a stable filename discriminator, never a security fingerprint.
    std::uint64_t digest(UINT64_C(14695981039346656037));
    const std::string bytes(Serialize(draft));
    for (unsigned char c : bytes) { digest ^= c; digest *= UINT64_C(1099511628211); }
    std::ostringstream hash; hash << std::hex << std::setw(16) << std::setfill('0') << digest;
    const std::string stem("cydia-" + label + "-" + hash.str());
    const std::string extension(draft.format == Format::Deb822 ? ".sources" : ".list");
    std::set<std::string> existing(existingBasenames.begin(), existingBasenames.end());
    std::string candidate(stem + extension);
    for (std::size_t suffix(2); existing.count(candidate); ++suffix) candidate = stem + "-" + std::to_string(suffix) + extension;
    return candidate;
}
} // namespace CydiaSources
