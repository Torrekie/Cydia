/* This adapter neither creates nor broadens native execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderNativeVersionComparison.hpp"
#include <map>
#include <utility>

namespace CydiaAPT { namespace Provider {
namespace {
namespace B = BinaryRelationships;
B::VersionComparison Value(B::ComparisonStatus status, int ordering = 0) {
    B::VersionComparison result; result.status = status; result.ordering = ordering; return result;
}
bool Digest(const std::string &value) {
    return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos;
}
struct Comparator {
    const std::string identity;
    NativeVersionQuery query;
    std::function<bool()> cancelled;
    std::map<std::pair<std::string, std::string>, int> cache;
    B::ComparisonStatus terminal = B::ComparisonStatus::Compared;
    bool busy = false;
    Comparator(std::string authority, NativeVersionQuery callback, std::function<bool()> cancel) :
        identity(std::move(authority)), query(std::move(callback)), cancelled(std::move(cancel)) {
        if (!Digest(identity) || !query) terminal = B::ComparisonStatus::Unavailable;
    }
    B::VersionComparison Invalidate(B::ComparisonStatus status) {
        if (terminal == B::ComparisonStatus::Compared) terminal = status;
        cache.clear(); return Value(terminal);
    }
    bool Cancelled() {
        if (!cancelled || !cancelled()) return false;
        Invalidate(B::ComparisonStatus::Failed); return true;
    }
    bool Query(const std::string &left, const char *relation, const std::string &right, bool *matches) {
        if (Cancelled() || terminal != B::ComparisonStatus::Compared) return false;
        NativeVersionQueryRequest request;
        request.nativeAuthorityIdentity = identity;
        request.arguments = {"--compare-versions", left, relation, right};
        const NativeVersionQueryReply reply = query(request, cancelled);
        if (Cancelled() || terminal != B::ComparisonStatus::Compared) return false;
        if (reply.nativeAuthorityIdentity != identity || !reply.output.empty() ||
            reply.result.kind != CydiaRuntime::Dpkg::ResultKind::Exited || reply.result.error != 0 ||
            (reply.result.code != 0 && reply.result.code != 1)) {
            Invalidate(B::ComparisonStatus::Failed); return false;
        }
        *matches = reply.result.code == 0; return true;
    }
    B::VersionComparison Compare(const std::string &left, const std::string &right) {
        if (terminal != B::ComparisonStatus::Compared) return Value(terminal);
        if (busy) return Invalidate(B::ComparisonStatus::Failed);
        struct Busy { bool &value; explicit Busy(bool &v) : value(v) { value = true; } ~Busy() { value = false; } } guard(busy);
        try {
            if (Cancelled() || terminal != B::ComparisonStatus::Compared) return Value(terminal);
            if (!B::ValidVersion(left) || !B::ValidVersion(right)) return Value(B::ComparisonStatus::InvalidVersion);
            const auto key = std::make_pair(left, right);
            const auto cached = cache.find(key);
            if (cached != cache.end()) return Value(B::ComparisonStatus::Compared, cached->second);
            if (cache.size() >= MaximumNativeVersionPairs) return Invalidate(B::ComparisonStatus::Unavailable);
            bool less = false, greater = false;
            if (!Query(left, "lt", right, &less)) return Value(terminal);
            if (!less && !Query(left, "gt", right, &greater)) return Value(terminal);
            if (Cancelled() || terminal != B::ComparisonStatus::Compared) return Value(terminal);
            const int ordering = less ? -1 : greater ? 1 : 0;
            cache.emplace(key, ordering);
            return Value(B::ComparisonStatus::Compared, ordering);
        } catch (...) { return Invalidate(B::ComparisonStatus::Failed); }
    }
};
}
B::VersionComparator MakeNativeVersionComparator(const std::string &identity, NativeVersionQuery query,
    const std::function<bool()> &cancelled) {
    const auto state = std::make_shared<Comparator>(identity, std::move(query), cancelled);
    return [state](const std::string &left, const std::string &right) { return state->Compare(left, right); };
}
}} // namespace CydiaAPT::Provider
