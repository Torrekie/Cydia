/* Native version semantics through a trusted parent-owned read-only callback.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderNativeVersionComparison_HPP
#define Cydia_AptProviderNativeVersionComparison_HPP
#include "Cydia/AptProviderBinaryRelationships.hpp"
#include "Cydia/DpkgRunner.h"

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumNativeVersionPairs = 256;
struct NativeVersionQueryRequest {
    std::string nativeAuthorityIdentity;
    std::vector<std::string> arguments;
    std::size_t maximumOutputBytes = 1; // Any stdout is unexpected.
    unsigned timeoutMilliseconds = 3000;
};
struct NativeVersionQueryReply {
    CydiaRuntime::Dpkg::Result result = {CydiaRuntime::Dpkg::ResultKind::LaunchFailed, -1, 0};
    std::string output, nativeAuthorityIdentity;
};
// Only an implementation owned by the native parent may be supplied. The
// callback must enforce the requested output/time/cancellation bounds and
// retain root/frontend-lock ownership. It must independently verify the exact
// selected binary, full native configuration and loader closure immediately
// before and after each read-only query, returning the captured identity only
// if both checks succeed. A worker callback or claimed identity is not proof.
using NativeVersionQuery = std::function<NativeVersionQueryReply(const NativeVersionQueryRequest &,
    const std::function<bool()> &cancelled)>;
// Belongs to one frozen, parent-captured native generation. Caller revalidates
// that complete authority before cache reuse and discards this comparator for
// another capture/component generation; cached results do not recheck files.
// Serialized parent use only. Copies share bounded cache and sticky failure.
// No executable is chosen or spawned here. Exact native exit codes determine
// ordering; no localized prose, lexical shortcut or APT fallback is used.
// Invalid inputs return InvalidVersion without consuming query budget. Bad
// factory authority/missing callback and exhausted budget return Unavailable.
// Cancellation, callback exceptions, mismatched authority or query failure
// return Failed and discard all cached results permanently for this instance.
BinaryRelationships::VersionComparator MakeNativeVersionComparator(const std::string &nativeAuthorityIdentity,
    NativeVersionQuery, const std::function<bool()> &cancelled = {});
}} // namespace CydiaAPT::Provider
#endif
