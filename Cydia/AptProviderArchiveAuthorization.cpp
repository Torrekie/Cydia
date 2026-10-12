/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderArchiveAuthorization.hpp"
#include "Cydia/RedactedURL.hpp"
namespace CydiaAPT { namespace Provider {
namespace {
CydiaRuntime::RepositoryArchiveAuthorizationHandler Handler(const ReviewedTransaction &review,
    const ServerRequestContext &context, std::uint64_t capabilities) {
    return [review, &context, capabilities](const CydiaRuntime::RepositoryArchiveAuthorizationRequest &request,
        const std::function<bool()> &cancelled) {
        ArchiveAuthorizationReply result;
        const auto stop = [&]() { return (cancelled && cancelled()) ||
            (context.control.cancelled && context.control.cancelled()) ||
            (context.control.remainingMilliseconds && !context.control.remainingMilliseconds()); };
        if (stop()) { result.status = CydiaRuntime::RepositoryArchiveAuthorizationStatus::Cancelled; return result; }
        if (!(capabilities & AuthorizedArchiveGrants) || !context.parentRequest) {
            result.status = CydiaRuntime::RepositoryArchiveAuthorizationStatus::Unsupported; return result;
        }
        const ArchiveManifest *matched = nullptr;
        for (const auto &archive : review.execution.archives)
            if (archive.sourceURI == request.sourceURL && archive.package.package == request.package &&
                archive.package.version == request.version && archive.package.architecture == request.architecture) {
                if (matched) return result; // An ambiguous selected index requires a new review.
                matched = &archive;
            }
        if (!matched) return result;
        ArchiveAuthorizationRequest grant; grant.binding = review.binding; grant.archive = matched->identifier;
        Message reply; std::string payload;
        if (!Encode(grant, &payload) || !context.parentRequest(Operation::AuthorizeArchive, payload, &reply) ||
            !reply.succeeded || !Decode(reply.payload, &result)) return ArchiveAuthorizationReply();
        if (stop()) {
            result = ArchiveAuthorizationReply(); result.status = CydiaRuntime::RepositoryArchiveAuthorizationStatus::Cancelled;
        }
        result.message = CydiaRuntime::RedactDiagnosticURLs(result.message);
        return result;
    };
}
}
ScopedWorkerArchiveAuthorization::ScopedWorkerArchiveAuthorization(const ReviewedTransaction &review,
    const ServerRequestContext &context, std::uint64_t capabilities) : scope_(Handler(review, context, capabilities)) {}
}} // namespace CydiaAPT::Provider
