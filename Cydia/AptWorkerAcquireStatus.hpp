/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptWorkerAcquireStatus_HPP
#define Cydia_AptWorkerAcquireStatus_HPP
#include "Cydia/AptProviderProtocol.hpp"
#include <apt-pkg/acquire.h>
#include <functional>
#include <set>

namespace CydiaAPT { namespace Provider {

// Cooperative status adapter for an unprivileged worker's libapt acquire loop.
// Callbacks are scoped to one serialized operation and must not be retained by
// the receiver. Transport failure cancels acquisition; no UIKit or English
// translations of APT diagnostics are needed in the worker.
class WorkerAcquireStatus : public pkgAcquireStatus {
    std::function<bool(const ProgressEvent &)> progress_;
    std::function<bool()> cancelled_;
    std::set<std::string> active_;
    bool stopped_ = true, failed_ = false;
    bool PollCancellation();
    bool Emit(ProgressEvent event);
    void Activity(const std::string &uri, SourceActivity activity);
public:
    WorkerAcquireStatus();
    void SetCallbacks(const std::function<bool(const ProgressEvent &)> &progress,
                      const std::function<bool()> &cancelled);
    bool failed() const { return failed_; }
    bool MediaChange(std::string, std::string) override;
    void IMSHit(pkgAcquire::ItemDesc &item) override;
    void Fetch(pkgAcquire::ItemDesc &item) override;
    void Done(pkgAcquire::ItemDesc &item) override;
    void Fail(pkgAcquire::ItemDesc &item) override;
    bool Pulse(pkgAcquire *owner) override;
    void Start() override;
    void Stop() override;
};
}} // namespace CydiaAPT::Provider
#endif
