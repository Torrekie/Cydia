/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptWorkerAcquireStatus.hpp"
#include "Cydia/RedactedURL.hpp"
#include <apt-pkg/acquire-item.h>
#include <limits>
#include <vector>

namespace CydiaAPT { namespace Provider {
namespace {
std::uint64_t Sum(std::uint64_t bytes, std::uint64_t items) {
    const auto maximum(std::numeric_limits<std::uint64_t>::max());
    return items > maximum - bytes ? maximum : bytes + items;
}
std::string ItemURI(pkgAcquire::ItemDesc &item) {
    return item.Owner ? item.Owner->DescURI() : item.URI;
}
}
WorkerAcquireStatus::WorkerAcquireStatus() { MorePulses = true; }
void WorkerAcquireStatus::SetCallbacks(const std::function<bool(const ProgressEvent &)> &progress,
                                      const std::function<bool()> &cancelled) {
    progress_ = progress; cancelled_ = cancelled;
}
bool WorkerAcquireStatus::PollCancellation() {
    if (failed_) return true;
    try { if (cancelled_ && cancelled_()) failed_ = true; }
    catch (...) { failed_ = true; }
    return failed_;
}
bool WorkerAcquireStatus::Emit(ProgressEvent event) {
    if (PollCancellation()) return false;
    event.current = Sum(CurrentBytes, CurrentItems);
    event.total = Sum(TotalBytes, TotalItems);
    event.cancellable = !stopped_;
    event.message = CydiaRuntime::RedactDiagnosticURLs(event.message);
    try { if (!progress_ || !progress_(event)) failed_ = true; }
    catch (...) { failed_ = true; }
    return !failed_;
}
void WorkerAcquireStatus::Activity(const std::string &uri, SourceActivity activity) {
    if (uri.empty()) return;
    if (activity == SourceActivity::Started) {
        if (!active_.insert(uri).second) return;
    } else if (!active_.erase(uri)) return;
    ProgressEvent event; event.sourceActivity = activity; event.sourceURI = uri;
    (void) Emit(event);
}
bool WorkerAcquireStatus::MediaChange(std::string, std::string) {
    // There is no worker-side media prompt. Do not silently approve a change.
    return false;
}
void WorkerAcquireStatus::IMSHit(pkgAcquire::ItemDesc &item) { Done(item); }
void WorkerAcquireStatus::Fetch(pkgAcquire::ItemDesc &item) { Activity(ItemURI(item), SourceActivity::Started); }
void WorkerAcquireStatus::Done(pkgAcquire::ItemDesc &item) { Activity(ItemURI(item), SourceActivity::Finished); }
void WorkerAcquireStatus::Fail(pkgAcquire::ItemDesc &item) {
    Done(item);
    if (!item.Owner || item.Owner->Status == pkgAcquire::Item::StatIdle ||
        item.Owner->Status == pkgAcquire::Item::StatDone || item.Owner->ErrorText.empty()) return;
    ProgressEvent event; event.type = "Error"; event.message = item.Owner->ErrorText;
    (void) Emit(event);
}
bool WorkerAcquireStatus::Pulse(pkgAcquire *owner) {
    if (!owner || PollCancellation() || !pkgAcquireStatus::Pulse(owner)) return false;
    std::set<std::string> fetching;
    for (auto item = owner->ItemsBegin(); item != owner->ItemsEnd(); ++item)
        if ((*item)->QueueCounter && (*item)->Status == pkgAcquire::Item::StatFetching) {
            const auto uri((*item)->DescURI());
            fetching.insert(uri); Activity(uri, SourceActivity::Started);
        }
    const std::vector<std::string> previous(active_.begin(), active_.end());
    for (const auto &uri : previous) if (!fetching.count(uri)) Activity(uri, SourceActivity::Finished);
    return Emit(ProgressEvent());
}
void WorkerAcquireStatus::Start() {
    pkgAcquireStatus::Start(); active_.clear(); stopped_ = false; failed_ = false;
    (void) Emit(ProgressEvent());
}
void WorkerAcquireStatus::Stop() {
    pkgAcquireStatus::Stop(); stopped_ = true;
    const std::vector<std::string> previous(active_.begin(), active_.end());
    for (const auto &uri : previous) Activity(uri, SourceActivity::Finished);
    active_.clear(); (void) Emit(ProgressEvent());
}
}} // namespace CydiaAPT::Provider
