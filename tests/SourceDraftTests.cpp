/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDraft.hpp"

#include <cstdlib>
#include <iostream>

using namespace CydiaSources;

namespace {
void Expect(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "[source-draft][FAIL] " << message << std::endl;
    std::exit(1);
}
bool HasCode(const DraftResult &result, const char *code, bool blocking = true) {
    for (const DraftDiagnostic &diagnostic : result.diagnostics)
        if (diagnostic.code == code && diagnostic.blocking == blocking) return true;
    return false;
}
void StructuredSources() {
    SourceDraft draft; draft.uri = "https://packages.example/";
    DraftResult result(BuildSourceDraft(draft, "/sources/user.list"));
    Expect(result.valid() && result.document.bytes == "deb https://packages.example/ ./\n",
           "simple flat addition inherits architecture and trust without adding options");
    draft.exactPath = false; draft.distribution = "iphoneos-arm64-rootless/1800";
    draft.components = {"main"}; draft.architectureMode = ArchitectureMode::Replace;
    draft.architectures = {"iphoneos-arm64"}; draft.includeSourcePackages = true;
    draft.signedBy = "/configured/keyrings/vendor.gpg";
    result = BuildSourceDraft(draft, "/sources/user.list");
    Expect(result.valid() && result.document.definitions.size() == 2 &&
           result.document.definitions[0].suites[0] == "iphoneos-arm64-rootless/1800",
           "suite paths survive exactly and classic binary/source pair remains one addition");
    const Document target(ParseDocument("/sources/user.list", Format::OneLine, "# existing notes\n"));
    Mutation append(EditKind::AppendDefinition); append.contents = result.document.bytes;
    Expect(PlanMutation(target, target.bytes, append).accepted(), "matching binary/source pair can append atomically");
    draft.format = Format::Deb822;
    result = BuildSourceDraft(draft, "/sources/user.sources");
    Expect(result.valid() && result.document.definitions.size() == 1 && result.document.definitions[0].types.size() == 2 &&
           result.document.bytes.find("Architectures: iphoneos-arm64\n") != std::string::npos,
           "Deb822 represents the same source pair as one stanza");
    draft.architectureMode = ArchitectureMode::Modify; draft.architectures.clear();
    draft.architecturesAdd = {"iphoneos-arm64e"}; draft.architecturesRemove = {"iphoneos-arm"};
    result = BuildSourceDraft(draft, "/sources/user.sources");
    Expect(result.valid() && result.document.bytes.find("Architectures-Add: iphoneos-arm64e\n") != std::string::npos &&
           result.document.bytes.find("Architectures-Remove: iphoneos-arm\n") != std::string::npos,
           "architecture additions and removals keep their APT semantics");
    draft.enabled = false;
    Expect(BuildSourceDraft(draft, "new.sources").document.bytes.find("Enabled: no\n") != std::string::npos,
           "saving disabled emits APT state instead of changing a separate cache");
}
void InputBoundaries() {
    SourceDraft draft; draft.uri = "https://packages.example/";
    draft.components = {"main"};
    Expect(HasCode(BuildSourceDraft(draft, "new.list"), "invalid_components"), "flat source cannot accidentally acquire components");
    draft.components.clear(); draft.exactPath = false; draft.distribution = "stable";
    Expect(HasCode(BuildSourceDraft(draft, "new.list"), "invalid_components"), "suite source needs a component");
    draft.components = {"main\nTrusted: yes"};
    Expect(!BuildSourceDraft(draft, "new.sources").valid(), "structured field cannot inject configuration");
    draft.components = {"main"}; draft.uri = "https://packages.example/\nTypes: deb-src";
    Expect(HasCode(BuildSourceDraft(draft, "new.list"), "invalid_uri"), "URI cannot inject additional lines");
    draft.uri = "mirror+https://packages.example/";
    Expect(BuildSourceDraft(draft, "new.list").valid(), "custom APT transports are syntax-valid without hardcoded HTTP assumptions");
    draft.architectureMode = ArchitectureMode::Modify;
    draft.architecturesAdd = {"iphoneos-arm64"}; draft.architecturesRemove = {"iphoneos-arm64"};
    Expect(HasCode(BuildSourceDraft(draft, "new.list"), "invalid_architectures"), "contradictory architecture changes rejected");
    draft.architectureMode = ArchitectureMode::Inherit; draft.architecturesAdd.clear(); draft.architecturesRemove.clear();
    draft.signedBy = "key.gpg";
    Expect(HasCode(BuildSourceDraft(draft, "new.list"), "invalid_signed_by"), "keyring path must be absolute");
    draft.signedBy = "C101A4205F8616491D9B23BAB4532449E1E8AA68!";
    Expect(BuildSourceDraft(draft, "new.list").valid(), "full signing fingerprint can constrain an existing trusted key");
}
void LosslessImports() {
    const std::string raw("# maintainer note\r\ndeb [custom=keep arch=iphoneos-arm64] https://packages.example/ stable main # note\r\n"
                          "deb-src [custom=keep arch=iphoneos-arm64] https://packages.example/ stable main\r\n");
    const SourceDraft imported(ImportSourceDraft(raw, Format::OneLine));
    const DraftResult result(BuildSourceDraft(imported, "new.list"));
    Expect(result.valid() && result.document.bytes == raw, "raw pair retains comments, options and CRLF byte-exact");
    SourceDraft structured;
    Expect(!ConvertDraftToStructured(imported, &structured), "structured conversion cannot silently discard unknown options or comments");
    const SourceDraft known(ImportSourceDraft("deb-src [arch+=iphoneos-arm64e] https://packages.example/ stable main\n"
                                           "deb [arch+=iphoneos-arm64e] https://packages.example/ stable main\n", Format::OneLine));
    Expect(ConvertDraftToStructured(known, &structured) && structured.includeSourcePackages &&
           structured.architectureMode == ArchitectureMode::Modify && structured.architecturesAdd[0] == "iphoneos-arm64e",
           "matching pair converts even when source packages appear first");
    const SourceDraft opaque(ImportSourceDraft("Types: deb\nURIs: https://packages.example/\nSuites: stable\nComponents: main\n"
        "X-Maintainer: keep\n continuation\n", Format::Deb822));
    Expect(BuildSourceDraft(opaque, "new.sources").valid() && !ConvertDraftToStructured(opaque, &structured),
           "unknown Deb822 fields remain importable without destructive conversion");
    const SourceDraft inlineKey(ImportSourceDraft("Types: deb\nURIs: https://packages.example/\nSuites: ./\nSigned-By:\n"
        " -----BEGIN PGP PUBLIC KEY BLOCK-----\n .\n public-key-data\n -----END PGP PUBLIC KEY BLOCK-----\n", Format::Deb822));
    Expect(BuildSourceDraft(inlineKey, "new.sources").valid() && !ConvertDraftToStructured(inlineKey, &structured),
           "embedded signing keys remain unchanged in raw mode");
    const SourceDraft multi(ImportSourceDraft("deb https://one.example/ ./\ndeb https://two.example/ ./\n", Format::OneLine));
    Expect(HasCode(BuildSourceDraft(multi, "new.list"), "multiple_sources"), "bulk import cannot hide unrelated sources in one add operation");
    const SourceDraft mismatch(ImportSourceDraft("deb [trusted=yes] https://packages.example/ ./\n"
                                              "deb-src https://packages.example/ ./\n", Format::OneLine));
    Expect(!BuildSourceDraft(mismatch, "new.list").valid(), "binary/source pair cannot conceal differing trust configuration");
}
void ExistingSources() {
    SourceDraft draft; draft.uri = "https://packages.example"; draft.exactPath = false;
    draft.distribution = "stable"; draft.components = {"main"};
    const Document existing(ParseDocument("/effective/vendor.sources", Format::Deb822,
        "Types: deb\nURIs: https://packages.example/\nSuites: stable\nComponents: main extra\n"));
    DraftResult result(BuildSourceDraft(draft, "new.list", {existing}));
    Expect(HasCode(result, "duplicate_source") && result.diagnostics[0].path == existing.path,
           "cross-format overlap identifies its owning file even when component sets differ");
    Expect(BuildSourceDraft(draft, existing.path, {existing}, existing.path, 0).valid(),
           "editing can exclude exactly its original definition");
    draft.components = {"testing"};
    Expect(BuildSourceDraft(draft, "new.list", {existing}).valid(), "distinct components may share a Release");
    draft.signedBy = "/keys/replacement.gpg";
    Expect(HasCode(BuildSourceDraft(draft, "new.list", {existing}), "conflicting_options"),
           "conflicting Release trust is rejected even across different components");
    draft.signedBy.clear(); draft.components = {"main"}; draft.enabled = false;
    Expect(BuildSourceDraft(draft, "new.list", {existing}).valid() &&
           HasCode(BuildSourceDraft(draft, "new.list", {existing}), "duplicate_source", false),
           "disabled draft reports overlap without blocking intentional disabled save");
    draft.enabled = true; draft.architectureMode = ArchitectureMode::Replace; draft.architectures = {"iphoneos-arm64e"};
    const Document disjoint(ParseDocument("/effective/foreign.list", Format::OneLine,
        "deb [arch=iphoneos-arm64] https://packages.example/ stable main\n"));
    Expect(BuildSourceDraft(draft, "new.list", {disjoint}).valid(), "explicit disjoint index architecture filters are not duplicates");
    const Document broken(ParseDocument("/effective/broken.list", Format::OneLine, "deb broken\n"));
    Expect(HasCode(BuildSourceDraft(draft, "new.list", {broken}), "existing_document_invalid"),
           "invalid existing state cannot claim a clean duplicate check");
}
void FilenameCollisions() {
    SourceDraft draft; draft.uri = "https://user:secret@packages.example/path?token=hidden";
    const std::string first(SuggestedSourceFilename(draft, {}));
    const std::string second(SuggestedSourceFilename(draft, {first}));
    Expect(first != second && first.find('/') == std::string::npos && first.find("secret") == std::string::npos &&
           first.find("hidden") == std::string::npos && first.find("packages-example") != std::string::npos,
           "suggestion avoids collisions and never leaks URL credentials or query data");
    Expect(SuggestedSourceFilename(draft, {first, second}) != second, "multiple existing names remain untouched");
    draft.format = Format::Deb822;
    const std::string deb822(SuggestedSourceFilename(draft, {}));
    Expect(deb822.substr(deb822.size() - 8) == ".sources", "filename extension retains document format");
}
} // namespace

int main() {
    StructuredSources(); InputBoundaries(); LosslessImports(); ExistingSources(); FilenameCollisions();
    std::cout << "Source draft tests passed" << std::endl;
    return 0;
}
