/* Root-owned regular-file evidence. Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#ifndef Cydia_AptProviderComponentCapture_HPP
#define Cydia_AptProviderComponentCapture_HPP
#include "Cydia/AptProviderTransactionLease.hpp"
namespace CydiaAPT { namespace Provider {
// No archive parsing or execution. Final symlinks and hardlinks reject;
// protected directory aliases bind the complete parent/target identity chain.
bool CaptureTransactionComponent(const std::string &, InstalledComponentEvidence *,
    std::string *error, const std::function<bool()> &cancelled = {});
// Internal helper-owned retained descriptor. Computes all supported hashes on
// that descriptor and verifies its current named path and protected parents.
bool CaptureRetainedTransactionFile(const std::string &, int descriptor, StagedArchiveEvidence *,
    std::string *error, const std::function<bool()> &cancelled = {});
}}
#endif
