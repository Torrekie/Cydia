/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_KeyringImport_HPP
#define Cydia_KeyringImport_HPP
#include "Cydia/PrivilegedRuntime.hpp"
#include "Cydia/SourceDocumentCommit.hpp"

namespace CydiaRuntime { namespace Keyring {
constexpr std::size_t MaximumKeyBytes = 1024 * 1024;
struct Input {
    std::string bytes;
    CydiaSources::CommitRequest source;
    std::string token;
};
struct Review {
    std::vector<std::string> fingerprints;
    std::string destination;
    CydiaSources::CommitRequest source;
    std::string token;
};
bool ParseInput(const std::string &payload, Input *input, Privileged::Error *error);
std::string SerializeInput(const Input &input);
bool ParseReview(const std::string &payload, Review *review, Privileged::Error *error);
std::string SerializeReview(const Review &review);
/* This is a packet boundary check, not signature or fingerprint validation.
 * Authentication/normalization is performed independently by trusted GnuPG. */
bool CheckPublicKeyPackets(const std::string &input, std::size_t *primaryCount,
                          Privileged::Error *error);
bool ReadFingerprints(const std::string &listing, std::vector<std::string> *fingerprints,
                      Privileged::Error *error);
bool BindSignedBy(const CydiaSources::Document &document, std::size_t ordinal,
                  const std::string &keyring, std::string *replacement, Privileged::Error *error);
/* The caller independently resolves environment and holds the frontend lock
 * during Apply. The input never selects the verifier or destination. */
bool Prepare(const PackageDatabasePaths &paths, const Privileged::Environment &environment,
             const Input &input, Review *review, std::string *publicBytes, Privileged::Error *error);
bool Apply(const PackageDatabasePaths &paths, const Privileged::Environment &environment,
           const Input &input, Privileged::Error *error);
/* Package provider reads use the active dpkg file manifest, never an arbitrary
 * privileged file path. Results are bounded public-key candidates. */
bool PackageKeys(const Privileged::Environment &environment, const std::string &package,
                 std::vector<std::string> *files, Privileged::Error *error);
bool ReadPackageKey(const Privileged::Environment &environment, const std::string &package,
                    const std::string &path, std::string *bytes, Privileged::Error *error);
} }
#endif
