/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_KeyringVerifier_HPP
#define Cydia_KeyringVerifier_HPP
#include "Cydia/PrivilegedRuntime.hpp"
namespace CydiaRuntime { namespace Keyring {
/* Portable GnuPG adapter. This owns bounded public-key normalization in a
 * fresh 0700 temporary home, not privileged path authorization. Privileged
 * callers independently validate the executable and staging parent first. */
bool VerifyPublicKey(const std::string &verifier, const std::string &temporaryParent,
    const std::string &input, std::string *normalized,
    std::vector<std::string> *fingerprints, Privileged::Error *error);
} }
#endif
