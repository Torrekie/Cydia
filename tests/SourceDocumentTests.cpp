/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDocument.hpp"
#include "Cydia/SourceDocumentStore.hpp"

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

using namespace CydiaSources;

namespace {
void Expect(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "[source-document][FAIL] " << message << std::endl;
    std::exit(1);
}
void ClassicEdits() {
    const std::string before(
        "# User notes, not an ownership manifest\r\n"
        "# deb this is an incomplete example, not an enabled source\r\n"
        "deb [signed-by=/usr/share/keyrings/vendor.gpg arch=iphoneos-arm64,iphoneos-arm custom=keep] mirror+https://example.invalid/ stable main # retained\r\n"
        "  # deb-src [custom=opaque] file:/local/repo ./\r\n"
        "deb https://user.invalid/ ./\r\n"
        "# trailing notes\r\n");
    const Document document(ParseDocument("/etc/apt/parts/vendor.list", Format::OneLine, before));
    Expect(document.valid() && document.definitions.size() == 3, "parse active and disabled classic sources");
    Expect(!document.definitions[1].enabled && document.definitions[1].types[0] == "deb-src", "disabled deb-src preserved");
    Expect(document.definitions[0].fields.size() == 3, "preserve arbitrary classic options");
    Expect(document.definitions[1].suites[0] == "./", "exact path suite without components");
    Mutation disable(EditKind::SetEnabled); disable.ordinal = 0; disable.enabled = false;
    EditResult result(PlanMutation(document, before, disable));
    std::string expected(before); expected.insert(document.definitions[0].span.begin, "# ");
    Expect(result.accepted() && result.updated == expected, "disable changes only comment marker");
    const Document disabled(ParseDocument(document.path, document.format, result.updated));
    disable.enabled = true;
    Expect(PlanMutation(disabled, disabled.bytes, disable).updated == before, "classic disable-enable round trip");
    Mutation enable(EditKind::SetEnabled); enable.ordinal = 1;
    result = PlanMutation(document, before, enable);
    expected = before; expected.erase(document.definitions[1].commentOffset, 2);
    Expect(result.updated == expected, "enable retains indentation, options and neighboring lines");
    Mutation remove(EditKind::RemoveDefinition); remove.ordinal = 2;
    result = PlanMutation(document, before, remove);
    expected = before; expected.erase(document.definitions[2].span.begin,
                                      document.definitions[2].span.end - document.definitions[2].span.begin);
    Expect(result.accepted() && result.updated == expected, "remove actual user line, preserve bootstrap bytes");
    Expect(PlanMutation(document, before + "# external edit\n", remove).status == EditStatus::StaleDocument,
           "external edit rejected using exact preimage");
    Mutation append(EditKind::AppendDefinition); append.contents = "deb ssh://host.invalid/repo testing main\n";
    result = PlanMutation(document, before, append);
    Expect(result.accepted() && result.updated == before + append.contents, "append supports custom transports");
    const std::string quotedBytes(
        "deb [signed-by=\"/keys/vendor key.gpg\" custom=\"opaque # text\" custom=\"last ] value\"] \"file:/local/repo with spaces\" ./ # keep this\n"
        "deb https://encoded.invalid/%72epo stable \"main extras\"\n");
    const Document quoted(ParseDocument("/parts/quoted.list", Format::OneLine, quotedBytes));
    Expect(quoted.valid() && quoted.definitions.size() == 2, "quoted classic URI and option values accepted");
    Expect(quoted.definitions[0].uris[0] == "file:/local/repo with spaces" &&
           quoted.definitions[0].fields[2].value == "last ] value", "quoted spaces, hash and bracket decoded without losing original bytes");
    Expect(quoted.definitions[1].uris[0] == "https://encoded.invalid/repo" &&
           quoted.definitions[1].components[0] == "main extras", "classic percent and quote decoding follows APT tokens");
    disable.enabled = false;
    result = PlanMutation(quoted, quoted.bytes, disable);
    Expect(result.accepted() && result.updated == "# " + quotedBytes, "quoted option and duplicate assignments preserved byte-exact");
    const Document cases(ParseDocument("/parts/options.list", Format::OneLine,
        "deb [arch=arm64] https://case.invalid/ ./\n"
        "deb [Arch=arm64] https://case.invalid/ ./\n"));
    Expect(cases.valid() && cases.definitions[0].semanticKey != cases.definitions[1].semanticKey,
           "classic option names remain case-sensitive like APT");
}
void Deb822Edits() {
    const std::string bootstrap(
        "# Shared bootstrap comment\n"
        "Types: deb deb-src\n"
        "URIs: https://one.invalid/\n https://two.invalid/\n"
        "Suites: stable testing\n"
        "Components: main extras\n"
        "Architectures: iphoneos-arm64 iphoneos-arm\n"
        "Signed-By:\n -----BEGIN PGP PUBLIC KEY BLOCK-----\n .\n keydata\n -----END PGP PUBLIC KEY BLOCK-----\n"
        "X-Vendor-Option: opaque value\n more opaque text\n");
    const std::string user("# Preserve this user note\nTypes: deb\nURIs: file:/local/repo\nSuites: ./\nEnabled: no\n");
    const Document document(ParseDocument("/custom/sources.sources", Format::Deb822, bootstrap + "\n" + user));
    Expect(document.valid() && document.definitions.size() == 2, "parse Deb822 stanzas and inline key");
    const Definition &definition(document.definitions[0]);
    Expect(definition.uris.size() == 2 && definition.suites.size() == 2 && definition.types.size() == 2,
           "multi URI, suite and type remains one owning stanza");
    Expect(definition.fields.back().value == "opaque value\nmore opaque text", "unknown folded value exposed without reconstruction");
    const Document foldedHash(ParseDocument("/parts/hash.sources", Format::Deb822,
        "Types: deb\nURIs: https://hash.invalid/\nSuites: ./\nX-Unknown: value\n # continuation, not a comment\n"));
    Expect(foldedHash.valid() && foldedHash.definitions[0].fields.back().value == "value\n# continuation, not a comment",
           "indented hash is folded Deb822 data, not a column-zero comment");
    const Document templateSource(ParseDocument("/parts/template.sources", Format::Deb822,
        "Types: deb\nEnabled: no\n# Fill in URI and suite before enabling\n"));
    Expect(templateSource.valid() && templateSource.definitions.size() == 1 && !templateSource.definitions[0].enabled,
           "disabled incomplete Deb822 templates remain valid like APT");
    Mutation enableTemplate(EditKind::SetEnabled);
    Expect(PlanMutation(templateSource, templateSource.bytes, enableTemplate).status == EditStatus::InvalidMutation,
           "incomplete disabled template cannot become an invalid active source");
    Mutation disable(EditKind::SetEnabled); disable.enabled = false;
    EditResult result(PlanMutation(document, document.bytes, disable));
    Expect(result.accepted() && result.updated == bootstrap + "Enabled: no\n\n" + user,
           "disable inserts only Enabled while preserving inline key and unknown fields");
    Mutation enable(EditKind::SetEnabled); enable.ordinal = 1;
    result = PlanMutation(document, document.bytes, enable);
    std::string enabledUser(user); enabledUser.replace(enabledUser.find("Enabled: no"), 11, "Enabled: yes");
    Expect(result.accepted() && result.updated == bootstrap + "\n" + enabledUser, "enable changes only boolean value");
    Mutation remove(EditKind::RemoveDefinition); remove.ordinal = 1;
    result = PlanMutation(document, document.bytes, remove);
    Expect(result.accepted() && result.updated == bootstrap + "\n# Preserve this user note\n",
           "remove fields of selected stanza while retaining unrelated comments and bootstrap bytes");
    Mutation append(EditKind::AppendDefinition); append.contents = "Types: deb\nURIs: https://extra.invalid/\nSuites: ./";
    result = PlanMutation(document, document.bytes, append);
    Expect(result.accepted() && ParseDocument(document.path, document.format, result.updated).definitions.size() == 3,
           "append separated Deb822 stanza with no terminal newline");
    Mutation replace(EditKind::ReplaceDefinition); replace.ordinal = 1;
    replace.contents = "Types: deb\nURIs: https://changed.invalid/\nSuites: ./\n";
    result = PlanMutation(document, document.bytes, replace);
    Expect(result.accepted() && result.updated.substr(0, bootstrap.size()) == bootstrap,
           "explicit replacement leaves other stanza byte-exact");
    const Document crlf(ParseDocument("/parts/windows.sources", Format::Deb822,
        "Types: deb\r\nURIs: https://crlf.invalid/\r\nSuites: ./"));
    result = PlanMutation(crlf, crlf.bytes, disable);
    Expect(result.updated == crlf.bytes + "\r\nEnabled: no\r\n", "new field keeps CRLF document style");
}
void ComponentEdits() {
    const std::string line("  # deb [signed-by=\"/keys/vendor key.gpg\" custom=keep] https://components.invalid/ stable  main\t extras   # note\r\n");
    const Document classic(ParseDocument("/parts/user.list", Format::OneLine, line));
    std::string replacement;
    Expect(SourceWithComponents(classic, 0, {"main", "additional"}, &replacement) &&
           replacement == "  # deb [signed-by=\"/keys/vendor key.gpg\" custom=keep] https://components.invalid/ stable  main additional   # note\r\n",
           "component edit preserves disabled marker, quoted options, whitespace and comment");
    Mutation edit(EditKind::ReplaceDefinition); edit.contents = replacement;
    Expect(PlanMutation(classic, classic.bytes, edit).accepted(), "component edit is an explicit valid stanza replacement");
    Expect(!SourceWithComponents(classic, 0, {}, &replacement), "removing last component cannot invalidate a non-flat source");
    Expect(!SourceWithComponents(classic, 0, {"main\nEnabled: yes"}, &replacement), "component input cannot inject a source field");
    const Document flat(ParseDocument("/parts/flat.list", Format::OneLine, "deb https://flat.invalid/ ./ # keep\n"));
    Expect(!SourceWithComponents(flat, 0, {"main"}, &replacement), "component edit cannot change flat repository semantics");

    const std::string stanza("# User comment\r\nTypes: deb\r\nURIs: https://components.invalid/\r\nSuites: stable\r\nCoMpOnEnTs:  main extras  \r\nX-Opaque: keep\r\n continuation\r\n");
    const Document deb822(ParseDocument("/parts/user.sources", Format::Deb822, stanza));
    Expect(SourceWithComponents(deb822, 0, {"main", "additional"}, &replacement) &&
           replacement == "# User comment\r\nTypes: deb\r\nURIs: https://components.invalid/\r\nSuites: stable\r\nCoMpOnEnTs:  main additional  \r\nX-Opaque: keep\r\n continuation\r\n",
           "Deb822 component edit preserves field casing, whitespace and unrelated folded data");
    edit.contents = replacement;
    const auto result(PlanMutation(deb822, deb822.bytes, edit));
    Expect(result.accepted() && result.updated.substr(0, 16) == "# User comment\r\n",
           "Deb822 component replacement preserves leading document comments");
    const Document folded(ParseDocument("/parts/folded.sources", Format::Deb822,
        "Types: deb\nURIs: https://folded.invalid/\nSuites: stable\nComponents: main\n extras\n"));
    Expect(!SourceWithComponents(folded, 0, {"main"}, &replacement),
           "compatibility component edit refuses to flatten a folded field");
}
void Protection() {
    const Document a(ParseDocument("/parts/a.sources", Format::Deb822,
        "Types: deb\nURIs: https://boot.invalid/ https://mirror.invalid/\nSuites: stable testing\nComponents: main\n"
        "Signed-By: /keyring.gpg\nX-Cydia-Source-ID: stable-id\n"));
    const Document b(ParseDocument("/parts/b.list", Format::OneLine, "deb https://second.invalid/ ./\n"));
    const Document user(ParseDocument("/parts/user.list", Format::OneLine, "deb https://user.invalid/ ./\n"));
    const std::vector<ProtectionSelector> policy = {
        SelectorForDefinition("bootstrap-main", a.definitions[0]),
        SelectorForDefinition("bootstrap-main", b.definitions[0]),
        SelectorForDefinition("bootstrap-other", b.definitions[0])};
    const std::vector<Document> documents = {a, b, user};
    Expect(EvaluateProtection(documents, policy, b.path, 0).sets.size() == 2, "one source can belong to multiple explicit sets");
    Mutation remove(EditKind::RemoveDefinition);
    Expect(PlanMutation(a, a.bytes, remove, documents, policy).status == EditStatus::ProtectedDefinition,
           "ordinary removal of whole multi-repository stanza denied");
    Mutation disable(EditKind::SetEnabled); disable.enabled = false;
    Expect(PlanMutation(b, b.bytes, disable, documents, policy).status == EditStatus::ProtectedDefinition,
           "ordinary disable protected source denied");
    Document forged(b); forged.definitions[0].semanticKey = "unprotected caller claim";
    forged.definitions[0].span = Span(0, 0);
    Expect(PlanMutation(forged, b.bytes, remove, documents, policy).status == EditStatus::ProtectedDefinition,
           "caller-supplied span and selector claims are rederived from actual bytes");
    Mutation replace(EditKind::ReplaceDefinition); replace.contents = "deb https://else.invalid/ ./\n";
    Expect(PlanMutation(b, b.bytes, replace, documents, policy).status == EditStatus::ProtectedDefinition,
           "ordinary edit or signing-policy replacement denied");
    Mutation imported(EditKind::ReplaceDocument); imported.contents = "";
    Expect(PlanMutation(a, a.bytes, imported, documents, policy).status == EditStatus::ProtectedDefinition,
           "whole document import cannot overwrite protected stanza");
    Expect(PlanMutation(b, b.bytes, remove, documents, policy, Access::AdvancedSettings).accepted(),
           "authenticated integration can plan explicit Advanced Settings removal");
    Expect(PlanMutation(user, user.bytes, remove, documents, policy).accepted(), "ordinary unrelated user source removal allowed");
    std::string stripped(a.bytes); stripped.erase(stripped.find("X-Cydia-Source-ID"));
    const Document rewritten(ParseDocument(a.path, a.format, stripped));
    Expect(EvaluateProtection({rewritten, b, user}, policy, a.path, 0).state == ProtectionState::Protected,
           "metadata stripping does not silently remove protection");
    const Document moved(ParseDocument("/parts/moved.sources", a.format, stripped));
    Expect(EvaluateProtection({moved, b, user}, policy, moved.path, 0).state == ProtectionState::ReviewRequired,
           "moved definition requires advanced review");
    Expect(PlanMutation(user, user.bytes, remove, {moved, b, user}, policy).status == EditStatus::ProtectionReviewRequired,
           "unresolved moved policy cannot silently permit ordinary writes");
    const Document duplicate(ParseDocument("/parts/duplicate.sources", a.format, stripped));
    Expect(EvaluateProtection({a, duplicate, b, user}, policy, duplicate.path, 0).state == ProtectionState::ReviewRequired,
           "ambiguous duplicate selector fails closed");
    const Document changed(ParseDocument(a.path, a.format,
        "Types: deb\nURIs: https://boot.invalid/\nSuites: changed\nComponents: main\n"));
    Expect(PlanMutation(user, user.bytes, remove, {changed, b, user}, policy).status == EditStatus::ProtectionReviewRequired,
           "externally changed unresolved role blocks ordinary mutations rather than unprotecting");
    Expect(EvaluateProtection({b, user}, policy, user.path, 0).state == ProtectionState::ReviewRequired,
           "missing protected source is not recreated and requires review");
    Mutation append(EditKind::AppendDefinition); append.contents = b.bytes;
    Expect(PlanMutation(user, user.bytes, append, documents, policy).status == EditStatus::ProtectionReviewRequired,
           "ordinary append cannot duplicate protected source");
    replace.contents = b.bytes;
    Expect(PlanMutation(user, user.bytes, replace, documents, policy).status == EditStatus::ProtectionReviewRequired,
           "ordinary replacement cannot turn user record into protected duplicate");
    imported.contents = b.bytes;
    Expect(PlanMutation(user, user.bytes, imported, documents, policy).status == EditStatus::ProtectionReviewRequired,
           "ordinary import cannot add a protected duplicate into unrelated file");
    append.contents = "deb https://new.invalid/ ./\n";
    Expect(PlanMutation(user, user.bytes, append, documents, policy).accepted(), "ordinary unrelated addition allowed");
    Expect(EvaluateProtection(documents, {}, a.path, 0).state == ProtectionState::Unprotected,
           "no repository catalogue or implicit default protection");
}
void InvalidInputs() {
    const std::vector<std::string> bad = {
        "deb https://host.invalid stable\n", "deb https://host.invalid ./ main\n",
        "deb [signed-by=/keyring.gpg https://host.invalid ./\n", "not-a-source active bytes\n"};
    for (const std::string &bytes : bad)
        Expect(!ParseDocument("/parts/bad.list", Format::OneLine, bytes).valid(), "reject malformed active classic definition");
    Expect(!ParseDocument("/parts/quote.list", Format::OneLine,
        "deb https://host.invalid/ stable main \"unterminated\n").valid(), "unterminated optional token is not silently discarded");
    Expect(!ParseDocument("/parts/bad.sources", Format::Deb822,
        "Types: deb\nURIs: https://host.invalid/\nSuites: ./\nEnabled: yes\nEnabled: no\n").valid(),
        "duplicate Deb822 fields must not acquire ambiguous mutation identity");
    Expect(!ParseDocument("/parts/bad.sources", Format::Deb822,
        "Types: deb\nURIs: https://host.invalid/\nSuites: ./\nEnabled: perhaps\n").valid(), "unknown Enabled spelling rejected");
    const Document empty(ParseDocument("/custom/new.sources", Format::Deb822, "# keep me\n"));
    Mutation append(EditKind::AppendDefinition); append.contents = "Types: deb\nURIs: https://host.invalid/\nSuites: ./\n";
    Expect(PlanMutation(empty, empty.bytes, append).accepted(), "explicit valid addition to comment-only document");
    append.contents = "Types: deb\nURIs: https://host.invalid/\nSuites: stable\n";
    Expect(PlanMutation(empty, empty.bytes, append).status == EditStatus::InvalidMutation, "invalid replacement cannot enter plan");
    const char nulBytes[] = "deb https://host.invalid/ ./\0ignored";
    const std::string nul(nulBytes, sizeof(nulBytes) - 1);
    Expect(!ParseDocument("/parts/nul.list", Format::OneLine, nul).valid(), "NUL bytes rejected");
}
class FixtureDirectory {
  public:
    std::string path;
    std::vector<std::string> files, directories;
    FixtureDirectory() {
        char temporary[] = "/tmp/source-documents-XXXXXX";
        const char *created(mkdtemp(temporary));
        Expect(created != NULL, "create generic temporary source fixture"); path = created;
    }
    ~FixtureDirectory() {
        for (const std::string &file : files) unlink(file.c_str());
        for (auto directory(directories.rbegin()); directory != directories.rend(); ++directory) rmdir(directory->c_str());
        rmdir(path.c_str());
    }
    std::string MakeDirectory(const std::string &leaf) {
        const std::string name(path + "/" + leaf);
        Expect(mkdir(name.c_str(), 0700) == 0, "create fixture sourceparts directory");
        directories.push_back(name); return name;
    }
    void Track(const std::string &name) { files.push_back(name); }
    void Write(const std::string &name, const std::string &contents) {
        std::ofstream file(name.c_str(), std::ios::binary | std::ios::trunc);
        file << contents; file.close(); Expect(file.good(), "write source fixture bytes"); Track(name);
    }
};
void FilesystemSnapshots() {
    FixtureDirectory fixture;
    const std::string parts(fixture.MakeDirectory("parts"));
    const std::string primary(fixture.path + "/primary.sources");
    const std::string alpha(parts + "/alpha.list"), beta(parts + "/beta.sources");
    fixture.Write(primary, "Types: deb\nURIs: https://bootstrap.invalid/\nSuites: ./\nX-Vendor: preserved\n");
    fixture.Write(alpha, "# note\ndeb ssh://user.invalid/ stable main\n");
    fixture.Write(beta, "Types: deb\nURIs: https://disabled.invalid/\nSuites: ./\nEnabled: no\n");
    fixture.Write(parts + "/ignored.list.backup", "deliberately not a source\n");
    fixture.Write(parts + "/.hidden.list", "also not a source\n");
    fixture.Write(parts + "/bad name.list", "not an APT filename\n");
    const EffectiveLocations locations = {primary, parts + "/"};
    const StoreSnapshot snapshot(ReadEffectiveDocuments(locations));
    Expect(snapshot.ready() && snapshot.documents.size() == 3, "read actual main Deb822 and supported sourceparts files only");
    Expect(snapshot.documents[0].document.path == primary && snapshot.documents[1].document.path == alpha &&
           snapshot.documents[2].document.path == beta, "preserve exact effective paths and sort sourceparts deterministically");
    Expect(snapshot.documents[0].identity.exists && snapshot.documents[0].identity.size == snapshot.documents[0].document.bytes.size(),
           "capture stable file identity beside original bytes");
    Expect(!snapshot.documents[2].document.definitions[0].enabled, "disabled definitions remain visible in filesystem snapshot");
    const std::string qualified(parts + "/package:architecture.sources");
    fixture.Write(qualified, "Types: deb\nURIs: https://qualified.invalid/\nSuites: ./\n");
    const auto qualifiedSnapshot(ReadEffectiveDocuments(locations));
    Expect(qualifiedSnapshot.ready() && qualifiedSnapshot.documents.size() == 4 &&
           qualifiedSnapshot.documents.back().document.path == qualified && IsEffectiveDestination(locations, qualified),
           "sourceparts names containing a colon are consumed like APT run-parts inputs");
    Expect(unlink(qualified.c_str()) == 0, "remove isolated colon-name fixture");
    fixture.Write(primary, "Types: deb\nURIs: https://invalid.invalid/\nSuites: stable\n");
    const auto invalidMain(ReadEffectiveDocuments(locations));
    Expect(!invalidMain.ready() && invalidMain.documents.size() == 3 &&
           invalidMain.documents[1].document.path == alpha && invalidMain.documents[2].document.path == beta,
           "invalid main file blocks writes while retaining safe sourceparts rows for review");
    fixture.Write(primary, snapshot.documents[0].document.bytes);
    const auto refreshed(ReadEffectiveDocuments(locations));
    const auto policy = std::vector<ProtectionSelector>{SelectorForDefinition("bootstrap", snapshot.documents[0].document.definitions[0])};
    Mutation remove(EditKind::RemoveDefinition);
    StorePlan plan(PlanStoredMutation(locations, refreshed.documents[1], remove, policy));
    Expect(plan.ready() && plan.edit.updated == "# note\n", "plan actual user-source removal without rewriting neighboring files");
    Expect(ReadDocument(alpha, Format::OneLine).documents[0].document.bytes == snapshot.documents[1].document.bytes,
           "planning performs no filesystem writes");
    Expect(PlanStoredMutation(locations, refreshed.documents[0], remove, policy).edit.status == EditStatus::ProtectedDefinition,
           "filesystem planner rechecks separate protected role policy");
    const std::string protectedBytes(snapshot.documents[0].document.bytes);
    fixture.Write(primary, "Types: deb\nURIs: https://bootstrap.invalid/\nSuites: changed\nComponents: main\n");
    Expect(PlanStoredMutation(locations, snapshot.documents[1], remove, policy).edit.status == EditStatus::ProtectionReviewRequired,
           "external protected-file rewrite is rechecked before an unrelated ordinary mutation");
    fixture.Write(primary, protectedBytes);
    fixture.Write(alpha, "# external edit\ndeb ssh://user.invalid/ stable main\n");
    Expect(PlanStoredMutation(locations, snapshot.documents[1], remove, policy).edit.status == EditStatus::StaleDocument,
           "stale visible source is rejected after external edit");
    const StoredDocument fresh(ReadDocument(alpha, Format::OneLine).documents[0]);
    const std::string replacement(fixture.path + "/replacement");
    fixture.Write(replacement, fresh.document.bytes);
    Expect(rename(replacement.c_str(), alpha.c_str()) == 0, "replace fixture inode while retaining bytes");
    Expect(PlanStoredMutation(locations, fresh, remove, policy).edit.status == EditStatus::StaleDocument,
           "same-byte inode replacement cannot bypass snapshot conflict detection");
    const std::string chosen(parts + "/user-selected.sources");
    Mutation append(EditKind::AppendDefinition); append.contents = "Types: deb\nURIs: mirror+https://chosen.invalid/\nSuites: ./\n";
    plan = PlanStoredMutation(locations, NewDocument(chosen, Format::Deb822), append, policy);
    Expect(plan.ready() && !plan.target.identity.exists && plan.edit.updated == append.contents,
           "new file plan uses an explicit user-selected effective destination");
    Expect(access(chosen.c_str(), F_OK) != 0, "planning does not materialize new source files");
    Expect(!IsEffectiveDestination(locations, fixture.path + "/outside.list") &&
           !IsEffectiveDestination(locations, parts + "/../outside.list") &&
           !IsEffectiveDestination(locations, parts + "/ignored.list.backup"), "destination validation rejects outside, traversal, and ignored names");
    Expect(!PlanStoredMutation(locations, NewDocument(fixture.path + "/outside.list", Format::OneLine), append).ready(),
           "unconfigured arbitrary source destination denied");
    const std::string linked(parts + "/linked.list"); fixture.Track(linked);
    Expect(symlink(alpha.c_str(), linked.c_str()) == 0, "create symlink fixture");
    const StoreSnapshot unsafe(ReadEffectiveDocuments(locations));
    Expect(!unsafe.ready() && !ReadDocument(linked, Format::OneLine).ready(), "symlink source leaf refuses mutation snapshot");
    Expect(unlink(linked.c_str()) == 0, "remove symlink fixture");
    const std::string pipe(parts + "/pipe.list"); fixture.Track(pipe);
    Expect(mkfifo(pipe.c_str(), 0600) == 0, "create nonregular fixture");
    Expect(!ReadDocument(pipe, Format::OneLine).ready(), "FIFO source is rejected without blocking read");
    Expect(unlink(pipe.c_str()) == 0, "remove FIFO fixture");
    const StoreSnapshot limited(ReadDocument(primary, Format::Deb822, 8));
    Expect(!limited.ready() && limited.diagnostics[0].kind == StoreError::TooLarge, "bounded reader rejects oversized documents");
    Expect(!ReadEffectiveDocuments(locations, 4 * 1024 * 1024, 1).ready(), "bounded reader rejects excessive effective file count");
    Expect(!ReadEffectiveDocuments({primary, ""}, 4 * 1024 * 1024, 0).ready(), "main file participates in the total file limit");
    const EffectiveLocations none = {"/dev/null", fixture.path + "/missing-parts"};
    Expect(ReadEffectiveDocuments(none).ready() && ReadEffectiveDocuments(none).documents.empty(),
           "absent or disabled source inputs never assume or restore a repository");

    // A parent alias can be retargeted while a hard link keeps the leaf's
    // bytes and inode metadata identical. Its canonical destination still
    // belongs to the snapshot and must be rechecked before any write.
    const std::string otherParts(fixture.MakeDirectory("other-parts"));
    const std::string otherAlpha(otherParts + "/alpha.list");
    Expect(link(alpha.c_str(), otherAlpha.c_str()) == 0, "create same-inode alternate destination");
    fixture.Track(otherAlpha);
    const std::string alias(fixture.path + "/parts-alias");
    Expect(symlink(parts.c_str(), alias.c_str()) == 0, "create legitimate sourceparts parent alias");
    fixture.Track(alias);
    const StoredDocument viaAlias(ReadDocument(alias + "/alpha.list", Format::OneLine).documents[0]);
    Expect(unlink(alias.c_str()) == 0 && symlink(otherParts.c_str(), alias.c_str()) == 0,
           "retarget sourceparts alias");
    const StoredDocument retargeted(ReadDocument(alias + "/alpha.list", Format::OneLine).documents[0]);
    Expect(viaAlias.identity.sameVersion(retargeted.identity) && viaAlias.document.bytes == retargeted.document.bytes,
           "retargeted alias retains identical leaf identity and bytes");
    Expect(PlanStoredMutation({"", alias}, viaAlias, remove).edit.status == EditStatus::StaleDocument,
           "parent alias retargeting cannot bypass canonical destination conflict detection");
}
} // namespace

int main() {
    ClassicEdits(); Deb822Edits(); ComponentEdits(); Protection(); InvalidInputs(); FilesystemSnapshots();
    std::cout << "[source-document] PASS\n";
    return 0;
}
