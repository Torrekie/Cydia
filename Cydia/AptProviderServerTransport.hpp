/* Serialized socket transport for the reusable Cydia provider server.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderServerTransport_HPP
#define Cydia_AptProviderServerTransport_HPP
#include "Cydia/AptProviderServer.hpp"

namespace CydiaAPT { namespace Provider {
enum class ServerTransportResult { Dispatched, EndOfStream, TimedOut, Stopped, Failed };

class ServerTransport {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
public:
    // Consumes this exclusively owned connected stream socket even on failure.
    // The same socket carries input/output; no descriptor or child is inherited
    // or launched here. All methods and installed callbacks use one thread.
    explicit ServerTransport(int ownedSocket, unsigned writeMilliseconds = 2000);
    ~ServerTransport();
    ServerTransport(const ServerTransport &) = delete;
    ServerTransport &operator=(const ServerTransport &) = delete;

    // Installs only pollControl, emitFrame and parentExchange. This transport
    // must outlive the Server constructed from those hooks. Never replace them
    // after a session has begun or read/write the owned socket elsewhere.
    bool Attach(ServerHooks *hooks);
    // Reads one bounded frame, dispatches and writes its complete response.
    // Timeout/stop/error closes the channel. The stop callback is cooperative;
    // arbitrary backend calls cannot be preempted and must poll their context.
    ServerTransportResult RunOne(Server &server, unsigned readMilliseconds = 30000,
        const std::function<bool()> &stopping = std::function<bool()>());
    // A worker entry point may serve until EOF, close, stop or a finite idle
    // timeout. Per-operation deadlines remain those chosen by ServerLimits.
    ServerTransportResult Serve(Server &server, unsigned idleMilliseconds = 3 * 60 * 60 * 1000,
        const std::function<bool()> &stopping = std::function<bool()>());
    void Close();
    bool valid() const;
    const std::string &lastError() const;
};
}} // namespace CydiaAPT::Provider
#endif
