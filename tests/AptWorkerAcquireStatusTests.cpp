/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptWorkerAcquireStatus.hpp"
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/init.h>
#include <apt-pkg/configuration.h>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[apt-worker-progress] " << message << '\n'; std::abort(); }
}
struct Item : pkgAcquire::Item {
    std::string uri;
    Item(pkgAcquire *owner, const std::string &uri) : pkgAcquire::Item(owner), uri(uri) {}
    std::string DescURI() const override { return uri; }
    HashStringList GetExpectedHashes() const override { return {}; }
};
}
int main() {
    Require(pkgInitConfig(*_config), "isolated default configuration");
    P::WorkerAcquireStatus status;
    std::vector<P::ProgressEvent> events;
    bool cancelled = false, channel = true;
    status.SetCallbacks([&](const P::ProgressEvent &event) {
        Require(P::ValidProgressEvent(event), "worker emitted invalid source activity");
        events.push_back(event); return channel;
    }, [&]() { return cancelled; });
    pkgAcquire acquire(&status);
    auto *item = new Item(&acquire, "https://name:secret@repo.invalid/dists/stable/Release");
    pkgAcquire::ItemDesc description;
    description.Owner = item; description.URI = item->DescURI();
    status.Start();
    Require(events.size() == 1 && events.back().cancellable, "start enables cancellation");
    status.Fetch(description); status.Fetch(description);
    Require(events.size() == 2 && events.back().sourceActivity == P::SourceActivity::Started &&
            events.back().sourceURI == item->DescURI() && events.back().message.empty(),
            "source starts once without displaying transport credentials");
    item->Status = pkgAcquire::Item::StatError;
    item->ErrorText = "Upstream diagnostic https://name:secret@repo.invalid/private?token=secret";
    status.Fail(description);
    Require(events.size() == 4 && events[2].sourceActivity == P::SourceActivity::Finished &&
            events[3].message == "Upstream diagnostic https://repo.invalid/[redacted]" &&
            events[3].type == "Error", "failure stops source activity and preserves redacted upstream diagnostic");
    item->Status = pkgAcquire::Item::StatFetching; item->QueueCounter = 1;
    Require(status.Pulse(&acquire) && events[4].sourceActivity == P::SourceActivity::Started,
            "pulse reconciles a newly fetching source");
    item->Status = pkgAcquire::Item::StatDone; item->QueueCounter = 0;
    const auto before(events.size());
    Require(status.Pulse(&acquire) && events[before].sourceActivity == P::SourceActivity::Finished,
            "pulse reconciles completed activity");
    status.Stop();
    Require(!events.back().cancellable && events.back().sourceURI.empty(), "stop disables cancellation");
    status.Start(); cancelled = true;
    Require(!status.Pulse(&acquire) && status.failed(), "cancellation stops acquisition");
    cancelled = false;
    Require(!status.Pulse(&acquire), "cancellation stays latched until a new operation");
    status.Stop(); status.Start(); channel = false;
    Require(!status.Pulse(&acquire) && status.failed(), "failed transport cancels acquisition");
    Require(!status.MediaChange("fixture", "fixture"), "worker cannot approve an unavailable media prompt");
    std::cout << "[apt-worker-progress] source activity, upstream diagnostics and cancellation passed\n";
}
