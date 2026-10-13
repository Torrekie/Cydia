/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RuntimeState_HPP
#define Cydia_RuntimeState_HPP
#include "Cydia/PrivilegedRuntime.hpp"
#include <functional>
namespace CydiaRuntime { namespace Privileged {
bool RuntimeSnapshot(const Environment &environment, std::string *token, Error *error,
                     const std::function<bool()> &cancelled = {});
/* Stored as authentication evidence only after a successful metadata refresh.
 * A cache reload or a fresh transaction snapshot cannot renew this proof. */
bool TrustSnapshot(const Environment &environment, std::string *token, Error *error,
                     const std::function<bool()> &cancelled = {});
bool ReadExtendedState(const Environment &environment, std::string *bytes, Error *error);
bool CommitExtendedState(const Environment &environment, const std::string &payload, Error *error);
} }
#endif
