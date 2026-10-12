/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderServerTransport.hpp"
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <climits>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
using Clock = std::chrono::steady_clock;
using Deadline = Clock::time_point;
constexpr unsigned MaximumMilliseconds = 3 * 60 * 60 * 1000;
constexpr unsigned SettlementMilliseconds = 2000;
unsigned Remaining(Deadline deadline) {
    const auto value(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count());
    return value <= 0 ? 0 : static_cast<unsigned>(std::min<decltype(value)>(value, UINT_MAX));
}
struct Flag {
    bool &flag;
    explicit Flag(bool &flag) : flag(flag) { flag = true; }
    ~Flag() { flag = false; }
};
}

class ServerTransport::Implementation {
public:
    int socket;
    unsigned writeMilliseconds;
    ServerFrameReader reader;
    std::string tail, controlFrame, parentFrame, error;
    Message parentRequest;
    bool partial = false, running = false, reading = false, writing = false, parentWaiting = false;
    std::function<bool()> stopping;

    Implementation(int ownedSocket, unsigned writeMilliseconds) : socket(ownedSocket), writeMilliseconds(writeMilliseconds) {
        int type(0); socklen_t length(sizeof(type));
        if (socket < 0 || !writeMilliseconds || writeMilliseconds > 30000 ||
            getsockopt(socket, SOL_SOCKET, SO_TYPE, &type, &length) != 0 || type != SOCK_STREAM) {
            Fail("provider_invalid_channel"); return;
        }
        const int flags(fcntl(socket, F_GETFL));
        const int descriptorFlags(fcntl(socket, F_GETFD));
        if (flags < 0 || descriptorFlags < 0 || fcntl(socket, F_SETFL, flags | O_NONBLOCK) != 0 ||
            fcntl(socket, F_SETFD, descriptorFlags | FD_CLOEXEC) != 0) { Fail("provider_channel_failed"); return; }
#ifdef SO_NOSIGPIPE
        const int one(1);
        if (setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0) Fail("provider_channel_failed");
#endif
    }
    ~Implementation() { Close(); }
    void Close() {
        if (socket >= 0) { close(socket); socket = -1; }
        tail.clear(); controlFrame.clear(); parentFrame.clear();
    }
    bool Fail(const std::string &code) { if (error.empty()) error = code; Close(); return false; }
    bool Stopping() {
        try { return stopping && stopping(); }
        catch (...) { Fail("provider_stop_callback_failed"); return true; }
    }
    bool Wait(short events, Deadline deadline) {
        if (socket < 0) return false;
        struct pollfd descriptor = {socket, events, 0};
        const int result(poll(&descriptor, 1, static_cast<int>(std::min(Remaining(deadline), 25u))));
        if (result < 0 && errno != EINTR) return Fail("provider_channel_failed");
        if (result > 0 && (descriptor.revents & POLLNVAL)) return Fail("provider_channel_failed");
        return true;
    }
    // Nonblocking, at most 64 KiB per call. A single reader serves all phases.
    // 1 = complete frame, 0 = no complete frame, -1 = failure, -2 = clean EOF.
    int TryRead(std::string *frame) {
        if (socket < 0 || !frame || reading) { Fail("provider_channel_failed"); return -1; }
        Flag guard(reading); frame->clear();
        std::size_t received(0); unsigned attempts(0);
        for (;;) {
            // Repeated EINTR must yield to the caller's deadline as well.
            if (++attempts > 64) return 0;
            if (!tail.empty()) {
                std::size_t consumed(0); bool complete(false);
                if (!reader.Push(tail.data(), tail.size(), &consumed, frame, &complete)) {
                    Fail(reader.error()); return -1;
                }
                partial = !complete; tail.erase(0, consumed);
                if (complete) return 1;
            }
            if (received >= 64u * 1024u) return 0;
            char buffer[8192]; const ssize_t count(recv(socket, buffer, sizeof(buffer), 0));
            if (count > 0) { tail.assign(buffer, static_cast<std::size_t>(count)); received += count; continue; }
            if (count == 0) {
                if (partial) { Fail("provider_truncated_frame"); return -1; }
                Close(); return -2;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            if (errno == EINTR) continue;
            Fail("provider_disconnected"); return -1;
        }
    }
    bool Write(const std::string &frame, Deadline deadline) {
        if (socket < 0 || writing || frame.size() > MaximumMessageBytes) return Fail("provider_invalid_frame");
        Message checked;
        if (!DecodeFrame(frame, &checked)) return Fail("provider_invalid_frame");
        Flag guard(writing); std::size_t offset(0);
        while (offset != frame.size()) {
            if (!Remaining(deadline)) return Fail("provider_write_timeout");
            // Do not read/pump callbacks while part of this frame is written:
            // an acknowledgement must never be interleaved into those bytes.
            int flags(0);
#ifdef MSG_NOSIGNAL
            flags |= MSG_NOSIGNAL;
#endif
            const ssize_t count(send(socket, frame.data() + offset, frame.size() - offset, flags));
            if (count > 0) { offset += static_cast<std::size_t>(count); continue; }
            if (count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK))
                return Fail("provider_disconnected");
            if (!Wait(POLLOUT, deadline)) return false;
        }
        return true;
    }
    Deadline WriteDeadline(const ServerControl &control) const {
        const unsigned remaining(control.remainingMilliseconds ? control.remainingMilliseconds() : 0);
        // A cancellation acknowledgement still has a short settlement budget
        // when the original operation deadline has already elapsed.
        return Clock::now() + std::chrono::milliseconds(std::min(writeMilliseconds,
            remaining ? remaining : SettlementMilliseconds));
    }
    bool Route(const std::string &frame) {
        Message message;
        if (!DecodeFrame(frame, &message)) return Fail("provider_invalid_frame");
        if (message.kind == MessageKind::Request && message.operation == Operation::Cancel) {
            if (!controlFrame.empty()) return Fail("provider_invalid_cancel_request");
            controlFrame = frame; return true;
        }
        if (parentWaiting && message.kind == MessageKind::ParentResponse && parentFrame.empty() &&
            ValidateReply(parentRequest, message)) { parentFrame = frame; return true; }
        return Fail("provider_unexpected_message");
    }
    bool PollControl(std::string *frame, const ServerControl &) {
        if (!running || socket < 0 || !frame || reading || writing) return Fail("provider_channel_failed");
        frame->clear();
        if (Stopping()) return Fail("provider_stopped");
        if (controlFrame.empty()) {
            std::string incoming; const int result(TryRead(&incoming));
            if (result < 0) return Fail("provider_disconnected");
            if (result == 1 && !Route(incoming)) return false;
        }
        frame->swap(controlFrame); return true;
    }
    bool Emit(const std::string &frame, const ServerControl &control) {
        return running && Write(frame, WriteDeadline(control));
    }
    bool Parent(const std::string &frame, std::string *reply, const ServerControl &control) {
        if (!running || !reply || parentWaiting || !parentFrame.empty() || !DecodeFrame(frame, &parentRequest) ||
            parentRequest.kind != MessageKind::ParentRequest || !ValidRequestBinding(parentRequest))
            return Fail("provider_invalid_parent_request");
        Flag guard(parentWaiting); reply->clear();
        if (!Write(frame, WriteDeadline(control))) return false;
        const unsigned remaining(control.remainingMilliseconds ? control.remainingMilliseconds() : 0);
        Deadline deadline(Clock::now() + std::chrono::milliseconds(std::min(remaining, MaximumMilliseconds)));
        bool settling(false);
        while (socket >= 0) {
            // This may consume only a Cancel, or queue a ParentResponse. It
            // never nests inside TryRead, and acknowledgement writes happen
            // only after the complete reverse request was written above.
            const bool cancelled(control.cancelled && control.cancelled());
            if (socket < 0) return false;
            if (cancelled && !settling) {
                settling = true; deadline = Clock::now() + std::chrono::milliseconds(SettlementMilliseconds);
            }
            if (!parentFrame.empty()) { reply->swap(parentFrame); return true; }
            if (!Remaining(deadline)) return Fail("provider_parent_timeout");
            if (Stopping()) return Fail("provider_stopped");
            std::string incoming; const int result(TryRead(&incoming));
            if (result < 0) return Fail("provider_disconnected");
            if (result == 1) { if (!Route(incoming)) return false; continue; }
            if (!Wait(POLLIN, deadline)) return false;
        }
        return false;
    }
    ServerTransportResult One(Server &server, unsigned milliseconds, const std::function<bool()> &stop) {
        if (socket < 0 || running || !milliseconds || milliseconds > MaximumMilliseconds) {
            Fail("provider_invalid_channel"); return ServerTransportResult::Failed;
        }
        if (server.closed()) { Close(); return ServerTransportResult::Stopped; }
        Flag guard(running); stopping = stop;
        const Deadline deadline(Clock::now() + std::chrono::milliseconds(milliseconds));
        std::string request;
        for (;;) {
            if (Stopping()) {
                const bool failed(!error.empty()); Close(); stopping = {};
                return failed ? ServerTransportResult::Failed : ServerTransportResult::Stopped;
            }
            if (!Remaining(deadline)) { Fail("provider_timeout"); stopping = {}; return ServerTransportResult::TimedOut; }
            const int result(TryRead(&request));
            if (result == -2) { stopping = {}; return ServerTransportResult::EndOfStream; }
            if (result < 0) { stopping = {}; return ServerTransportResult::Failed; }
            if (result == 1) break;
            if (!Wait(POLLIN, deadline)) { stopping = {}; return ServerTransportResult::Failed; }
        }
        std::string response;
        if (!server.DispatchFrame(request, &response)) {
            Fail(server.lastError().empty() ? "provider_dispatch_failed" : server.lastError());
            stopping = {}; return ServerTransportResult::Failed;
        }
        if (!Write(response, Clock::now() + std::chrono::milliseconds(writeMilliseconds))) {
            stopping = {}; return ServerTransportResult::Failed;
        }
        if (server.closed()) Close();
        stopping = {}; return ServerTransportResult::Dispatched;
    }
};

ServerTransport::ServerTransport(int socket, unsigned writeMilliseconds) :
    implementation_(new Implementation(socket, writeMilliseconds)) {}
ServerTransport::~ServerTransport() {}
bool ServerTransport::Attach(ServerHooks *hooks) {
    auto *state(implementation_.get());
    if (!hooks || state->socket < 0 || state->running) return false;
    hooks->pollControl = [state](std::string *frame, const ServerControl &control) { return state->PollControl(frame, control); };
    hooks->emitFrame = [state](const std::string &frame, const ServerControl &control) { return state->Emit(frame, control); };
    hooks->parentExchange = [state](const std::string &frame, std::string *reply, const ServerControl &control) {
        return state->Parent(frame, reply, control);
    };
    return true;
}
ServerTransportResult ServerTransport::RunOne(Server &server, unsigned milliseconds, const std::function<bool()> &stopping) {
    return implementation_->One(server, milliseconds, stopping);
}
ServerTransportResult ServerTransport::Serve(Server &server, unsigned milliseconds, const std::function<bool()> &stopping) {
    for (;;) {
        const auto result(RunOne(server, milliseconds, stopping));
        if (result != ServerTransportResult::Dispatched) return result;
        if (server.closed()) return ServerTransportResult::Stopped;
    }
}
void ServerTransport::Close() { implementation_->Close(); }
bool ServerTransport::valid() const { return implementation_->socket >= 0; }
const std::string &ServerTransport::lastError() const { return implementation_->error; }
}} // namespace CydiaAPT::Provider
