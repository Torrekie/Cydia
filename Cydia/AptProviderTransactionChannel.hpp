/* Direct app-to-cydo transaction framing; no worker authority crosses this API.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderTransactionChannel_HPP
#define Cydia_AptProviderTransactionChannel_HPP
#include "Cydia/AptProviderConffilePolicy.hpp"
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace CydiaAPT { namespace Provider { namespace TransactionChannel {
constexpr std::size_t MaximumFrameBytes = 8 * 1024 * 1024;
enum class Operation { Begin, Capture, Execute, Commit, Close };
enum class Event { Request, Started, Settled, ChildNeeded, ChildChannels, ChildDenied,
    ChildStarted, ChildSettled, ChildReleased, ChildCancelled, ChildPolicy, ChildPolicyAccepted };
enum class ChildPurpose { Primary, TriggerDrain };
struct ChildPackage { std::string package, version, architecture; };
struct ChildDescriptor {
    ChildPurpose purpose = ChildPurpose::Primary;
    std::uint64_t primaryBatch = 0;
    unsigned primaryAction = 0;
    std::vector<std::uint64_t> primaryActions;
    std::string envelopeIdentity, checkpointIdentity;
    std::uint64_t pass = 0, primaryCheckpoint = 0;
    bool incorporateDeferred = false;
    std::vector<ChildPackage> targets;
};
constexpr std::size_t MaximumChildDescriptorBytes = 256 * 1024;
bool EncodeChildDescriptor(const ChildDescriptor &, std::string *);
bool DecodeChildDescriptor(const std::string &, ChildDescriptor *);
bool EncodeConffilePolicy(const ConffilePolicyDecision &, std::string *);
bool DecodeConffilePolicy(const std::string &, ConffilePolicyDecision *);
struct Frame {
    Operation operation = Operation::Begin;
    Event event = Event::Request;
    std::uint64_t sequence = 0;
    std::string nonce, reviewDigest, payload, errorCode;
    bool success = false, mutationStarted = false, indeterminate = false;
    bool scopedChildren = false;
    // Negotiates direct app/helper v3 only. No provider capability or target
    // authorization; policy handshakes are required before every actual child.
    bool conffilePolicy = false;
    std::uint64_t childOrdinal = 0;
    std::string childDescriptor;
};
bool Encode(const Frame &, std::string *);
bool Decode(const std::string &, Frame *);
bool ValidChildDescriptors(int inputDescriptor, int statusDescriptor);

// Owns an exclusively used, connected AF_UNIX stream socket, including on
// constructor failure. No reads/writes may occur elsewhere. Methods are
// serialized by the caller. This framing layer does not authenticate peers or
// authorize operations; the cydo owner must bind the authenticated application,
// recompute the Begin digest and enforce nonce/digest/sequence for every call.
class Channel {
    int socket_ = -1;
    std::string error_;
    bool Fail(const char *);
public:
    explicit Channel(int ownedSocket);
    ~Channel();
    Channel(const Channel &) = delete;
    Channel &operator=(const Channel &) = delete;
    bool valid() const { return socket_ >= 0; }
    const std::string &error() const { return error_; }
    void Close();
    // Legacy Execute Request, or a negotiated ChildChannels response, carries
    // exactly readable stdin then writable status (FIFO/socket). Scoped outer
    // Execute has no descriptors. All remaining events carry none.
    // Send borrows descriptors; a successful recv transfers CLOEXEC ownership
    // to the caller. Failures close all received descriptors and the channel.
    // A zero timeout waits indefinitely. Use this only when mutation must
    // settle; do not cancel/timeout/kill a child after dispatching execution.
    bool Send(const Frame &, const std::vector<int> &descriptors = {},
        unsigned timeoutMilliseconds = 4000,
        const std::function<bool()> &cancelled = {}, bool *anyBytesSent = nullptr);
    bool Receive(Frame *, std::vector<int> *descriptors,
        unsigned timeoutMilliseconds = 4000,
        const std::function<bool()> &cancelled = {});
};
}}}
#endif
