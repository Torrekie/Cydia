/* Isolated authorization fixtures; no account server, credentials or downloads.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderArchiveAuthorization.hpp"
#include <cstdlib>
#include <iostream>
#include <thread>
namespace {
namespace P = CydiaAPT::Provider;
namespace R = CydiaRuntime;
using Status = R::RepositoryArchiveAuthorizationStatus;
void Require(bool value, const char *why) { if (!value) { std::cerr << why << '\n'; std::abort(); } }
P::ReviewedTransaction Review() {
    P::ReviewedTransaction review;
    review.binding.providerIdentifier = "fixture"; review.binding.session = std::string(64, 'a');
    review.binding.configurationIdentity = "config"; review.binding.policyIdentity = "policy";
    review.binding.packageStateIdentity = "state"; review.binding.review = "review"; review.binding.cacheEpoch = 1;
    P::ArchiveManifest archive; archive.identifier = "approved-all";
    archive.sourceURI = "https://repo.invalid/"; archive.package = {"sample", "1:2.0~rc1", "all"};
    review.execution.archives.push_back(archive); return review;
}
R::RepositoryArchiveAuthorizationRequest Request() { return {"https://repo.invalid/", "sample", "1:2.0~rc1", "all"}; }
void Wire() {
    auto review = Review(); P::ArchiveAuthorizationRequest request; request.binding = review.binding; request.archive = "approved-all";
    std::string bytes; Require(P::Encode(request, &bytes), "encode exact archive authorization");
    P::ArchiveAuthorizationRequest decoded; Require(P::Decode(bytes, &decoded) && decoded.archive == request.archive, "decode exact archive authorization");
    request.archive = std::string(513, 'a'); Require(!P::Encode(request, &bytes), "bounded archive identifier");
    P::ArchiveAuthorizationReply result; result.status = Status::Authorized; result.transportURL = "https://cdn.invalid/private?token=secret";
    Require(P::Encode(result, &bytes), "valid HTTPS grant");
    P::ArchiveAuthorizationReply copy; Require(P::Decode(bytes, &copy) && copy.transportURL == result.transportURL, "grant is not redacted as transport");
    for (const auto &url : {"http://cdn.invalid/a", "https://name:secret@cdn.invalid/a", "https:///missing", "https://cdn.invalid/a#fragment", "https://cdn.invalid/a\nheader"}) {
        result.transportURL = url; Require(!P::Encode(result, &bytes), "unsafe grant rejected");
    }
    result.transportURL = "https://cdn.invalid/a"; result.status = Status::Failed;
    Require(!P::Encode(result, &bytes), "failure must not carry a grant");
    result.transportURL.clear(); result.message = std::string(4097, 'x'); Require(!P::Encode(result, &bytes), "bounded diagnostic");
    P::Message message; message.kind = P::MessageKind::ParentRequest; message.operation = P::Operation::AuthorizeArchive;
    message.sequence = 1; message.binding = review.binding;
    Require(P::ValidRequestBinding(message), "grant is a reviewed parent request");
    message.binding.review.clear(); Require(!P::ValidRequestBinding(message), "unreviewed grant rejected");
    message.binding = review.binding; message.kind = P::MessageKind::Request;
    Require(!P::ValidRequestBinding(message), "grant cannot be ordinary worker operation");
}
void Scope() {
    R::SetRepositoryArchiveAuthorizationHandler([](const R::RepositoryArchiveAuthorizationRequest &, const std::function<bool()> &) {
        R::RepositoryArchiveAuthorizationResult result; result.status = Status::NotRequired; return result;
    });
    auto review = Review(); P::ServerRequestContext context; unsigned requests = 0;
    context.parentRequest = [&](P::Operation operation, const std::string &payload, P::Message *reply) {
        Require(operation == P::Operation::AuthorizeArchive, "only authorization reverse operation");
        P::ArchiveAuthorizationRequest decoded; Require(P::Decode(payload, &decoded) &&
            P::SameBinding(decoded.binding, review.binding) && decoded.archive == "approved-all", "exact reviewed ID and binding");
        ++requests; P::ArchiveAuthorizationReply result; result.status = Status::Authorized;
        result.transportURL = "https://cdn.invalid/file?token=secret";
        result.message = "diagnostic https://name:secret@cdn.invalid/private?token=secret";
        reply->succeeded = P::Encode(result, &reply->payload); return true;
    };
    {
        P::ScopedWorkerArchiveAuthorization scoped(review, context, P::AuthorizedArchiveGrants);
        auto result = R::AuthorizeRepositoryArchive(Request());
        Require(result.status == Status::Authorized && result.transportURL.find("secret") != std::string::npos &&
            result.message.find("secret") == std::string::npos, "transport grant preserved and diagnostic redacted");
        std::thread concurrent([] { Require(R::AuthorizeRepositoryArchive(Request()).status == Status::NotRequired, "thread scope must not replace app handler"); }); concurrent.join();
        auto wrong = Request(); wrong.architecture = "amd64";
        Require(R::AuthorizeRepositoryArchive(wrong).status == Status::Failed && requests == 1, "all and native identity cannot substitute");
        Require(R::AuthorizeRepositoryArchive(Request(), [] { return true; }).status == Status::Cancelled && requests == 1, "cancelled grant makes no RPC");
        {
            P::ScopedWorkerArchiveAuthorization nested(review, context, 0);
            Require(R::AuthorizeRepositoryArchive(Request()).status == Status::Unsupported && requests == 1, "unnegotiated capability denied");
        }
        Require(R::AuthorizeRepositoryArchive(Request()).status == Status::Authorized && requests == 2, "nested scope restores outer handler");
    }
    Require(R::AuthorizeRepositoryArchive(Request()).status == Status::NotRequired, "operation scope restores global handler");
    review.execution.archives.push_back(review.execution.archives.front());
    P::ScopedWorkerArchiveAuthorization ambiguous(review, context, P::AuthorizedArchiveGrants);
    Require(R::AuthorizeRepositoryArchive(Request()).status == Status::Failed && requests == 2, "ambiguous archive association fails closed");
}
}
int main() { Wire(); Scope(); std::cout << "[apt-provider-archive-authorization] PASS\n"; }
