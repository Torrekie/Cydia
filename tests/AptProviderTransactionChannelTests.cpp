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
    for (const int fd : received) close(fd);
    received.clear();
    // Linux exposes both anonymous-pipe ends as one inode; Darwin exposes
    // endpoint identities. fstat cannot infer a Darwin pipe's peer endpoint.
#if defined(__linux__)
    Check(!ValidChildDescriptors(input[0], input[1]), "one pipe inode cannot share child input and status");
#endif
    int interactive[2]; Pair(interactive);
    Check(ValidChildDescriptors(interactive[0], status[1]), "production Unix stream input is supported");
    const int duplicate = dup(interactive[0]);
    Check(duplicate >= 3 && !ValidChildDescriptors(interactive[0], duplicate), "duplicate socket object cannot serve both roles");
    close(duplicate);
    close(interactive[0]); close(interactive[1]);
    ChildDescriptor primary; primary.primaryBatch = 1; primary.primaryActions = {4, 5};
    ChildDescriptor parsed; std::string purpose;
    Check(EncodeChildDescriptor(primary, &purpose) && DecodeChildDescriptor(purpose, &parsed) && parsed.primaryActions == primary.primaryActions,
        "bounded exact primary purpose roundtrip");
    primary.primaryActions.push_back(4); Check(!EncodeChildDescriptor(primary, &encoded), "duplicate primary actions refused");
    ChildDescriptor trigger; trigger.purpose = ChildPurpose::TriggerDrain;
    trigger.envelopeIdentity = "approved-envelope"; trigger.checkpointIdentity = "native-checkpoint";
    trigger.pass = 2; trigger.primaryCheckpoint = 1; trigger.targets.push_back({"sample", "1:2.0-3", "all"});
    Check(EncodeChildDescriptor(trigger, &encoded) && DecodeChildDescriptor(encoded, &parsed) && parsed.targets[0].architecture == "all" && parsed.pass == 2,
        "trigger purpose binds exact generation, pass and checkpoint");
    trigger.targets.push_back(trigger.targets.front()); Check(!EncodeChildDescriptor(trigger, &encoded), "duplicate trigger targets refused");
    trigger.targets.clear(); Check(!EncodeChildDescriptor(trigger, &encoded), "empty drain requires explicit deferred incorporation");
    trigger.incorporateDeferred = true; Check(EncodeChildDescriptor(trigger, &encoded), "native deferred-only scope is representable");
    auto scoped = Request(Operation::Execute); scoped.scopedChildren = true;
    Check(sender.Send(scoped) && receiver.Receive(&decoded, &received) && received.empty() && decoded.scopedChildren,
        "finite outer Execute carries no channels");
    scoped.event = Event::ChildNeeded; scoped.childOrdinal = 1; scoped.childDescriptor = purpose;
    Check(sender.Send(scoped) && receiver.Receive(&decoded, &received) && decoded.childOrdinal == 1,
        "needed event binds scoped child ordinal");
    scoped.event = Event::ChildChannels; scoped.success = true;
    Check(sender.Send(scoped, {input[0], status[1]}) && receiver.Receive(&decoded, &received) && received.size() == 2,
        "negotiated response transfers fresh descriptors");
    for (int descriptor : received) close(descriptor);
    received.clear();
    auto wrongScope = scoped; wrongScope.childOrdinal = 0;
    Check(!Encode(wrongScope, &encoded), "child frame cannot omit ordinal");
    wrongScope = scoped; wrongScope.scopedChildren = false;
    Check(!Encode(wrongScope, &encoded), "legacy transaction cannot inject child messages");
    wrongScope = scoped; wrongScope.operation = Operation::Commit;
    Check(!Encode(wrongScope, &encoded), "Commit cannot negotiate a dpkg child");
    {
        using namespace CydiaAPT::Provider;
        ConffilePolicyDecision policy; policy.match = NativeEffectPolicy::Status::Matched;
        policy.input = CydiaRuntime::Dpkg::ConffileInputPolicy::Automatic;
        policy.inputIdentity.assign(64, 'a'); policy.recordIdentity.assign(64, 'b'); policy.launchIdentity.assign(64, 'c');
        auto event = scoped; event.event = Event::ChildPolicy; event.conffilePolicy = true;
        Check(EncodeConffilePolicy(policy, &event.payload) && Encode(event, &encoded) && Decode(encoded, &decoded) &&
            decoded.conffilePolicy && decoded.event == Event::ChildPolicy, "v3 policy bound to child envelope");
        ConffilePolicyDecision copy;
        Check(DecodeConffilePolicy(decoded.payload, &copy) && copy.launchIdentity == policy.launchIdentity, "exact launch identity roundtrip");
        auto invalidPolicy = policy; invalidPolicy.match = NativeEffectPolicy::Status::Missing;
        Check(!EncodeConffilePolicy(invalidPolicy, &encoded), "unmatched policy cannot claim automatic proof");
        invalidPolicy = policy; invalidPolicy.launchIdentity[0] = 'X';
        Check(!EncodeConffilePolicy(invalidPolicy, &encoded), "malformed launch binding refused");
        auto legacy = event; legacy.conffilePolicy = false;
        Check(!Encode(legacy, &encoded), "v2 cannot inject a policy handshake");
        Check(sender.Send(event) && receiver.Receive(&decoded, &received) && received.empty(), "policy transfers no child descriptors");
        event.event = Event::ChildPolicyAccepted;
        Check(sender.Send(event) && receiver.Receive(&decoded, &received) && received.empty(), "acknowledgement echoes exact decision frame");
        for (std::size_t size = 0; size != event.payload.size(); ++size)
            Check(!DecodeConffilePolicy(event.payload.substr(0, size), &copy), "truncated policy refused");
    }
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
