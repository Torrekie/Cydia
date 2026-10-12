/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderProtocol.hpp"
#include <algorithm>
#include <cstring>

namespace CydiaAPT { namespace Provider {

bool Writer::bytes(const char *bytes, std::size_t count) {
    if (!valid_ || count > MaximumMessageBytes - bytes_.size() || (bytes == NULL && count != 0))
        return valid_ = false;
    if (count != 0) bytes_.append(bytes, count);
    return true;
}
bool Writer::integer(std::uint64_t value, unsigned count) {
    if (count == 0 || count > 8) return false;
    char encoded[8];
    for (unsigned i = 0; i != count; ++i)
        encoded[count - i - 1] = static_cast<char>((value >> (i * 8)) & 0xff);
    return bytes(encoded, count);
}
bool Reader::bytes(std::size_t count, std::string *value) {
    if (count > bytes_.size() - offset_) return false;
    value->assign(bytes_.data() + offset_, count); offset_ += count; return true;
}
bool Reader::integer(std::uint64_t *value, unsigned count) {
    if (count == 0 || count > 8 || count > bytes_.size() - offset_) return false;
    std::uint64_t result(0);
    for (unsigned i = 0; i != count; ++i)
        result = (result << 8) | static_cast<unsigned char>(bytes_[offset_++]);
    *value = result; return true;
}
bool Reader::collection(std::uint64_t count) {
    // Every serialized element consumes at least one byte. This also stops a
    // tiny attacker-controlled count prefix from allocating an enormous DTO.
    if (count > MaximumCollectionItems || count > bytes_.size() - offset_ ||
        count > 1000000 - items_ || depth_ >= 32) return false;
    items_ += count; ++depth_; return true;
}

bool EncodeFrame(const Message &message, std::string *bytes) {
    std::string payload;
    if (bytes == NULL || message.version != ProtocolVersion || message.sequence == 0 ||
        !Encode(message, &payload)) return false;
    Writer writer;
    if (!writer.bytes("CYAP", 4) || !writer.integer(payload.size(), 4) ||
        !writer.bytes(payload.data(), payload.size())) return false;
    *bytes = writer.result(); return true;
}
bool DecodeFrame(const std::string &bytes, Message *message) {
    if (message == NULL || bytes.size() < 8 || bytes.size() > MaximumMessageBytes ||
        bytes.compare(0, 4, "CYAP") != 0) return false;
    Reader reader(bytes); std::string magic, payload; std::uint64_t size;
    if (!reader.bytes(4, &magic) || !reader.integer(&size, 4) || size != bytes.size() - 8 ||
        !reader.bytes(size, &payload)) return false;
    Message candidate(*message);
    if (!Decode(payload, &candidate) || candidate.version != ProtocolVersion || candidate.sequence == 0)
        return false;
    *message = std::move(candidate); return true;
}

bool SameEnvironment(const Environment &left, const Environment &right) {
    std::string a, b;
    return Encode(left, &a) && Encode(right, &b) && a == b;
}

bool ValidIdentityToken(const std::string &value) {
    if (value.empty() || value.size() > 512) return false;
    for (const unsigned char character : value)
        if (!((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') ||
              std::strchr("-._:/+@=", character) != NULL)) return false;
    // strchr would otherwise consider the terminating NUL part of the alphabet.
    return value.find('\0') == std::string::npos;
}

bool ValidChallenge(const std::string &value) {
    if (value.size() < 32 || value.size() > 128 || value.size() % 2 != 0) return false;
    for (const unsigned char character : value)
        if (!((character >= 'a' && character <= 'f') || (character >= 'A' && character <= 'F') ||
              (character >= '0' && character <= '9'))) return false;
    return true;
}

namespace {
bool Path(const std::string &value, bool optional = false) {
    if (value.empty()) return optional;
    if (value.front() != '/' || value.size() > 4096) return false;
    for (const unsigned char character : value) if (character < 32 || character == 127) return false;
    return true;
}
bool Architectures(const std::vector<std::string> &values, const std::string &native) {
    if (values.empty() || values.size() > 128) return false;
    std::set<std::string> unique;
    for (const auto &value : values) {
        if (value.empty() || value.size() > 128 || value.front() == '-') return false;
        for (const unsigned char character : value)
            if (!((character >= 'a' && character <= 'z') ||
                  (character >= '0' && character <= '9') || character == '-')) return false;
        if (!unique.insert(value).second) return false;
    }
    return unique.count(native) != 0;
}
}

bool ValidEnvironment(const Environment &environment) {
    const auto &paths = environment.paths;
    return Path(paths.dpkg) && Path(paths.dpkgQuery) && Path(paths.dpkgDeb) && Path(paths.dpkgRoot) &&
        Path(paths.dpkgAdmin) && Path(paths.aptConfigOverride, true) &&
        Path(paths.sourceList, true) && Path(paths.sourceParts, true) &&
        ValidIdentityToken(environment.configurationIdentity) && ValidIdentityToken(environment.policyIdentity) &&
        ValidIdentityToken(environment.methodsIdentity) && ValidIdentityToken(environment.packageStateIdentity) &&
        Architectures(environment.registeredArchitectures, environment.nativeArchitecture) &&
        Architectures(environment.acquisitionArchitectures, environment.nativeArchitecture);
}

bool ValidHello(const Hello &hello) {
    return hello.protocolVersion == ProtocolVersion && ValidChallenge(hello.challenge) && Path(hello.registrationPath, true) &&
        (hello.requiredCapabilities & RequiredCapabilities) == RequiredCapabilities &&
        (hello.options.repositorySecurityMode == RepositorySecurityMode::Distribution ||
            (hello.requiredCapabilities & ExplicitSecurityOverrides) != 0) &&
        ValidEnvironment(hello.expected);
}

bool Compatible(const Info &info, const Environment &expected, std::string *reason) {
    const char *failure = NULL;
    if (info.availability != Availability::Ready) failure = "provider_unavailable";
    else if (info.protocolVersion != ProtocolVersion) failure = "provider_protocol_unsupported";
    else if ((info.capabilities & RequiredCapabilities) != RequiredCapabilities) failure = "provider_capabilities_incomplete";
    else if (!ValidIdentityToken(info.identifier) || info.implementationVersion.empty() ||
             !ValidIdentityToken(info.libraryIdentity) || !ValidIdentityToken(info.frontendIdentity))
        failure = "provider_identity_incomplete";
    else if (!ValidEnvironment(expected) || !ValidEnvironment(info.environment))
        failure = "provider_environment_incomplete";
    else if (!SameEnvironment(info.environment, expected)) failure = "provider_environment_changed";
    if (reason != NULL) *reason = failure == NULL ? std::string() : failure;
    return failure == NULL;
}

bool SameBinding(const Binding &left, const Binding &right) {
    std::string a, b;
    return Encode(left, &a) && Encode(right, &b) && a == b;
}

bool ValidRequestBinding(const Message &request) {
    if (request.version != ProtocolVersion || request.sequence == 0 ||
        (request.kind != MessageKind::Request && request.kind != MessageKind::ParentRequest) ||
        static_cast<unsigned>(request.operation) > static_cast<unsigned>(Operation::Progress)) return false;
    const bool parentOperation = request.operation >= Operation::AcquireFrontendLock &&
        request.operation <= Operation::CaptureStateSnapshot;
    if (parentOperation != (request.kind == MessageKind::ParentRequest) ||
        request.operation == Operation::Progress) return false;
    if (request.operation == Operation::Hello) return true;
    const auto &binding = request.binding;
    if (!ValidIdentityToken(binding.providerIdentifier) || !ValidChallenge(binding.session) ||
        !ValidIdentityToken(binding.configurationIdentity) || !ValidIdentityToken(binding.policyIdentity) ||
        !ValidIdentityToken(binding.packageStateIdentity) ||
        (!binding.review.empty() && !ValidIdentityToken(binding.review))) return false;
    switch (request.operation) {
        case Operation::PrepareArchives:
        case Operation::RunFetcher:
        case Operation::RunPackageManager:
        case Operation::ExecuteDpkg:
        case Operation::CommitExtendedState:
            return binding.cacheEpoch != 0 && !binding.review.empty();
        case Operation::Reset:
        case Operation::DrainErrors:
        case Operation::DiscardErrors:
        case Operation::LoadSources:
        case Operation::OpenCache:
        case Operation::SourcePreflight:
        case Operation::SourceResource:
        case Operation::SetSecurityMode:
        case Operation::RefreshArchitectures:
        case Operation::Cancel:
        case Operation::CaptureStateSnapshot:
            return true;
        default: return binding.cacheEpoch != 0;
    }
}

bool ValidateReply(const Message &request, const Message &reply) {
    const MessageKind kind = request.kind == MessageKind::ParentRequest ?
        MessageKind::ParentResponse : MessageKind::Response;
    return ValidRequestBinding(request) && reply.version == ProtocolVersion &&
        reply.sequence == request.sequence && reply.kind == kind &&
        reply.operation == request.operation && SameBinding(request.binding, reply.binding);
}

bool ValidateHelloReply(const Hello &hello, const Message &reply, Info *info) {
    if (info == NULL || !ValidHello(hello) || reply.version != ProtocolVersion ||
        reply.kind != MessageKind::Response || reply.operation != Operation::Hello ||
        reply.sequence != 1 || !reply.succeeded || reply.binding.session != hello.challenge) return false;
    Info candidate;
    if (!Decode(reply.payload, &candidate) || !Compatible(candidate, hello.expected, NULL) ||
        (candidate.capabilities & hello.requiredCapabilities) != hello.requiredCapabilities ||
        reply.binding.providerIdentifier != candidate.identifier ||
        reply.binding.configurationIdentity != candidate.environment.configurationIdentity ||
        reply.binding.policyIdentity != candidate.environment.policyIdentity ||
        reply.binding.packageStateIdentity != candidate.environment.packageStateIdentity ||
        !reply.binding.review.empty() || reply.binding.selectionRevision != 0 ||
        reply.binding.cacheEpoch != 0) return false;
    *info = std::move(candidate); return true;
}

}} // namespace CydiaAPT::Provider
