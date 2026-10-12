/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/KeyringImport.hpp"
#include <algorithm>
#include <set>
#include <sstream>

namespace CydiaRuntime { namespace Keyring {
namespace {
bool Fail(Privileged::Error *error, const char *code, const char *message) {
    if (error) { error->code = code; error->message = message; } return false;
}
bool Space(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
std::string Lower(std::string value) {
    for (char &c : value) {
        if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    }
    return value;
}
bool Token(const std::string &value) {
    if (value.size() != 64) return false;
    for (char c : value) if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f')) return false;
    return true;
}
int Base64(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    return c == '+' ? 62 : c == '/' ? 63 : -1;
}
bool Dearmor(const std::string &input, std::string *binary) {
    std::size_t first(0); while (first < input.size() && Space(input[first])) ++first;
    if (first == input.size()) return false;
    if (static_cast<unsigned char>(input[first]) & 128) { *binary = input; return first == 0; }
    std::istringstream lines(input.substr(first)); std::string line, encoded;
    if (!std::getline(lines, line)) return false;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line != "-----BEGIN PGP PUBLIC KEY BLOCK-----") return false;
    bool body(false), checksum(false), ended(false);
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (ended) { for (char c : line) if (!Space(c)) return false; continue; }
        if (!body) {
            if (line.empty()) { body = true; continue; }
            if (line.find(':') == std::string::npos) return false;
            for (char c : line) if (static_cast<unsigned char>(c) < 32 || static_cast<unsigned char>(c) > 126) return false;
            continue;
        }
        if (line == "-----END PGP PUBLIC KEY BLOCK-----") { ended = true; continue; }
        if (line.size() == 5 && line[0] == '=') {
            if (checksum) return false;
            for (std::size_t i = 1; i < line.size(); ++i) if (Base64(line[i]) < 0) return false;
            checksum = true; continue; // GnuPG independently checks any armor CRC.
        }
        if (checksum) return false;
        for (char c : line) if (Base64(c) < 0 && c != '=') return false;
        encoded += line;
    }
    if (!ended || encoded.empty() || encoded.size() % 4) return false;
    binary->clear();
    for (std::size_t i = 0; i < encoded.size(); i += 4) {
        const int a(Base64(encoded[i])), b(Base64(encoded[i + 1]));
        const int c(encoded[i + 2] == '=' ? 0 : Base64(encoded[i + 2]));
        const int d(encoded[i + 3] == '=' ? 0 : Base64(encoded[i + 3]));
        if (a < 0 || b < 0 || c < 0 || d < 0 ||
            (encoded[i + 2] == '=' && (encoded[i + 3] != '=' || (b & 15))) ||
            (encoded[i + 3] == '=' && encoded[i + 2] != '=' && (c & 3)) ||
            ((encoded[i + 2] == '=' || encoded[i + 3] == '=') && i + 4 != encoded.size())) return false;
        binary->push_back(static_cast<char>((a << 2) | (b >> 4)));
        if (encoded[i + 2] != '=') binary->push_back(static_cast<char>((b << 4) | (c >> 2)));
        if (encoded[i + 3] != '=') binary->push_back(static_cast<char>((c << 6) | d));
    }
    return !binary->empty() && binary->size() <= MaximumKeyBytes;
}
bool SourceRequest(const CydiaSources::CommitRequest &source) {
    if (source.kind != CydiaSources::CommitKind::EditDocument || !source.expected.document.valid() ||
        source.initializePolicy || !source.selectors.empty()) return false;
    if (source.mutation.kind == CydiaSources::EditKind::ReplaceDefinition)
        if (!source.expected.identity.exists || source.mutation.ordinal >= source.expected.document.definitions.size()) return false;
    if (source.mutation.kind != CydiaSources::EditKind::AppendDefinition && source.mutation.kind != CydiaSources::EditKind::ReplaceDefinition) return false;
    return CydiaSources::IsSingleSourceAddition(CydiaSources::ParseDocument(source.expected.document.path,
        source.expected.document.format, source.mutation.contents));
}
bool SafeKeyPath(const std::string &path) {
    if (path.empty() || path[0] != '/') return false;
    for (char c : path) if (!(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') &&
        !(c >= '0' && c <= '9') && c != '/' && c != '.' && c != '_' && c != '-') return false;
    return path.find("/../") == std::string::npos && path.find("/./") == std::string::npos;
}
std::vector<std::string> Fields(const std::string &line) {
    std::vector<std::string> fields; std::size_t begin(0);
    for (;;) {
        std::size_t end(line.find(':', begin));
        fields.push_back(line.substr(begin, end - begin));
        if (end == std::string::npos) return fields;
        begin = end + 1;
    }
}
}

bool ParseInput(const std::string &payload, Input *input, Privileged::Error *error) {
    std::vector<std::string> fields;
    if (!input) return false;
    // Older native import requests contain three fields and remain accepted.
    if (!Privileged::ParseFields(payload, 5, &fields, NULL) && !Privileged::ParseFields(payload, 3, &fields, NULL))
        return Fail(error, "invalid_key_request", "Invalid reviewed key import request.");
    if (fields[0].empty() || fields[0].size() > MaximumKeyBytes ||
        !CydiaSources::ParseCommitRequest(fields[1], &input->source) || !SourceRequest(input->source) ||
        (!fields[2].empty() && !Token(fields[2]))) return Fail(error, "invalid_key_request", "Invalid reviewed key import request.");
    input->bytes = fields[0]; input->token = fields[2];
    input->referencePackage = fields.size() == 5 ? fields[3] : "";
    input->referencePath = fields.size() == 5 ? fields[4] : "";
    if (input->referencePackage.empty() != input->referencePath.empty() || input->referencePackage.size() > 256 ||
        (!input->referencePath.empty() && !SafeKeyPath(input->referencePath)))
        return Fail(error, "invalid_key_request", "Invalid installed keyring reference.");
    return true;
}
std::string SerializeInput(const Input &input) {
    return Privileged::SerializeFields({input.bytes, CydiaSources::SerializeCommitRequest(input.source), input.token,
        input.referencePackage, input.referencePath});
}
std::string SerializeReview(const Review &review) {
    std::string fingerprints; for (const auto &f : review.fingerprints) fingerprints += f + '\n';
    return Privileged::SerializeFields({fingerprints, review.destination, CydiaSources::SerializeCommitRequest(review.source), review.token});
}
bool ParseReview(const std::string &payload, Review *review, Privileged::Error *error) {
    std::vector<std::string> fields;
    if (!review || !Privileged::ParseFields(payload, 4, &fields, error) || !SafeKeyPath(fields[1]) ||
        !CydiaSources::ParseCommitRequest(fields[2], &review->source) || !SourceRequest(review->source) || !Token(fields[3]))
        return Fail(error, "invalid_key_review", "Invalid key review result.");
    review->fingerprints.clear(); std::istringstream lines(fields[0]); std::string f;
    while (std::getline(lines, f)) {
        if (f.size() != 40 && f.size() != 64) return false;
        for (char c : f) if (!(c >= 'A' && c <= 'F') && !(c >= '0' && c <= '9')) return false;
        review->fingerprints.push_back(f);
    }
    if (review->fingerprints.empty() || review->fingerprints.size() > 16) return false;
    CydiaSources::CommitRequest bound;
    if (!BindSourceSignedBy(review->source, fields[1], &bound, error) ||
        bound.mutation.contents != review->source.mutation.contents) return false;
    review->destination = fields[1]; review->token = fields[3]; return true;
}

bool CheckPublicKeyPackets(const std::string &input, std::size_t *primaryCount, Privileged::Error *error) {
    std::string bytes;
    if (input.empty() || input.size() > MaximumKeyBytes || !Dearmor(input, &bytes))
        return Fail(error, "invalid_public_key", "Expected a bounded binary or armored public key.");
    std::size_t offset(0), primaries(0), packets(0);
    while (offset < bytes.size()) {
        const unsigned header(static_cast<unsigned char>(bytes[offset++]));
        if (!(header & 128) || ++packets > 16384) return Fail(error, "invalid_public_key", "Invalid OpenPGP packet header.");
        const unsigned tag(header & 64 ? header & 63 : (header >> 2) & 15);
        if (tag == 5 || tag == 7) return Fail(error, "private_key_rejected", "Private keys cannot be imported as repository trust.");
        if (tag != 2 && tag != 6 && tag != 10 && tag != 12 && tag != 13 && tag != 14 && tag != 17 && tag != 21)
            return Fail(error, "invalid_public_key", "Only transferable public key packets are accepted.");
        std::size_t length(0);
        if (header & 64) {
            if (offset == bytes.size()) return false;
            const unsigned first(static_cast<unsigned char>(bytes[offset++]));
            if (first < 192) length = first;
            else if (first < 224) { if (offset == bytes.size()) return false; length = (first - 192) * 256 + static_cast<unsigned char>(bytes[offset++]) + 192; }
            else if (first == 255) {
                if (bytes.size() - offset < 4) return false;
                for (unsigned i = 0; i != 4; ++i) length = (length << 8) | static_cast<unsigned char>(bytes[offset++]);
            } else return Fail(error, "invalid_public_key", "Partial lengths are not valid for public key packets.");
        } else {
            const unsigned kind(header & 3);
            if (kind == 3) return Fail(error, "invalid_public_key", "Indeterminate legacy packet lengths are not supported.");
            const unsigned octets(1U << kind);
            if (bytes.size() - offset < octets) return false;
            for (unsigned i = 0; i != octets; ++i) length = (length << 8) | static_cast<unsigned char>(bytes[offset++]);
        }
        if (length == 0 || length > bytes.size() - offset) return Fail(error, "invalid_public_key", "Truncated OpenPGP packet.");
        if (tag == 6 && ++primaries > 16) return Fail(error, "invalid_public_key", "Too many primary keys in one import.");
        offset += length;
    }
    if (!primaries) return Fail(error, "invalid_public_key", "No primary public key was provided.");
    if (primaryCount) *primaryCount = primaries;
    return true;
}
bool ReadFingerprints(const std::string &listing, std::vector<std::string> *fingerprints, Privileged::Error *error) {
    if (!fingerprints || listing.size() > MaximumKeyBytes || listing.find('\0') != std::string::npos) return false;
    fingerprints->clear(); bool primary(false); std::size_t count(0); std::set<std::string> unique;
    std::istringstream lines(listing); std::string line;
    while (std::getline(lines, line)) {
        const auto fields(Fields(line));
        if (fields[0] == "sec" || fields[0] == "ssb") return Fail(error, "private_key_rejected", "The verifier returned a private key.");
        if (fields[0] == "pub") {
            if (primary || fields.size() < 12 || ++count > 16 || fields[1].find_first_of("irdne") != std::string::npos ||
                fields[11].find('D') != std::string::npos || fields[11].find('S') == std::string::npos)
                return Fail(error, "unusable_public_key", "The public key cannot sign repository metadata.");
            primary = true;
        } else if (fields[0] == "fpr" && primary) {
            if (fields.size() < 10 || (fields[9].size() != 40 && fields[9].size() != 64)) return false;
            for (char c : fields[9]) if (!(c >= '0' && c <= '9') && !(c >= 'A' && c <= 'F')) return false;
            if (!unique.insert(fields[9]).second) return false;
            fingerprints->push_back(fields[9]); primary = false;
        } else if (fields[0] == "sub" && primary) return false;
    }
    return !primary && count && fingerprints->size() == count;
}

bool BindSignedBy(const CydiaSources::Document &document, std::size_t ordinal,
                  const std::string &keyring, std::string *replacement, Privileged::Error *error) {
    if (!replacement || !document.valid() || ordinal >= document.definitions.size() || !SafeKeyPath(keyring)) return false;
    const auto &definition(document.definitions[ordinal]); std::string bytes(definition.original);
    std::vector<const CydiaSources::Field *> signedBy;
    for (const auto &field : definition.fields) if (Lower(field.name) == "signed-by") signedBy.push_back(&field);
    if (signedBy.size() > 1) return Fail(error, "ambiguous_signed_by", "The source has more than one Signed-By field.");
    if (document.format == CydiaSources::Format::Deb822) {
        const std::string newline(bytes.find("\r\n") != std::string::npos ? "\r\n" : "\n");
        if (signedBy.empty()) {
            if (!bytes.empty() && bytes.back() != '\n') bytes += newline;
            bytes += "Signed-By: " + keyring + newline;
        } else {
            const auto &field(*signedBy[0]); const std::size_t begin(field.span.begin - definition.span.begin), end(field.span.end - definition.span.begin);
            if (end > bytes.size() || begin > end) return false;
            // Preserve comment lines even inside a folded/embedded key field.
            std::string comments; std::istringstream lines(bytes.substr(begin, end - begin)); std::string line;
            while (std::getline(lines, line)) {
                if (!line.empty() && line[0] == '#') {
                    if (!line.empty() && line.back() == '\r') line.pop_back();
                    comments += line + newline;
                }
            }
            bytes.replace(begin, end - begin, field.name + ": " + keyring + newline + comments);
        }
    } else {
        std::size_t cursor(0); while (cursor < bytes.size() && Space(bytes[cursor])) ++cursor;
        if (cursor < bytes.size() && bytes[cursor] == '#') { ++cursor; while (cursor < bytes.size() && Space(bytes[cursor])) ++cursor; }
        while (cursor < bytes.size() && !Space(bytes[cursor])) ++cursor;
        while (cursor < bytes.size() && Space(bytes[cursor])) ++cursor;
        if (cursor < bytes.size() && bytes[cursor] == '[') {
            std::size_t close(cursor + 1); bool closingQuote(false);
            while (close < bytes.size()) { if (bytes[close] == '"') closingQuote = !closingQuote;
                if (bytes[close] == ']' && !closingQuote) break;
                ++close;
            }
            if (close == bytes.size() || closingQuote) return false;
            std::size_t start(0), end(0), found(0), position(cursor + 1);
            while (position < close) {
                while (position < close && Space(bytes[position])) ++position;
                const std::size_t begin(position); bool quote(false);
                while (position < close && (quote || !Space(bytes[position]))) { if (bytes[position] == '"') quote = !quote; ++position; }
                if (quote) return false;
                const std::string token(bytes.substr(begin, position - begin)); const std::size_t equals(token.find('='));
                if (Lower(token.substr(0, equals)) == "signed-by") { start = begin; end = position; ++found; }
            }
            if (found > 1 || found != signedBy.size()) return Fail(error, "ambiguous_signed_by", "Cannot identify the source key option safely.");
            if (found) bytes.replace(start, end - start, "signed-by=" + keyring);
            else bytes.insert(close, (close > cursor + 1 && !Space(bytes[close - 1]) ? " " : "") + std::string("signed-by=") + keyring);
        } else bytes.insert(cursor, "[signed-by=" + keyring + "] ");
    }
    const auto parsed(CydiaSources::ParseDocument(document.path, document.format, bytes));
    if (!parsed.valid() || parsed.definitions.size() != 1 || parsed.definitions[0].uris != definition.uris ||
        parsed.definitions[0].suites != definition.suites || parsed.definitions[0].components != definition.components ||
        parsed.definitions[0].types != definition.types || parsed.definitions[0].enabled != definition.enabled) return false;
    *replacement = bytes; return true;
}

bool BindSourceSignedBy(const CydiaSources::CommitRequest &source, const std::string &keyring,
                       CydiaSources::CommitRequest *bound, Privileged::Error *error) {
    if (!bound || !SourceRequest(source)) return Fail(error, "invalid_key_request", "Select one source for the signing key.");
    *bound = source;
    // Bind the definition the user reviewed, including unsaved edits. Using
    // expected.document here would silently restore the old URL/options.
    const auto document(CydiaSources::ParseDocument(source.expected.document.path,
        source.expected.document.format, source.mutation.contents));
    std::string bytes(document.bytes);
    // Work backwards so source spans remain exact, including comments and
    // trailing whitespace between a paired binary/source definition.
    for (auto it = document.definitions.rbegin(); it != document.definitions.rend(); ++it) {
        std::string replacement;
        if (!BindSignedBy(document, it->ordinal, keyring, &replacement, error)) return false;
        bytes.replace(it->span.begin, it->span.end - it->span.begin, replacement);
    }
    if (!CydiaSources::IsSingleSourceAddition(CydiaSources::ParseDocument(document.path, document.format, bytes)))
        return Fail(error, "invalid_key_request", "The signing key could not be scoped to the complete source draft.");
    bound->mutation.contents = bytes;
    return true;
}
} }
