/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/KeyringImport.hpp"
#include <cstdlib>
#include <iostream>
using namespace CydiaRuntime;
namespace {
void Expect(bool value, const char *message) { if (!value) { std::cerr << "[key-import] FAIL: " << message << '\n'; std::exit(1); } }
std::string Packet(unsigned tag, const std::string &body = "x") {
    return std::string(1, static_cast<char>(192 | tag)) + static_cast<char>(body.size()) + body;
}
void Packets() {
    Privileged::Error error; std::size_t count;
    const std::string key(Packet(6) + Packet(13) + Packet(2) + Packet(14) + Packet(2));
    Expect(Keyring::CheckPublicKeyPackets(key, &count, &error) && count == 1, "bounded public packet sequence");
    Expect(Keyring::CheckPublicKeyPackets(key + key, &count, &error) && count == 2, "multiple primary keys stay explicit");
    Expect(!Keyring::CheckPublicKeyPackets(key + Packet(5), nullptr, &error) && error.code == "private_key_rejected", "reject mixed secret primary packet");
    Expect(!Keyring::CheckPublicKeyPackets(key + Packet(7), nullptr, &error), "reject mixed secret subkey packet");
    Expect(!Keyring::CheckPublicKeyPackets(Packet(8), nullptr, &error), "reject compressed packet hiding private material");
    Expect(!Keyring::CheckPublicKeyPackets(Packet(6).substr(0, 2), nullptr, &error), "reject truncated packet body");
    Expect(!Keyring::CheckPublicKeyPackets(std::string("\xc6\xe0x", 3), nullptr, &error), "reject partial key packet lengths");
    Expect(!Keyring::CheckPublicKeyPackets(std::string("\x9bxx", 3), nullptr, &error), "reject indeterminate legacy key lengths");
    Expect(!Keyring::CheckPublicKeyPackets(Packet(13), nullptr, &error), "require a primary public packet");
    Expect(!Keyring::CheckPublicKeyPackets(std::string(Keyring::MaximumKeyBytes + 1, 'x'), nullptr, &error), "bound raw input");
    const std::string armor("-----BEGIN PGP PUBLIC KEY BLOCK-----\r\nVersion: fixture\r\n\r\n xgF4\r\n-----END PGP PUBLIC KEY BLOCK-----\r\n");
    Expect(!Keyring::CheckPublicKeyPackets(armor, nullptr, &error), "reject stray armor body characters");
    const std::string armored("-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nxgF4\n-----END PGP PUBLIC KEY BLOCK-----\n");
    Expect(Keyring::CheckPublicKeyPackets(armored, &count, &error) && count == 1, "decode armored public packet boundary");
    Expect(!Keyring::CheckPublicKeyPackets(armored + "trailing", nullptr, &error), "reject unreviewed data after armor");
    Expect(!Keyring::CheckPublicKeyPackets("-----BEGIN PGP PRIVATE KEY BLOCK-----\n\nxQF4\n-----END PGP PRIVATE KEY BLOCK-----\n", nullptr, &error), "reject secret armor before verifier execution");
}
void Fingerprints() {
    Privileged::Error error; std::vector<std::string> fingerprints;
    const std::string fingerprint(40, 'A');
    const std::string valid("pub:-:4096:1:0123456789ABCDEF:1:0:::-:::scSC:\nfpr:::::::::" + fingerprint + ":\nuid:-::::::::Untrusted\\x3a label:\nsub:-:2048:1:0123456789ABCDEF:1:0:::::s:\nfpr:::::::::" + std::string(40, 'B') + ":\n");
    // Field 12 is capabilities; user labels are never fingerprint authority.
    const std::string listing("pub:-:4096:1:0123456789ABCDEF:1:0:::::scSC:\nfpr:::::::::" + fingerprint + ":\nuid:-::::::::Fake fingerprint 123:\n");
    Expect(Keyring::ReadFingerprints(listing, &fingerprints, &error) && fingerprints.size() == 1 && fingerprints[0] == fingerprint, "take primary fingerprint only from verifier field 10");
    Expect(!Keyring::ReadFingerprints("sec:-:4096:1:x:1:0:::::s:\n" + listing, &fingerprints, &error), "reject secret verifier records");
    for (const char *state : {"r", "e", "i", "d", "n"}) {
        std::string revoked(listing); revoked.replace(4, 1, state);
        Expect(!Keyring::ReadFingerprints(revoked, &fingerprints, &error), "reject unusable primary key states");
    }
    std::string encryption(listing); encryption.replace(encryption.find("scSC"), 4, "eE");
    Expect(!Keyring::ReadFingerprints(encryption, &fingerprints, &error), "require usable signing capability");
    Expect(!Keyring::ReadFingerprints("pub:-:4096:1:x:1:0:::::sS:\n", &fingerprints, &error), "missing fingerprint fails closed");
    Expect(!Keyring::ReadFingerprints(listing + listing, &fingerprints, &error), "duplicate primary identity rejected");
}
void Bindings() {
    using namespace CydiaSources; Privileged::Error error; std::string replacement;
    const std::string path("/private/cydia/keyrings/" + std::string(64, 'a') + ".gpg");
    const auto classic(ParseDocument("/fixture/sources.list", Format::OneLine,
        "# retained\n# deb [arch=arm64 signed-by=\"/old keyring.gpg\" custom=\"bracket] value\"] https://repo.invalid/ stable main # retained inline\n"));
    Expect(classic.valid() && Keyring::BindSignedBy(classic, 0, path, &replacement, &error), "replace quoted classic Signed-By without changing source scope");
    Expect(replacement == "# deb [arch=arm64 signed-by=" + path + " custom=\"bracket] value\"] https://repo.invalid/ stable main # retained inline\n", "retain every unrelated option, comment and disabled state");
    const auto none(ParseDocument("/fixture/a.list", Format::OneLine, "deb https://repo.invalid/ ./\n"));
    Expect(Keyring::BindSignedBy(none, 0, path, &replacement, &error) && replacement == "deb [signed-by=" + path + "] https://repo.invalid/ ./\n", "insert explicit scalar trust scope");
    const auto deb822(ParseDocument("/fixture/a.sources", Format::Deb822,
        "# before\r\nTypes: deb deb-src\r\nURIs: https://a.invalid/ https://b.invalid/\r\nSuites: stable testing\r\nComponents: main\r\nEnabled: no\r\nSigned-By: /old.gpg\r\n# keep folded comment\r\n /another.gpg\r\nX-Custom: exact\r\n"));
    Expect(deb822.valid() && Keyring::BindSignedBy(deb822, 0, path, &replacement, &error), "bind entire multi-URI/suite stanza");
    Expect(replacement == "# before\r\nTypes: deb deb-src\r\nURIs: https://a.invalid/ https://b.invalid/\r\nSuites: stable testing\r\nComponents: main\r\nEnabled: no\r\nSigned-By: " + path + "\r\n# keep folded comment\r\nX-Custom: exact\r\n", "preserve CRLF, comments and unknown fields");
    const auto duplicate(ParseDocument("/fixture/a.list", Format::OneLine, "deb [signed-by=/a signed-by=/b] https://repo.invalid/ ./\n"));
    Expect(!Keyring::BindSignedBy(duplicate, 0, path, &replacement, &error), "reject ambiguous duplicate trust options");
    Expect(!Keyring::BindSignedBy(none, 0, "/private/keyrings/a.gpg trusted=yes", &replacement, &error), "destination cannot inject options");
    Keyring::Input input, decoded; input.bytes = Packet(6); input.source.expected.document = none;
    input.source.expected.identity.exists = true; input.source.mutation = Mutation(EditKind::ReplaceDefinition);
    input.source.mutation.contents = none.definitions[0].original; input.token = std::string(64, 'a');
    Expect(Keyring::ParseInput(Keyring::SerializeInput(input), &decoded, &error) && decoded.bytes == input.bytes, "bounded binary key/source token request round trip");
    CommitRequest edited(input.source), editedBound;
    edited.mutation.contents = "deb [arch=arm64 custom=keep] https://edited.invalid/ next main extras\n";
    Expect(Keyring::BindSourceSignedBy(edited, path, &editedBound, &error) && editedBound.mutation.contents ==
        "deb [arch=arm64 custom=keep signed-by=" + path + "] https://edited.invalid/ next main extras\n" &&
        editedBound.expected.document.bytes == none.bytes && editedBound.access == edited.access,
        "key binding preserves reviewed URL, suite, options and ordinary access without restoring the old source");
    input.source.mutation = Mutation(EditKind::RemoveDefinition);
    Expect(!Keyring::ParseInput(Keyring::SerializeInput(input), &decoded, &error), "key request cannot delete a source");

    CommitRequest draft;
    draft.expected = NewDocument("/fixture/new.list", Format::OneLine);
    draft.mutation = Mutation(EditKind::AppendDefinition);
    draft.mutation.contents = "# one source, two index types\ndeb [arch=arm64] https://repo.invalid/ stable main\n"
        "# source indexes\ndeb-src [arch=arm64] https://repo.invalid/ stable main\n";
    CommitRequest bound;
    Expect(Keyring::BindSourceSignedBy(draft, path, &bound, &error), "bind both records in an unsaved new-source draft");
    const auto paired(ParseDocument("/fixture/new.list", Format::OneLine, bound.mutation.contents));
    Expect(paired.valid() && paired.definitions.size() == 2 && bound.expected.document.bytes.empty() &&
        bound.mutation.contents.find("# source indexes\n") != std::string::npos, "retain draft comments and untouched file preimage");
    for (const auto &definition : paired.definitions) {
        bool found(false);
        for (const auto &field : definition.fields) if (field.name == "signed-by") found = field.value == path;
        Expect(found, "every new index type has the reviewed signing key scope");
    }
    input.source = draft; input.referencePackage = "example-keyring"; input.referencePath = "/usr/share/keyrings/example.gpg";
    Expect(Keyring::ParseInput(Keyring::SerializeInput(input), &decoded, &error) && decoded.referencePackage == input.referencePackage &&
        decoded.referencePath == input.referencePath, "installed package reference round trip for a new source");
    input.referencePath.clear();
    Expect(!Keyring::ParseInput(Keyring::SerializeInput(input), &decoded, &error), "reject incomplete package reference");
    input.referencePackage.clear(); input.source.mutation.contents += "deb https://other.invalid/ ./\n";
    Expect(!Keyring::ParseInput(Keyring::SerializeInput(input), &decoded, &error), "cannot bind one approval to unrelated source additions");
    Keyring::Review review, decodedReview;
    review.fingerprints.push_back(std::string(40, 'A')); review.destination = path;
    review.source = bound; review.token = std::string(64, 'a');
    Expect(Keyring::ParseReview(Keyring::SerializeReview(review), &decodedReview, &error), "new-source signing-key review round trip");
    review.source.mutation.contents.replace(review.source.mutation.contents.rfind(path), path.size(), "/another.gpg");
    Expect(!Keyring::ParseReview(Keyring::SerializeReview(review), &decodedReview, &error), "review rejects a pair with only one bound index type");
    draft.expected = NewDocument("/fixture/new.sources", Format::Deb822);
    draft.mutation.contents = "Types: deb deb-src\nURIs: https://repo.invalid/\nSuites: stable\nComponents: main\n";
    Expect(Keyring::BindSourceSignedBy(draft, path, &bound, &error) && bound.mutation.contents.find("Signed-By: " + path) != std::string::npos,
        "new Deb822 draft retains binary/source types in one scoped stanza");
}
}
int main() { Packets(); Fingerprints(); Bindings(); std::cout << "[key-import] PASS\n"; }
