/* Reusable Cydia provider dispatch; no process launcher or privileged executor.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderServer_HPP
#define Cydia_AptProviderServer_HPP
#include "Cydia/AptProviderProtocol.hpp"
#include <functional>
#include <memory>

namespace CydiaAPT { namespace Provider {

// A caller may feed arbitrary socket/pipe chunks without allocating a body
// from an unchecked length. Each call consumes at most one complete frame.
class ServerFrameReader {
    std::string bytes_, error_;
    std::size_t expected_ = 8;
public:
    bool Push(const char *bytes, std::size_t size, std::size_t *consumed,
              std::string *frame, bool *complete);
    const std::string &error() const { return error_; }
};

struct ServerControl {
    // Callback-scoped and serialized; never retain or invoke on another thread.
    // cancelled also pumps one pending Cancel frame and emits its acknowledgement.
    std::function<bool()> cancelled;
    std::function<unsigned()> remainingMilliseconds;
};
struct ServerRequestContext {
    ServerControl control;
    std::function<bool(const ProgressEvent &)> progress;
    std::function<bool(Operation, const std::string &, Message *)> parentRequest;
};
struct ServerHooks {
    // Admission must independently validate the registration, selected runtime,
    // environment, executable identity and supported options before returning Info.
    // No callback means denied. This core cannot turn an ordinary apt into a provider.
    std::function<bool(const Hello &, Info *, std::string *)> admit;

    // Transport callbacks own bounded nonblocking I/O. Empty poll output means
    // nothing is ready. All callbacks must honor remainingMilliseconds; the
    // core cannot preempt a blocking foreign callback. No callback owns cydo.
    // One channel driver owns the reader and writer. While parentExchange is
    // waiting it must route Cancel frames to pollControl's queue, retain the
    // matching ParentResponse for itself, and pump control.cancelled(). It must
    // never let pollControl consume that parent reply or recursively dispatch.
    // emitFrame serializes acknowledgements/progress with parentExchange writes.
    std::function<bool(std::string *, const ServerControl &)> pollControl;
    std::function<bool(const std::string &, const ServerControl &)> emitFrame;
    std::function<bool(const std::string &, std::string *, const ServerControl &)> parentExchange;

    // Install/clear cooperative progress/cancellation in the injected backend.
    // Called with nullptr even when a dispatched operation throws. The context
    // is valid only until it is cleared; dispatch/callbacks are not reentrant.
    std::function<void(const ServerRequestContext *)> operationContext;
    std::function<bool(const TransactionData &, const Binding &, ExecutionManifest *, std::string *)> buildReview;
    // Explicit bridges avoid calling BackendImplementation's app-specific
    // AcquireStatus or direct dpkg execution. Execution must use parentRequest.
    std::function<UpdateResultData(int, const ServerRequestContext &)> updateLists;
    // Completed requires all reviewed actions and a successful parent
    // CommitExtendedState for these exact review-time deltas, even when empty.
    std::function<PackageManagerReply(const ReviewedTransaction &, const std::vector<AutoInstalledDelta> &,
                                     const ServerRequestContext &)> runPackageManager;
    // Optional, process-local reconfiguration only; true ends this session.
    std::function<bool(RepositorySecurityMode, const ServerRequestContext &)> setSecurityMode;
    std::function<bool(const ServerRequestContext &)> refreshArchitectures;
};
struct ServerLimits {
    unsigned requestMilliseconds = 30000;
    unsigned operationMilliseconds = 3 * 60 * 60 * 1000;
    std::size_t exchangeBytes = 256 * 1024 * 1024;
    unsigned exchangeMessages = 4096;
};

// The backend and hooks outlive this object. No launch, activation, root
// credentials, file mutation, global APT state or output logging is supplied.
// The injected backend owns only its unprivileged/private cache operations.
// In particular, this core never calls its lock/unlock/runPackageManager methods.
// A socket loop uses ServerFrameReader then DispatchFrame and writes the result
// under its deadline. False means close the transport; never retry that frame.
class Server {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
public:
    Server(Internal::BackendImplementation &backend, const ServerHooks &hooks,
           const ServerLimits &limits = ServerLimits());
    ~Server();
    Server(const Server &) = delete;
    Server &operator=(const Server &) = delete;
    bool DispatchFrame(const std::string &request, std::string *response);
    bool ready() const;
    bool closed() const;
    const Binding &binding() const;
    const std::string &lastError() const;
};
}} // namespace CydiaAPT::Provider
#endif
