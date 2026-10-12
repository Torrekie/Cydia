/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/ProviderProgressPolicy.hpp"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>

namespace {
void Require(bool value, const char *message) {
    if (value) return;
    std::fprintf(stderr, "[provider-progress] %s\n", message);
    std::exit(1);
}
}

int main() {
    using namespace CydiaAPT::Provider;
    Require(std::isnan(ProgressFraction(0, 0)) && std::isnan(ProgressFraction(123, 0)),
        "unknown totals are indeterminate, never divided by zero");
    Require(ProgressFraction(0, 100) == 0.0 && ProgressFraction(25, 100) == 0.25 &&
        ProgressFraction(101, 100) == 1.0, "known progress is bounded");
    const auto maximum(std::numeric_limits<std::uint64_t>::max());
    Require(ProgressFraction(maximum, 1) == 1.0 && ProgressFraction(maximum, maximum) == 1.0 &&
        std::isfinite(ProgressFraction(maximum / 2, maximum)), "large counters do not overflow");

    ProgressCancellation state;
    Require(!state.Poll(true), "idle cancellation is ignored");
    state.Begin(false);
    Require(!state.Poll(true) && !state.wasCancelled(), "non-cancellable execution is not interrupted");
    state.SetCancellable(true);
    Require(state.cancellable() && state.Poll(true), "user cancellation is observed without an APT pulse");
    state.SetCancellable(false);
    Require(state.Poll(false) && state.wasCancelled() && !state.cancellable(),
        "an accepted cancellation survives later progress updates");
    state.SetCancellable(true);
    Require(!state.cancellable(), "cancel is not re-enabled after a request");
    state.End();
    Require(!state.active() && !state.Poll(true) && state.wasCancelled(),
        "ending disables cancellation but preserves the operation outcome");
    state.Begin(true);
    Require(!state.wasCancelled() && state.cancellable() && !state.Poll(false),
        "a new operation does not inherit cancellation");
    std::puts("[provider-progress] bounded counters and operation cancellation passed");
}
