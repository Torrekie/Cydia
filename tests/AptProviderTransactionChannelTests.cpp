/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTransactionChannel.hpp"
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
using namespace CydiaAPT::Provider::TransactionChannel;
namespace {
void Check(bool value, const char *message) {
    if (!value) { std::cerr << "[transaction-channel] " << message << '\n'; std::exit(1); }
}
void Pair(int sockets[2]) { Check(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "socketpair"); }
Frame Request(Operation operation = Operation::Capture) {
    Frame frame; frame.operation = operation; frame.sequence = 1;
    frame.nonce = "helper-nonce"; frame.reviewDigest = "SHA256:review"; return frame;
}
std::string Wire(const Frame &frame) {
    std::string bytes; Check(Encode(frame, &bytes), "encode fixture");
    return std::to_string(bytes.size()) + ':' + bytes + ',';
}
void SendRaw(int fd, const std::string &bytes, const std::vector<int> &descriptors = {}) {
    iovec data = {const_cast<char *>(bytes.data()), bytes.size()};
    union { cmsghdr align; char bytes[CMSG_SPACE(10 * sizeof(int))]; } control = {};
    msghdr message = {}; message.msg_iov = &data; message.msg_iovlen = 1;
    if (!descriptors.empty()) {
        message.msg_control = control.bytes; message.msg_controllen = CMSG_SPACE(descriptors.size() * sizeof(int));
        auto header = CMSG_FIRSTHDR(&message); header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(descriptors.size() * sizeof(int));
        std::memcpy(CMSG_DATA(header), descriptors.data(), descriptors.size() * sizeof(int));
    }
    Check(sendmsg(fd, &message, 0) == static_cast<ssize_t>(bytes.size()), "send raw small fixture");
}
}
int main() {
    Frame original = Request(), decoded; original.payload = std::string("binary\0data", 11);
    std::string encoded; Check(Encode(original, &encoded) && Decode(encoded, &decoded) && decoded.payload == original.payload,
        "exact binary payload roundtrip");
    Check(!Decode(encoded + "0:,", &decoded) && !Decode(encoded.substr(0, encoded.size() - 1), &decoded), "reject trailing/truncated codec");
    auto invalid = original; invalid.sequence = 0; Check(!Encode(invalid, &encoded), "reject missing sequence");
    invalid = original; invalid.nonce.clear(); Check(!Encode(invalid, &encoded), "reject missing nonce");
    invalid = original; invalid.event = Event::Started; invalid.success = invalid.mutationStarted = true;
    Check(!Encode(invalid, &encoded), "capture cannot claim mutation start");
    invalid = original; invalid.payload.assign(MaximumFrameBytes, 'x'); Check(!Encode(invalid, &encoded), "whole frame limit includes metadata");
    int sockets[2]; Pair(sockets); Channel sender(sockets[0]), receiver(sockets[1]);
    original.payload.assign(1024 * 1024, 'p');
    std::thread writer([&]() { Check(sender.Send(original), "bounded large frame send"); });
    std::vector<int> received;
    Check(receiver.Receive(&decoded, &received) && decoded.payload == original.payload && received.empty(), "large duplex socket frame"); writer.join();
    int input[2], status[2]; Check(pipe(input) == 0 && pipe(status) == 0, "execution pipes");
    auto execute = Request(Operation::Execute); execute.payload = "batch";
    Check(sender.Send(execute, {input[0], status[1]}) && receiver.Receive(&decoded, &received) && received.size() == 2,
        "exact descriptor pair handoff");
    Check((fcntl(received[0], F_GETFD) & FD_CLOEXEC) && (fcntl(received[1], F_GETFD) & FD_CLOEXEC), "received descriptors CLOEXEC");
    Check(write(input[1], "N\n", 2) == 2 && write(received[1], "status", 6) == 6, "descriptor roles usable");
    char buffer[8]; Check(read(received[0], buffer, 2) == 2 && read(status[0], buffer, 6) == 6, "descriptor contents delivered");
    for (const int fd : received) close(fd); received.clear();
    for (const auto &bad : std::vector<std::string>{"8388609:", "01:x,", "1:x;", "3:ab"}) {
        Pair(sockets); Channel channel(sockets[0]); SendRaw(sockets[1], bad); close(sockets[1]);
        Check(!channel.Receive(&decoded, &received, 200) && !channel.valid() && received.empty(), "reject invalid/truncated outer frame");
    }
    for (const auto &fds : std::vector<std::vector<int>>{{input[0]}, {status[1], input[0]}, {input[0], status[1], status[1]}}) {
        Pair(sockets); Channel channel(sockets[0]); SendRaw(sockets[1], Wire(execute), fds); close(sockets[1]);
        Check(!channel.Receive(&decoded, &received, 200) && received.empty(), "reject wrong descriptor count/roles");
    }
    Pair(sockets); { Channel channel(sockets[0]); auto response = Request(); response.event = Event::Settled; response.success = true;
        SendRaw(sockets[1], Wire(response), {input[0], status[1]}); close(sockets[1]);
        Check(!channel.Receive(&decoded, &received, 200), "reply cannot pass descriptors"); }
    Pair(sockets); { Channel channel(sockets[0]); const auto before = std::chrono::steady_clock::now();
        Check(!channel.Receive(&decoded, &received, 40) && channel.error() == "provider_transaction_timeout" &&
            std::chrono::steady_clock::now() - before < std::chrono::seconds(2), "bounded idle receive"); close(sockets[1]); }
    Pair(sockets); { Channel channel(sockets[0]); Check(!channel.Receive(&decoded, &received, 4000, [] { return true; }) &&
        channel.error() == "provider_cancelled", "cooperative nonmutating cancellation"); close(sockets[1]); }
    for (const int fd : {input[0], input[1], status[0], status[1]}) close(fd);
    std::cout << "[transaction-channel] bounded framing, descriptor roles and cancellation passed\n";
}
