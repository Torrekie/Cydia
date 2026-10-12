/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_KeyringVerifier_HPP
#define Cydia_KeyringVerifier_HPP
#include "Cydia/PrivilegedRuntime.hpp"
#include <functional>
namespace CydiaRuntime { namespace Keyring {
struct VerificationLimits {
    unsigned timeoutMilliseconds = 15000;
    std::function<bool()> cancelled;
};
/* Portable GnuPG adapter. This owns bounded public-key normalization in a
 * fresh 0700 temporary home, not privileged path authorization. Privileged
 * callers independently validate the executable and staging parent first. */
bool VerifyPublicKey(const std::string &verifier, const std::string &temporaryParent,
    const std::string &input, std::string *normalized,
    std::vector<std::string> *fingerprints, Privileged::Error *error,
    const VerificationLimits &limits = VerificationLimits());

enum class RepositorySignatureStatus {
    Valid, MissingKey, Expired, Revoked, BadSignature, UnsupportedAlgorithm, VerifierError
};
struct RepositorySignatureReview {
    RepositorySignatureStatus status;
    std::vector<std::string> signerFingerprints;
    std::vector<std::string> primaryFingerprints;
    /* Unauthenticated lookup hints, never trusted signer identities. Prefer
     * a full issuer fingerprint; old signatures may supply only a long ID. */
    std::vector<std::string> missingKeyIdentifiers;
    RepositorySignatureReview() : status(RepositorySignatureStatus::VerifierError) {}
};
/* Parse the documented machine status stream, never localized diagnostics or
 * user IDs. A true result means at least one usable matching signature. */
bool ReadRepositorySignatureStatus(const std::string &status, bool verifierSucceeded,
    RepositorySignatureReview *review, Privileged::Error *error);
/* An empty detachedSignature selects a clearsigned InRelease. Empty key bytes
 * permit discovery of missing-key hints only. The fresh private home does not
 * use user trust, retrieve keys, or modify installed keyrings. This verifies a
 * candidate's signature match; APT remains responsible for its full policy. */
bool VerifyRepositorySignature(const std::string &verifier, const std::string &temporaryParent,
    const std::string &publicKeyBytes, const std::string &metadataBytes,
    const std::string &detachedSignature, RepositorySignatureReview *review, Privileged::Error *error,
    const VerificationLimits &limits = VerificationLimits());
} }
#endif
