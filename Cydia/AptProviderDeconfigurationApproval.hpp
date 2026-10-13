/* Canonical approval transport; decoded values never establish authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderDeconfigurationApproval_HPP
#define Cydia_AptProviderDeconfigurationApproval_HPP
#include "Cydia/AptProviderDeconfigurationEffects.hpp"

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumDeconfigurationApprovalBytes = 8 * 1024 * 1024;

// Standalone CYDIA-DECONFIGURATION-APPROVAL-1 framing. This does not change the
// provider/transaction wire or advertise/enable deconfiguration. Only approval
// values travel: exact review, identities, old generations, ordered causes and
// existing endpoints; protected files and script bytes are never included.
//
// Shape validation does not recompute asserted digests, evaluate relationships
// or prove native policy. The parent must independently capture/rebuild the
// allowance set and compare canonical bytes under its existing review/lock
// lifecycle. Public decoded data is never sufficient execution authority.
// Both functions clear their output on failure, and publish no partial result.
bool EncodeDeconfigurationApproval(const DeconfigurationAllowanceSet &, std::string *,
    std::string *error = nullptr);
bool DecodeDeconfigurationApproval(const std::string &, DeconfigurationAllowanceSet *,
    std::string *error = nullptr);
}}
#endif
