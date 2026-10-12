/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_ProviderProgressPolicy_HPP
#define Cydia_ProviderProgressPolicy_HPP

#include <cstdint>
#include <limits>

namespace CydiaAPT { namespace Provider {

/* The protocol's counters have no declared unit. Use their ratio only, never
 * present package/item counts as download bytes. NaN is the existing native
 * progress model's indeterminate state. */
inline double ProgressFraction(std::uint64_t current, std::uint64_t total) {
    if (total == 0) return std::numeric_limits<double>::quiet_NaN();
    if (current >= total) return 1.0;
    return static_cast<double>(current) / static_cast<double>(total);
}

class ProgressCancellation {
    bool active_ = false, cancellable_ = false, cancelled_ = false;
public:
    void Begin(bool cancellable) { active_ = true; cancellable_ = cancellable; cancelled_ = false; }
    void SetCancellable(bool cancellable) { if (active_) cancellable_ = cancellable; }
    bool Poll(bool requested) {
        if (active_ && cancellable_ && requested) cancelled_ = true;
        return active_ && cancelled_;
    }
    void End() { active_ = cancellable_ = false; }
    bool active() const { return active_; }
    bool cancellable() const { return active_ && cancellable_ && !cancelled_; }
    bool wasCancelled() const { return cancelled_; }
};

}} // namespace CydiaAPT::Provider
#endif
