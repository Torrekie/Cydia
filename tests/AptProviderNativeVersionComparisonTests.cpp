/* Native comparison callback contract; no process, package database or APT.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderNativeVersionComparison.hpp"
#include <cerrno>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

namespace {
namespace P = CydiaAPT::Provider;
namespace B = P::BinaryRelationships;
namespace D = CydiaRuntime::Dpkg;
const std::string Authority(64, 'a');
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[apt-provider-native-version-comparison] " << message << '\n'; std::exit(1);
}
P::NativeVersionQueryReply Reply(int code) {
    P::NativeVersionQueryReply reply;
    reply.result = {D::ResultKind::Exited, code, 0}; reply.nativeAuthorityIdentity = Authority; return reply;
}
struct Sequence {
    std::vector<P::NativeVersionQueryReply> replies;
    std::vector<P::NativeVersionQueryRequest> requests;
    P::NativeVersionQuery Callback() {
        return [this](const P::NativeVersionQueryRequest &request, const std::function<bool()> &) {
            Require(request.nativeAuthorityIdentity == Authority && request.maximumOutputBytes == 1 &&
                request.timeoutMilliseconds == 3000, "query carries frozen authority and bounded capture requirements");
            Require(requests.size() < replies.size(), "no unplanned query");
            requests.push_back(request); return replies[requests.size() - 1];
        };
    }
};
void ExitStatusOrdering() {
    Sequence less; less.replies = {Reply(0)};
    auto compare = P::MakeNativeVersionComparator(Authority, less.Callback());
    auto value = compare("1:2.0~rc1-3", "1:2.0-1");
    Require(value.status == B::ComparisonStatus::Compared && value.ordering == -1 && less.requests.size() == 1 &&
        less.requests[0].arguments == std::vector<std::string>({"--compare-versions", "1:2.0~rc1-3", "lt", "1:2.0-1"}),
        "native lt success determines ordering with exact separate argv");
    auto copy = compare; value = copy("1:2.0~rc1-3", "1:2.0-1");
    Require(value.status == B::ComparisonStatus::Compared && value.ordering == -1 && less.requests.size() == 1, "copies share retained native result");
    Sequence greater; greater.replies = {Reply(1), Reply(0)};
    compare = P::MakeNativeVersionComparator(Authority, greater.Callback()); value = compare("2", "1");
    Require(value.status == B::ComparisonStatus::Compared && value.ordering == 1 && greater.requests.size() == 2 &&
        greater.requests[0].arguments == std::vector<std::string>({"--compare-versions", "2", "lt", "1"}) &&
        greater.requests[1].arguments == std::vector<std::string>({"--compare-versions", "2", "gt", "1"}), "gt is queried only after lt is false");
    Sequence equal; equal.replies = {Reply(1), Reply(1), Reply(1), Reply(1)};
    compare = P::MakeNativeVersionComparator(Authority, equal.Callback()); value = compare("1", "1-0");
    Require(value.status == B::ComparisonStatus::Compared && value.ordering == 0, "native equivalence is not lexical string equality");
    value = compare("1", "1");
    Require(value.status == B::ComparisonStatus::Compared && value.ordering == 0 && equal.requests.size() == 4, "identical text still obtains native comparison proof");
}
void InvalidInputsAndFactory() {
    Sequence sequence; sequence.replies = {Reply(0)};
    auto compare = P::MakeNativeVersionComparator(Authority, sequence.Callback());
    for (const std::string &invalid : {std::string(), std::string("--force-all"), std::string("-1"), std::string("1 bad"),
        std::string("1\n2"), std::string("1;true"), std::string("1:"), std::string("1-"), std::string("1-2-"),
        std::string("2147483648:1"), std::string("1\0bad", 5), std::string(1025, '1')}) {
        Require(compare(invalid, "1").status == B::ComparisonStatus::InvalidVersion &&
            compare("1", invalid).status == B::ComparisonStatus::InvalidVersion, "invalid version refuses before query");
    }
    Require(sequence.requests.empty() && compare("1", "2").status == B::ComparisonStatus::Compared, "invalid inputs neither query nor poison valid comparisons");
    Require(P::MakeNativeVersionComparator("worker-claim", sequence.Callback())("1", "2").status == B::ComparisonStatus::Unavailable,
        "unbound authority cannot create a usable comparator");
    Require(P::MakeNativeVersionComparator(Authority, {}) ("1", "2").status == B::ComparisonStatus::Unavailable, "absent native query has no fallback");
}
void FailedQueryIsSticky() {
    std::vector<P::NativeVersionQueryReply> failures;
    failures.push_back(Reply(2)); failures.push_back(Reply(-1));
    auto reply = Reply(0); reply.result.kind = D::ResultKind::Signaled; reply.result.code = 9; failures.push_back(reply);
    reply = Reply(0); reply.result.kind = D::ResultKind::LaunchFailed; reply.result.error = ENOENT; failures.push_back(reply);
    reply = Reply(0); reply.result.error = EIO; failures.push_back(reply);
    reply = Reply(0); reply.output = "\n"; failures.push_back(reply);
    reply = Reply(0); reply.output.assign(1024, 'x'); failures.push_back(reply);
    reply = Reply(0); reply.nativeAuthorityIdentity.assign(64, 'b'); failures.push_back(reply);
    reply = Reply(0); reply.nativeAuthorityIdentity.clear(); failures.push_back(reply);
    for (const auto &failure : failures) {
        Sequence sequence; sequence.replies = {Reply(0), Reply(1), failure};
        auto compare = P::MakeNativeVersionComparator(Authority, sequence.Callback());
        Require(compare("1", "2").status == B::ComparisonStatus::Compared, "retain initial native pair");
        const auto value = compare("3", "4");
        Require(value.status == B::ComparisonStatus::Failed && value.ordering == 0 && sequence.requests.size() == 3,
            "second comparison failure publishes no partial ordering");
        Require(compare("1", "2").status == B::ComparisonStatus::Failed && compare("3", "4").status == B::ComparisonStatus::Failed &&
            sequence.requests.size() == 3, "failure discards prior cache and forbids retries");
    }
    Sequence first; first.replies = {Reply(2)};
    auto compare = P::MakeNativeVersionComparator(Authority, first.Callback());
    Require(compare("1", "2").status == B::ComparisonStatus::Failed && first.requests.size() == 1, "lt failure never falls through to gt");
}
void BoundAndCancellation() {
    unsigned calls = 0;
    auto compare = P::MakeNativeVersionComparator(Authority, [&](const P::NativeVersionQueryRequest &, const std::function<bool()> &) {
        ++calls; return Reply(0);
    });
    for (std::size_t i = 0; i < P::MaximumNativeVersionPairs; ++i)
        Require(compare(std::to_string(i), "999").status == B::ComparisonStatus::Compared, "bounded distinct pair admitted");
    Require(compare("0", "999").status == B::ComparisonStatus::Compared && calls == P::MaximumNativeVersionPairs, "cached pair remains available at budget limit");
    Require(compare("999", "0").status == B::ComparisonStatus::Unavailable && calls == P::MaximumNativeVersionPairs &&
        compare("0", "999").status == B::ComparisonStatus::Unavailable, "new ordered pair exhausts bound without query or surviving cache");
    bool cancelled = true; calls = 0;
    compare = P::MakeNativeVersionComparator(Authority, [&](const P::NativeVersionQueryRequest &, const std::function<bool()> &) {
        ++calls; return Reply(0);
    }, [&] { return cancelled; });
    Require(compare("1", "2").status == B::ComparisonStatus::Failed && calls == 0, "pre-query cancellation refuses");
    cancelled = false;
    Require(compare("1", "2").status == B::ComparisonStatus::Failed && calls == 0, "cancelled comparator cannot restart");
    calls = 0;
    compare = P::MakeNativeVersionComparator(Authority, [&](const P::NativeVersionQueryRequest &, const std::function<bool()> &cancel) {
        ++calls; Require(bool(cancel) && !cancel(), "query receives parent cancellation callback"); cancelled = true; return Reply(0);
    }, [&] { return cancelled; });
    Require(compare("1", "2").status == B::ComparisonStatus::Failed && calls == 1, "cancellation racing terminal success discards result");
}
void ExceptionsAndReentry() {
    unsigned calls = 0;
    auto compare = P::MakeNativeVersionComparator(Authority, [&](const P::NativeVersionQueryRequest &, const std::function<bool()> &) -> P::NativeVersionQueryReply {
        ++calls; throw std::runtime_error("native parent query failed");
    });
    Require(compare("1", "2").status == B::ComparisonStatus::Failed && compare("1", "2").status == B::ComparisonStatus::Failed && calls == 1,
        "callback exception invalidates once");
    compare = P::MakeNativeVersionComparator(Authority, {}, []() -> bool { throw std::runtime_error("cancel failed"); });
    Require(compare("1", "2").status == B::ComparisonStatus::Unavailable, "unavailable factory does not run callbacks");
    compare = P::MakeNativeVersionComparator(Authority, [](const P::NativeVersionQueryRequest &, const std::function<bool()> &) { return Reply(0); },
        []() -> bool { throw std::runtime_error("cancel failed"); });
    Require(compare("1", "2").status == B::ComparisonStatus::Failed, "cancellation callback exception refuses");
    B::VersionComparator recursive; calls = 0;
    recursive = P::MakeNativeVersionComparator(Authority, [&](const P::NativeVersionQueryRequest &, const std::function<bool()> &) {
        ++calls; Require(recursive("3", "4").status == B::ComparisonStatus::Failed, "reentrant parent use denied"); return Reply(0);
    });
    Require(recursive("1", "2").status == B::ComparisonStatus::Failed && calls == 1, "outer callback cannot publish success after reentrant invalidation");
}
}
int main() {
    ExitStatusOrdering(); InvalidInputsAndFactory(); FailedQueryIsSticky(); BoundAndCancellation(); ExceptionsAndReentry();
    std::cout << "apt-provider-native-version-comparison tests passed\n";
}
