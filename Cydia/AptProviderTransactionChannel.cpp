/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionChannel.hpp"
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider { namespace TransactionChannel {
namespace {
bool Token(const std::string &value, bool empty = false) {
    if (value.empty()) return empty;
    if (value.size() > 256) return false;
    for (const unsigned char byte : value)
        if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
            (byte >= '0' && byte <= '9') || byte == '_' || byte == '-' || byte == ':' || byte == '.')) return false;
    return true;
}
bool Number(const std::string &value, std::uint64_t *result) {
    if (value.empty() || (value.size() > 1 && value[0] == '0')) return false;
    std::uint64_t number = 0;
    for (const unsigned char byte : value) {
        if (byte < '0' || byte > '9' || number > (UINT64_MAX - (byte - '0')) / 10) return false;
        number = number * 10 + byte - '0';
    }
    *result = number; return true;
}
bool Valid(const Frame &frame) {
    if (static_cast<unsigned>(frame.operation) > static_cast<unsigned>(Operation::Close) ||
        static_cast<unsigned>(frame.event) > static_cast<unsigned>(Event::Settled) ||
        !Token(frame.reviewDigest) || !Token(frame.errorCode, true) || !Token(frame.nonce, true)) return false;
    if (frame.operation == Operation::Begin) {
        if (frame.sequence != 0 || (frame.event == Event::Request && !frame.nonce.empty()) ||
            (frame.event == Event::Settled && frame.success && frame.nonce.empty())) return false;
    } else if (!frame.sequence || frame.nonce.empty()) return false;
    const bool mutating = frame.operation == Operation::Execute || frame.operation == Operation::Commit;
    if (!mutating && (frame.mutationStarted || frame.indeterminate)) return false;
    if (frame.event == Event::Request)
        return !frame.success && !frame.mutationStarted && !frame.indeterminate && frame.errorCode.empty();
    if (frame.event == Event::Started)
        return mutating && frame.success && frame.mutationStarted && !frame.indeterminate &&
            frame.payload.empty() && frame.errorCode.empty();
    return frame.success ? frame.errorCode.empty() && !frame.indeterminate : !frame.errorCode.empty();
}
void Field(std::string &output, const std::string &value) {
    output += std::to_string(value.size()); output += ':'; output += value; output += ',';
}
bool Fields(const std::string &bytes, std::vector<std::string> *values) {
    if (bytes.size() > MaximumFrameBytes) return false;
    std::size_t offset = 0;
    while (offset < bytes.size() && values->size() < 11) {
        const auto colon = bytes.find(':', offset);
        std::uint64_t size;
        if (colon == std::string::npos || colon - offset > 8 ||
            !Number(bytes.substr(offset, colon - offset), &size) ||
            size > bytes.size() - colon - 1 || size == bytes.size() - colon - 1 ||
            bytes[colon + 1 + size] != ',') return false;
        values->push_back(bytes.substr(colon + 1, size)); offset = colon + 2 + size;
    }
    return offset == bytes.size() && values->size() == 11;
}
void CloseAll(std::vector<int> &descriptors) {
    for (const int descriptor : descriptors) close(descriptor);
    descriptors.clear();
}
bool DescriptorRoles(const Frame &frame, const std::vector<int> &descriptors) {
    const bool execution = frame.operation == Operation::Execute && frame.event == Event::Request;
    if (descriptors.size() != (execution ? 2u : 0u)) return false;
    for (std::size_t i = 0; i < descriptors.size(); ++i) {
        struct stat status; const int flags = fcntl(descriptors[i], F_GETFL);
        if (flags < 0 || fstat(descriptors[i], &status) ||
            (!S_ISFIFO(status.st_mode) && !S_ISSOCK(status.st_mode)) ||
            (i == 0 && (flags & O_ACCMODE) == O_WRONLY) ||
            (i == 1 && (flags & O_ACCMODE) == O_RDONLY)) return false;
    }
    return true;
}
class Deadline {
    unsigned timeout_;
    std::chrono::steady_clock::time_point end_;
    const std::function<bool()> &cancelled_;
public:
    Deadline(unsigned timeout, const std::function<bool()> &cancelled) : timeout_(timeout),
        end_(std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout)), cancelled_(cancelled) {}
    const char *Wait(int fd, short events) {
        for (;;) {
            if (cancelled_) {
                try { if (cancelled_()) return "provider_cancelled"; }
                catch (...) { return "provider_cancelled"; }
            }
            int delay = -1;
            if (timeout_) {
                const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(end_ - std::chrono::steady_clock::now()).count();
                if (left <= 0) return "provider_transaction_timeout";
                delay = static_cast<int>(std::min<long long>(left, 2147483647));
            }
            if (cancelled_) delay = delay < 0 ? 50 : std::min(delay, 50);
            pollfd request = {fd, events, 0}; const auto count = poll(&request, 1, delay);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) return "provider_transaction_io";
            if (!count) continue;
            if (request.revents & POLLNVAL) return "provider_transaction_io";
            return nullptr; // HUP/ERR must still be consumed by recv/send.
        }
    }
};
}
bool Encode(const Frame &frame, std::string *output) {
    if (!output || !Valid(frame) || frame.payload.size() > MaximumFrameBytes) return false;
    std::string bytes;
    for (const auto &value : std::vector<std::string>{"CYDIA-TRANSACTION-1", std::to_string(static_cast<unsigned>(frame.operation)),
            std::to_string(static_cast<unsigned>(frame.event)), std::to_string(frame.sequence), frame.nonce, frame.reviewDigest,
            frame.payload, frame.errorCode, frame.success ? "1" : "0", frame.mutationStarted ? "1" : "0",
            frame.indeterminate ? "1" : "0"}) Field(bytes, value);
    if (bytes.size() > MaximumFrameBytes) return false;
    *output = std::move(bytes); return true;
}
bool Decode(const std::string &bytes, Frame *output) {
    if (!output) return false;
    std::vector<std::string> fields;
    if (!Fields(bytes, &fields) || fields[0] != "CYDIA-TRANSACTION-1") return false;
    std::uint64_t operation, event; Frame frame;
    if (!Number(fields[1], &operation) || operation > static_cast<unsigned>(Operation::Close) ||
        !Number(fields[2], &event) || event > static_cast<unsigned>(Event::Settled) ||
        !Number(fields[3], &frame.sequence)) return false;
    frame.operation = static_cast<Operation>(operation); frame.event = static_cast<Event>(event);
    frame.nonce = fields[4]; frame.reviewDigest = fields[5]; frame.payload = fields[6]; frame.errorCode = fields[7];
    for (std::size_t i = 8; i < 11; ++i) if (fields[i] != "0" && fields[i] != "1") return false;
    frame.success = fields[8] == "1"; frame.mutationStarted = fields[9] == "1"; frame.indeterminate = fields[10] == "1";
    if (!Valid(frame)) return false;
    *output = std::move(frame); return true;
}
Channel::Channel(int ownedSocket) : socket_(ownedSocket) {
    int type = 0; socklen_t size = sizeof(type); sockaddr_storage local = {}, peer = {};
    socklen_t localSize = sizeof(local), peerSize = sizeof(peer);
    const int flags = fcntl(socket_, F_GETFL);
    if (flags < 0 || getsockopt(socket_, SOL_SOCKET, SO_TYPE, &type, &size) || type != SOCK_STREAM ||
        getsockname(socket_, reinterpret_cast<sockaddr *>(&local), &localSize) || local.ss_family != AF_UNIX ||
        getpeername(socket_, reinterpret_cast<sockaddr *>(&peer), &peerSize) || peer.ss_family != AF_UNIX ||
        fcntl(socket_, F_SETFD, FD_CLOEXEC) || fcntl(socket_, F_SETFL, flags | O_NONBLOCK)) {
        Fail("provider_transaction_channel_invalid"); return;
    }
#ifdef SO_NOSIGPIPE
    const int enabled = 1;
    if (setsockopt(socket_, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled))) Fail("provider_transaction_io");
#endif
}
Channel::~Channel() { Close(); }
void Channel::Close() { if (socket_ >= 0) close(socket_); socket_ = -1; }
bool Channel::Fail(const char *error) { error_ = error; Close(); return false; }
bool Channel::Send(const Frame &frame, const std::vector<int> &descriptors, unsigned timeout,
    const std::function<bool()> &cancelled, bool *anyBytesSent) {
    if (anyBytesSent) *anyBytesSent = false;
    std::string payload;
    if (!valid() || !Encode(frame, &payload) || !DescriptorRoles(frame, descriptors)) return Fail("provider_transaction_frame_invalid");
    const std::string bytes = std::to_string(payload.size()) + ':' + payload + ',';
    Deadline deadline(timeout, cancelled); std::size_t offset = 0;
    while (offset < bytes.size()) {
        if (const char *error = deadline.Wait(socket_, POLLOUT)) return Fail(error);
        iovec data = {const_cast<char *>(bytes.data() + offset), bytes.size() - offset};
        union { cmsghdr alignment; char bytes[CMSG_SPACE(2 * sizeof(int))]; } control = {};
        msghdr message = {}; message.msg_iov = &data; message.msg_iovlen = 1;
        if (!offset && !descriptors.empty()) {
            message.msg_control = control.bytes; message.msg_controllen = CMSG_SPACE(descriptors.size() * sizeof(int));
            auto header = CMSG_FIRSTHDR(&message); header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS;
            header->cmsg_len = CMSG_LEN(descriptors.size() * sizeof(int));
            std::memcpy(CMSG_DATA(header), descriptors.data(), descriptors.size() * sizeof(int));
        }
        int flags = 0;
#ifdef MSG_NOSIGNAL
        flags = MSG_NOSIGNAL;
#endif
        const auto count = sendmsg(socket_, &message, flags);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return Fail("provider_transaction_io");
        offset += count; if (anyBytesSent) *anyBytesSent = true;
    }
    return true;
}
bool Channel::Receive(Frame *output, std::vector<int> *descriptors, unsigned timeout,
    const std::function<bool()> &cancelled) {
    if (!output || !descriptors || !descriptors->empty() || !valid()) return Fail("provider_transaction_frame_invalid");
    Deadline deadline(timeout, cancelled); std::vector<int> received;
    std::string prefix, payload; std::size_t length = 0, total = 0; bool headerDone = false;
    const auto fail = [&](const char *error) { CloseAll(received); return Fail(error); };
    for (;;) {
        if (const char *error = deadline.Wait(socket_, POLLIN)) return fail(error);
        char buffer[65536]; const auto capacity = headerDone ? std::min(sizeof(buffer), length + 1 - payload.size()) : 1u;
        iovec data = {buffer, capacity};
        union { cmsghdr alignment; char bytes[CMSG_SPACE(8 * sizeof(int))]; } control = {};
        msghdr message = {}; message.msg_iov = &data; message.msg_iovlen = 1;
        message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
        const auto count = recvmsg(socket_, &message, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return fail(total ? "provider_transaction_truncated" : "provider_transaction_closed");
        bool invalid = (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) != 0;
        for (auto item = CMSG_FIRSTHDR(&message); item; item = CMSG_NXTHDR(&message, item)) {
            if (item->cmsg_level != SOL_SOCKET || item->cmsg_type != SCM_RIGHTS || item->cmsg_len < CMSG_LEN(0)) {
                invalid = true; continue;
            }
            const auto bytes = item->cmsg_len - CMSG_LEN(0);
            if (bytes % sizeof(int) || total) invalid = true;
            for (std::size_t i = 0; i < bytes / sizeof(int); ++i) {
                int fd; std::memcpy(&fd, reinterpret_cast<const char *>(CMSG_DATA(item)) + i * sizeof(int), sizeof(fd));
                received.push_back(fd);
                if (fcntl(fd, F_SETFD, FD_CLOEXEC)) invalid = true;
            }
        }
        total += count;
        if (invalid || received.size() > 2) return fail("provider_transaction_descriptors_invalid");
        if (!headerDone) {
            if (buffer[0] == ':') {
                std::uint64_t parsed;
                if (!Number(prefix, &parsed) || !parsed || parsed > MaximumFrameBytes) return fail("provider_transaction_frame_invalid");
                length = parsed; headerDone = true;
            } else {
                if (buffer[0] < '0' || buffer[0] > '9' || prefix.size() == 8) return fail("provider_transaction_frame_invalid");
                prefix += buffer[0];
            }
        } else {
            payload.append(buffer, count);
            if (payload.size() == length + 1) {
                Frame frame;
                if (payload.back() != ',' || !Decode(payload.substr(0, length), &frame) || !DescriptorRoles(frame, received))
                    return fail("provider_transaction_frame_invalid");
                *output = std::move(frame); *descriptors = std::move(received); return true;
            }
        }
    }
}
}}}
